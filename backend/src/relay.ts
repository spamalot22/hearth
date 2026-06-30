// SPDX-License-Identifier: AGPL-3.0-or-later
import { Hono, type MiddlewareHandler } from 'hono';
import { cors } from 'hono/cors';

import { addGifRoutes } from './gif';
import {
  IP_RATE_LIMIT,
  IP_RATE_WINDOW_MS,
  MAX_BODY_BYTES,
  MAX_CHANNEL_MESSAGES,
  MAX_CHANNELS,
  MESSAGE_RATE_LIMIT,
  MESSAGE_RATE_WINDOW_MS,
  RateLimiter,
  SEARCH_RATE_LIMIT,
  SEARCH_RATE_WINDOW_MS,
} from './limits';
import { type WireMessage, verifyWire } from './message';
import { SignalHub, addSignalingRoutes } from './signal';
import { addSoundRoutes } from './sound';
import { TunnelHub, addTunnelRoutes } from './tunnel';
import { VersionStore, addVersionRoutes } from './version';

interface StoredMessage {
  seq: number;
  message: WireMessage;
}

/**
 * In-memory channel store for the offline-courier endpoints. Self-hosted and
 * in-memory; a durable store can slot in behind the same interface later.
 */
export class RelayStore {
  private readonly byChannel = new Map<string, StoredMessage[]>();
  private seq = 0;

  append(message: WireMessage): number {
    const list = this.byChannel.get(message.channel) ?? [];
    const stored: StoredMessage = { seq: ++this.seq, message };
    list.push(stored);
    if (list.length > MAX_CHANNEL_MESSAGES) {
      list.splice(0, list.length - MAX_CHANNEL_MESSAGES);
    }
    this.byChannel.set(message.channel, list);
    // LRU eviction: if over the cap, drop the oldest-accessed channel.
    if (this.byChannel.size > MAX_CHANNELS) {
      const oldest = this.byChannel.keys().next().value!;
      this.byChannel.delete(oldest);
    }
    return stored.seq;
  }

  since(channel: string, since: number): StoredMessage[] {
    const list = this.byChannel.get(channel);
    if (!list) return [];
    // Touch: move to end for LRU ordering.
    this.byChannel.delete(channel);
    this.byChannel.set(channel, list);
    return list.filter((m) => m.seq > since);
  }
}

/**
 * The rendezvous relay as a portable Hono app — self-hosted (Docker, tunnelled).
 * It is a *dumb relay*: it verifies each message's signature + id (so it can't be
 * spammed with garbage) but never decrypts or owns history — the clients are the
 * source of truth.
 */
/** Extracts a Bearer token from the Authorization header, or null. */
function bearerToken(c: { req: { header(name: string): string | undefined } }): string | null {
  const h = c.req.header('authorization');
  if (!h?.startsWith('Bearer ')) return null;
  return h.slice(7);
}

