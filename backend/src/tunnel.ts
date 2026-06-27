// SPDX-License-Identifier: AGPL-3.0-or-later
import type { Hono } from 'hono';

/**
 * Relay tunnel for symmetric-NAT pairs: when ICE fails completely, two peers
 * can tunnel their already-encrypted gossip frames through the relay. The relay
 * sees opaque ciphertext — it cannot read or forge messages (they're still
 * signed + encrypted end-to-end). It only learns who's tunnelling with whom.
 *
 * Design: simple POST-to-poll pairing. Each peer POSTs frames addressed to the
 * other; the other GETs them. Bounded per-pair buffer, TTL on entries.
 */

const TUNNEL_TTL_MS = 30_000;
const MAX_BUFFER = 100;

interface TunnelEntry {
  data: string;
  ts: number;
}

export class TunnelHub {
  // Key: "from|to" -> buffered frames the sender posted for the receiver.
  private readonly buffers = new Map<string, TunnelEntry[]>();

  post(from: string, to: string, data: string, nowMs: number): void {
    const key = `${from}|${to}`;
    const buf = this.buffers.get(key) ?? [];
    buf.push({ data, ts: nowMs });
    if (buf.length > MAX_BUFFER) buf.splice(0, buf.length - MAX_BUFFER);
    this.buffers.set(key, buf);
  }

  /** Drains buffered frames for [to] from [from], pruning stale entries. */
  drain(from: string, to: string, nowMs: number): string[] {
    const key = `${from}|${to}`;
    const buf = this.buffers.get(key);
    if (!buf) return [];
    const fresh = buf.filter((e) => nowMs - e.ts <= TUNNEL_TTL_MS);
    this.buffers.delete(key);
    return fresh.map((e) => e.data);
  }
}

export function addTunnelRoutes(
  app: Hono,
  hub: TunnelHub,
  verifyToken: (token: string, nowMs: number) => string | null,
): void {
  // A peer sends a frame through the relay to another peer.
  app.post('/tunnel', async (c) => {
    const body = (await c.req.json()) as {
      from?: string;
      to?: string;
      data?: string;
      token?: string;
    };
    if (!body.from || !body.to || !body.data) {
      return c.json({ error: 'from, to, data required' }, 400);
    }
    if (!body.token) return c.json({ error: 'token required' }, 403);
    const owner = verifyToken(body.token, Date.now());
    if (owner !== body.from) {
      return c.json({ error: 'invalid or expired token' }, 403);
    }
    hub.post(body.from, body.to, body.data, Date.now());
    return c.json({ ok: true });
  });

  // A peer polls for frames addressed to them from a specific peer.
  app.get('/tunnel', (c) => {
    const from = c.req.query('from'); // who sent the frames
    const to = c.req.query('to'); // me (the poller)
    const token = c.req.query('token');
    if (!from || !to) {
      return c.json({ error: 'from and to required' }, 400);
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
