// SPDX-License-Identifier: AGPL-3.0-or-later
import type { Hono } from 'hono';

import { RateLimiter, TUNNEL_RATE_LIMIT, TUNNEL_RATE_WINDOW_MS } from './limits';

/** Extracts a Bearer token from the Authorization header, or null. */
function bearerToken(c: { req: { header(name: string): string | undefined } }): string | null {
  const h = c.req.header('authorization');
  if (!h || h.length < 8 || h.slice(0, 7).toLowerCase() !== 'bearer ') return null;
  return h.slice(7);
}

/**
 * Relay tunnel for symmetric-NAT pairs: when ICE fails completely, two peers
 * can tunnel their already-encrypted gossip frames through the relay. The relay
 * sees opaque ciphertext — it cannot read or forge messages (they're still
 * signed + encrypted end-to-end). It only learns who's tunnelling with whom.
 *
 * Design: simple POST-to-poll pairing. Each peer POSTs frames addressed to the
 * other; the other GETs them. Bounded per-pair buffer, TTL on entries.
 */

const TUNNEL_TTL_MS = 5 * 60_000;
const MAX_BUFFER = 512;
const MAX_DRAIN_FRAMES = 32;
const MAX_TUNNEL_DATA_BYTES = 60 * 1024;
const MAX_PAIR_BYTES = 24 * 1024 * 1024;
const MAX_TOTAL_BYTES = 64 * 1024 * 1024;
const HEX_PUBKEY = /^[0-9a-f]{64}$/i;
// Cap distinct (from|to) pairs. Undrained buffers to peers that never poll
// (e.g. an attacker posting to random `to` values) would otherwise grow the map
// between periodic lazy TTL pruning passes.
const MAX_PAIRS = 10_000;
const MAX_TOTAL_FRAMES = 2048;

interface TunnelEntry {
  data: string;
  ts: number;
  bytes: number;
}

export class TunnelHub {
  // Key: "from|to" -> buffered frames the sender posted for the receiver.
  private readonly buffers = new Map<string, TunnelEntry[]>();
  private readonly bufferBytes = new Map<string, number>();
  private frameCount = 0;
  private totalBytes = 0;
  private lastPruneMs = 0;

  post(from: string, to: string, data: string, nowMs: number): boolean {
    const dataBytes = Buffer.byteLength(data, 'utf8');
    if (dataBytes > MAX_TUNNEL_DATA_BYTES) return false;
    if (nowMs - this.lastPruneMs >= TUNNEL_TTL_MS) {
      this.prune(nowMs);
    }
    const key = `${from}|${to}`;
    // Touch for LRU: delete + re-insert so active pairs move to the end and the
    // oldest pair sits at the front for eviction.
    const buf = this.buffers.get(key) ?? [];
    let pairBytes = this.bufferBytes.get(key) ?? 0;
    this.buffers.delete(key);
    this.bufferBytes.delete(key);
    buf.push({ data, ts: nowMs, bytes: dataBytes });
    this.frameCount++;
    this.totalBytes += dataBytes;
    pairBytes += dataBytes;
    while (buf.length > MAX_BUFFER || pairBytes > MAX_PAIR_BYTES) {
      const removed = buf.shift();
      if (removed == null) break;
      this.frameCount--;
      this.totalBytes -= removed.bytes;
      pairBytes -= removed.bytes;
    }
    this.buffers.set(key, buf);
    this.bufferBytes.set(key, pairBytes);
    // Evict the least-recently-posted pair once over the cap.
    while (
      this.buffers.size > MAX_PAIRS ||
      this.frameCount > MAX_TOTAL_FRAMES ||
      this.totalBytes > MAX_TOTAL_BYTES
    ) {
      const oldest = this.buffers.keys().next().value;
      if (oldest === undefined) break;
      this.deletePair(oldest);
    }
    return true;
  }

