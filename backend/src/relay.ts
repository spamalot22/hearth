// SPDX-License-Identifier: AGPL-3.0-or-later
import { Hono, type Handler, type MiddlewareHandler } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { randomBytes } from 'node:crypto';

import { addGifRoutes } from './gif';
import {
  IP_RATE_LIMIT,
  IP_RATE_WINDOW_MS,
  MAX_BODY_BYTES,
  MAX_CHANNEL_LENGTH,
  MAX_CHANNEL_MESSAGES,
  MAX_CHANNELS,
  MAX_POLL_MESSAGES,
  MAX_TOTAL_MESSAGES,
  MESSAGE_RATE_LIMIT,
  MESSAGE_RATE_WINDOW_MS,
  RateLimiter,
  SEARCH_RATE_LIMIT,
  SEARCH_RATE_WINDOW_MS,
} from './limits';
import { type WireMessage, verifyWire } from './message';
import { SignalHub, addSignalingRoutes } from './signal';
import { addSoundRoutes } from './sound';

interface StoredMessage {
  seq: number;
  message: WireMessage;
}

const RELAY_MAILBOX_HEADER = 'x-hearth-mailbox';

/**
 * In-memory capability-mailbox store for the offline-courier endpoints.
 * Self-hosted and in-memory; a durable store can slot in later.
 */
export class RelayStore {
  private readonly byChannel = new Map<string, StoredMessage[]>();
  private seq = 0;
  private messageCount = 0;

  append(message: WireMessage, mailbox = message.channel): number {
    const list = this.byChannel.get(mailbox) ?? [];
    this.byChannel.delete(mailbox);
    const duplicate = list.find((stored) => stored.message.id === message.id);
    if (duplicate) {
      // Retries are expected after ambiguous network failures. Touch the
      // mailbox for LRU purposes, but do not let one envelope consume capacity
      // repeatedly or advance cursors indefinitely.
      this.byChannel.set(mailbox, list);
      return duplicate.seq;
    }
    const stored: StoredMessage = { seq: ++this.seq, message };
    list.push(stored);
    this.messageCount++;
    if (list.length > MAX_CHANNEL_MESSAGES) {
      const removed = list.length - MAX_CHANNEL_MESSAGES;
      list.splice(0, removed);
      this.messageCount -= removed;
    }
    this.byChannel.set(mailbox, list);
    // LRU eviction: if over the cap, drop the oldest-accessed channel.
    while (
      this.byChannel.size > MAX_CHANNELS ||
      this.messageCount > MAX_TOTAL_MESSAGES
    ) {
      const oldest = this.byChannel.keys().next().value!;
      this.messageCount -= this.byChannel.get(oldest)?.length ?? 0;
      this.byChannel.delete(oldest);
    }
    return stored.seq;
  }

  since(
    channel: string,
    since: number,
    limit = MAX_POLL_MESSAGES,
  ): StoredMessage[] {
    const list = this.byChannel.get(channel);
    if (!list) return [];
    // Touch: move to end for LRU ordering.
    this.byChannel.delete(channel);
    this.byChannel.set(channel, list);
    const fresh: StoredMessage[] = [];
    for (const message of list) {
      if (message.seq <= since) continue;
      fresh.push(message);
      if (fresh.length >= limit) break;
    }
    return fresh;
  }