export function createRelay(
  store: RelayStore = new RelayStore(),
  signalHub: SignalHub = new SignalHub(),
  versionStore: VersionStore = new VersionStore(),
  tunnelHub: TunnelHub = new TunnelHub(),
): Hono {
  const app = new Hono();

  // Allow the web app (served from a different localhost port) to call us.
  app.use('/*', cors());

  // Reject oversized bodies early — signals and messages are tiny.
  app.use('/*', async (c, next) => {
    const len = Number(c.req.header('content-length') ?? '0');
    if (Number.isFinite(len) && len > MAX_BODY_BYTES) {
      return c.json({ error: 'payload too large' }, 413);
    }
    await next();
  });

  app.get('/health', (c) => c.json({ ok: true }));

  // Per-IP global rate limit — catches keypair-rotating attackers. Applied to
  // all routes except /health (which load balancers hit frequently).
  const ipLimiter = new RateLimiter(IP_RATE_LIMIT, IP_RATE_WINDOW_MS);
  const limitIp: MiddlewareHandler = async (c, next) => {
    const ip =
      c.req.header('x-forwarded-for')?.split(',')[0]?.trim() ??
      c.req.header('x-real-ip') ??
      'unknown';
    if (!ipLimiter.allow(ip, Date.now())) {
      return c.json({ error: 'rate limited' }, 429);
    }
    await next();
  };
  app.use('/announce', limitIp);
  app.use('/signal', limitIp);
  app.use('/messages', limitIp);
  app.use('/poll', limitIp);
  app.use('/tunnel', limitIp);
  app.use('/gif/*', limitIp);
  app.use('/sound/*', limitIp);

  // WebRTC signalling + presence (POST /announce, GET /peers, POST/GET /signal).
  addSignalingRoutes(app, signalHub);

  // Cap the media-search proxies relay-wide so a stranger can't drain the provider
  // quota. Also requires a valid announce token (proves you're a Hearth client, not
  // a random scraper).
  const searchLimiter = new RateLimiter(SEARCH_RATE_LIMIT, SEARCH_RATE_WINDOW_MS);
  const limitSearch: MiddlewareHandler = async (c, next) => {
    const token = bearerToken(c) ?? c.req.query('token');
    if (!token || !signalHub.verifyToken(token, Date.now())) {
      return c.json({ error: 'token required' }, 403);
    }
    if (!searchLimiter.allow('search', Date.now())) {
      return c.json({ error: 'rate limited' }, 429);
    }
    await next();
  };
  app.use('/gif/*', limitSearch);
  app.use('/sound/*', limitSearch);

  // GIF search proxy (provider key stays on the relay, never in clients).
  addGifRoutes(app);

  // Sound search proxy (Freesound token stays on the relay; CC0-filtered).
  addSoundRoutes(app);

  // Signed release manifest (auto-update check).
  addVersionRoutes(app, versionStore);

  // Download proxy removed — repo is public, clients download directly from GitHub.

  // Relay tunnel for symmetric-NAT fallback (opaque ciphertext forwarding).
  addTunnelRoutes(app, tunnelHub, (token, nowMs) =>
    signalHub.verifyToken(token, nowMs),
  );

  // Accept a signed message: verify it, then store it.
  const messageLimiter = new RateLimiter(MESSAGE_RATE_LIMIT, MESSAGE_RATE_WINDOW_MS);
  app.post('/messages', async (c) => {
    let body: WireMessage;
    try {
      body = (await c.req.json()) as WireMessage;
    } catch {
      return c.json({ error: 'invalid json' }, 400);
    }
    // A malformed-but-valid-JSON body (missing/non-base64 fields) makes verifyWire
    // throw — treat that as unverifiable (400), not a 500.
    let ok = false;
    try {
      ok = await verifyWire(body);
    } catch {
      ok = false;
    }
    if (!ok) return c.json({ error: 'verification failed' }, 400);
    if (!messageLimiter.allow(body.author, Date.now())) {
      return c.json({ error: 'rate limited' }, 429);
    }
    return c.json({ ok: true, seq: store.append(body) });
  });

  // Short-poll: messages in a channel with seq greater than `since`.
  // Requires a valid announce token to prevent strangers from observing channel
  // activity (metadata leak).
  app.get('/poll', (c) => {
    const channel = c.req.query('channel');
    if (!channel) return c.json({ error: 'channel required' }, 400);
    const token = bearerToken(c) ?? c.req.query('token');
    if (!token) return c.json({ error: 'token required' }, 403);
    if (!signalHub.verifyToken(token, Date.now())) {
      return c.json({ error: 'invalid or expired token' }, 403);
    }
    const sinceRaw = Number(c.req.query('since') ?? '0');
    const since = Number.isFinite(sinceRaw) ? sinceRaw : 0;
    const fresh = store.since(channel, since);
    const messages = fresh.map((m) => ({ seq: m.seq, ...m.message }));
    const seq = fresh.length ? fresh[fresh.length - 1]!.seq : since;
    return c.json({ messages, seq });
  });

  return app;
}