  private prune(nowMs: number): void {
    for (const [key, buf] of [...this.buffers.entries()]) {
      const fresh = buf.filter((entry) => nowMs - entry.ts <= TUNNEL_TTL_MS);
      this.deletePair(key);
      if (fresh.length === 0) {
        continue;
      }
      this.putPair(key, fresh);
    }
    this.lastPruneMs = nowMs;
  }

  private deletePair(key: string): void {
    this.frameCount -= this.buffers.get(key)?.length ?? 0;
    this.totalBytes -= this.bufferBytes.get(key) ?? 0;
    this.buffers.delete(key);
    this.bufferBytes.delete(key);
  }

  private putPair(key: string, entries: TunnelEntry[]): void {
    const bytes = entries.reduce((total, entry) => total + entry.bytes, 0);
    this.buffers.set(key, entries);
    this.bufferBytes.set(key, bytes);
    this.frameCount += entries.length;
    this.totalBytes += bytes;
  }

  /** Drains buffered frames for [to] from [from], pruning stale entries. */
  drain(from: string, to: string, nowMs: number): string[] {
    const key = `${from}|${to}`;
    const buf = this.buffers.get(key);
    if (!buf) return [];
    const fresh = buf.filter((e) => nowMs - e.ts <= TUNNEL_TTL_MS);
    this.deletePair(key);
    const drained = fresh.splice(0, MAX_DRAIN_FRAMES);
    if (fresh.length > 0) this.putPair(key, fresh);
    return drained.map((e) => e.data);
  }
}

export function addTunnelRoutes(
  app: Hono,
  hub: TunnelHub,
  verifyToken: (token: string, nowMs: number) => string | null,
): void {
  const tunnelLimiter = new RateLimiter(TUNNEL_RATE_LIMIT, TUNNEL_RATE_WINDOW_MS);

  // A peer sends a frame through the relay to another peer.
  app.post('/tunnel', async (c) => {
    let body: {
      from?: string;
      to?: string;
      data?: string;
      token?: string;
    };
    try {
      body = (await c.req.json()) as typeof body;
    } catch {
      return c.json({ error: 'invalid json' }, 400);
    }
    if (!body.from || !body.to || !body.data) {
      return c.json({ error: 'from, to, data required' }, 400);
    }
    if (
      !HEX_PUBKEY.test(body.from) ||
      !HEX_PUBKEY.test(body.to) ||
      typeof body.data !== 'string'
    ) {
      return c.json({ error: 'invalid tunnel frame' }, 400);
    }
    const token = bearerToken(c);
    if (!token) return c.json({ error: 'token required' }, 403);
    const owner = verifyToken(token, Date.now());
    if (owner !== body.from) {
      return c.json({ error: 'invalid or expired token' }, 403);
    }
    // Per-pair bandwidth cap.
    const pairKey = `${body.from}|${body.to}`;
    if (!tunnelLimiter.allow(pairKey, Date.now())) {
      return c.json({ error: 'rate limited' }, 429);
    }
    if (!hub.post(body.from, body.to, body.data, Date.now())) {
      return c.json({ error: 'tunnel frame too large' }, 413);
    }
    return c.json({ ok: true });
  });

  // A peer polls for frames addressed to them from a specific peer.
  app.get('/tunnel', (c) => {
    const from = c.req.query('from'); // who sent the frames
    const to = c.req.query('to'); // me (the poller)
    const token = bearerToken(c);
    if (!from || !to) {
      return c.json({ error: 'from and to required' }, 400);
    }
    if (!HEX_PUBKEY.test(from) || !HEX_PUBKEY.test(to)) {
      return c.json({ error: 'invalid tunnel pair' }, 400);
    }
    if (!token) return c.json({ error: 'token required' }, 403);
    const owner = verifyToken(token, Date.now());
    if (owner !== to) {
      return c.json({ error: 'invalid or expired token' }, 403);
    }
    const frames = hub.drain(from, to, Date.now());
    return c.json({ frames });
  });
}