  latestSeq(channel: string): number {
    const list = this.byChannel.get(channel);
    return list?.at(-1)?.seq ?? 0;
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
  if (!h || h.length < 8 || h.slice(0, 7).toLowerCase() !== 'bearer ') return null;
  return h.slice(7);
}

export function createRelay(
  store: RelayStore = new RelayStore(),
  signalHub: SignalHub = new SignalHub(),
  relayEpoch = randomBytes(16).toString('hex'),
): Hono {
  const app = new Hono();

  // Allow the web app (served from a different localhost port) to call us.
  app.use('/*', cors());

  // Enforce the limit while reading streams too; Content-Length can be absent
  // for chunked requests and must not be the only resource boundary.
  app.use(
    '/*',
    bodyLimit({
      maxSize: MAX_BODY_BYTES,
      onError: (c) => c.json({ error: 'payload too large' }, 413),
    }),
  );

  app.get('/health', (c) => c.json({ ok: true, relayEpoch }));

  // Per-IP global rate limit — catches keypair-rotating attackers. Applied to
  // all routes except /health (which load balancers hit frequently).
  const ipLimiter = new RateLimiter(IP_RATE_LIMIT, IP_RATE_WINDOW_MS);
  const clientIp = (c: {
    req: { header(name: string): string | undefined };
  }): string => {
    // Reverse proxies append the connecting client to X-Forwarded-For. Use the
    // right-most value so a caller cannot evade the limiter by prepending a
    // different forged address to every request.
    const forwarded = c.req.header('x-forwarded-for')
      ?.split(',')
      .map((value) => value.trim())
      .filter(Boolean);
    return forwarded?.at(-1) ?? c.req.header('x-real-ip') ?? 'unknown';
  };
  const limitIp: MiddlewareHandler = async (c, next) => {
    const ip = clientIp(c);
    if (!ipLimiter.allow(ip, Date.now())) {
      return c.json({ error: 'rate limited' }, 429);
    }
    await next();
  };
  app.use('/announce', limitIp);
  app.use('/signal', limitIp);
  app.use('/messages', limitIp);
  app.use('/poll', limitIp);
  app.use('/v2/messages', limitIp);
  app.use('/v2/poll', limitIp);
  app.use('/gif/*', limitIp);
  app.use('/sound/*', limitIp);

  // WebRTC signalling + presence (POST /announce, GET /peers, POST/GET /signal).
  addSignalingRoutes(app, signalHub, relayEpoch);

  // Cap the media-search proxies relay-wide so a stranger can't drain the provider
  // quota. Also requires a valid announce token (proves you're a Hearth client, not
  // a random scraper).
  const searchLimiter = new RateLimiter(SEARCH_RATE_LIMIT, SEARCH_RATE_WINDOW_MS);
  const limitSearch: MiddlewareHandler = async (c, next) => {
    const token = bearerToken(c);
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

  // Accept a signed message: verify it, then store it.
  const messageLimiter = new RateLimiter(MESSAGE_RATE_LIMIT, MESSAGE_RATE_WINDOW_MS);
  const acceptMessage: Handler = async (c) => {
    const headerMailbox = c.req.header(RELAY_MAILBOX_HEADER);
    const versioned = c.req.path === '/v2/messages';
    const legacyMailbox = versioned ? undefined : c.req.query('mailbox');
    if (
      (versioned && headerMailbox === undefined) ||
      (headerMailbox !== undefined &&
        (!headerMailbox || headerMailbox.length > MAX_CHANNEL_LENGTH))
    ) {
      return c.json({ error: 'valid mailbox capability required' }, 400);
    }
    // Older clients only put private (hex) mailbox overrides in the query.
    if (
      legacyMailbox !== undefined &&
      !/^[0-9a-f]{32,64}$/.test(legacyMailbox)
    ) {
      return c.json({ error: 'valid mailbox capability required' }, 400);
    }
    const requestedMailbox = headerMailbox ?? legacyMailbox;
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
    return c.json({
      ok: true,
      seq: store.append(body, requestedMailbox ?? body.channel),
    });
  };
  app.post('/messages', acceptMessage);
  app.post('/v2/messages', acceptMessage);

  // Short-poll: messages in a channel with seq greater than `since`.
  // The mailbox ID (a random capability) is the auth — no token needed.
  const pollMessages: Handler = (c) => {
    const versioned = c.req.path === '/v2/poll';
    const channel =
      c.req.header(RELAY_MAILBOX_HEADER) ??
      (versioned ? undefined : c.req.query('channel'));
    if (!channel || channel.length > MAX_CHANNEL_LENGTH) {
      return c.json({ error: 'valid channel required' }, 400);
    }
    // No token required: the mailbox ID itself is an unguessable
    // capability — knowing it proves membership. Token-gating was
    // defence-in-depth but prevents background poll after token expiry.
    const sinceRaw = Number(c.req.query('since') ?? '0');
    const since = Number.isSafeInteger(sinceRaw) && sinceRaw >= 0 ? sinceRaw : 0;
    const fresh = store.since(channel, since, MAX_POLL_MESSAGES);
    const messages = fresh.map((m) => ({ seq: m.seq, ...m.message }));
    const seq = fresh.length ? fresh[fresh.length - 1]!.seq : since;
    const latestSeq = store.latestSeq(channel);
    return c.json({
      messages,
      seq,
      latestSeq,
      more: seq < latestSeq,
      relayEpoch,
    });
  };
  app.get('/poll', pollMessages);
  app.get('/v2/poll', pollMessages);

  return app;
}
