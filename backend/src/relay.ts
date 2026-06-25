import { Hono } from 'hono';
import { cors } from 'hono/cors';

import { addGifRoutes } from './gif';
import { type WireMessage, verifyWire } from './message';
import { SignalHub, addSignalingRoutes } from './signal';
import { addSoundRoutes } from './sound';

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
    this.byChannel.set(message.channel, list);
    return stored.seq;
  }

  since(channel: string, since: number): StoredMessage[] {
    return (this.byChannel.get(channel) ?? []).filter((m) => m.seq > since);
  }
}

/**
 * The rendezvous relay as a portable Hono app — self-hosted (Docker, tunnelled).
 * It is a *dumb relay*: it verifies each message's signature + id (so it can't be
 * spammed with garbage) but never decrypts or owns history — the clients are the
 * source of truth.
 */
export function createRelay(
  store: RelayStore = new RelayStore(),
  signalHub: SignalHub = new SignalHub(),
): Hono {
  const app = new Hono();

  // Allow the web app (served from a different localhost port) to call us.
  app.use('/*', cors());

  app.get('/health', (c) => c.json({ ok: true }));

  // WebRTC signalling + presence (POST /announce, GET /peers, POST/GET /signal).
  addSignalingRoutes(app, signalHub);

  // GIF search proxy (provider key stays on the relay, never in clients).
  addGifRoutes(app);

  // Sound search proxy (Freesound token stays on the relay; CC0-filtered).
  addSoundRoutes(app);

  // Accept a signed message: verify it, then store it.
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
    return c.json({ ok: true, seq: store.append(body) });
  });

  // Short-poll: messages in a channel with seq greater than `since`.
  app.get('/poll', (c) => {
    const channel = c.req.query('channel');
    if (!channel) return c.json({ error: 'channel required' }, 400);
    const sinceRaw = Number(c.req.query('since') ?? '0');
    const since = Number.isFinite(sinceRaw) ? sinceRaw : 0;
    const fresh = store.since(channel, since);
    const messages = fresh.map((m) => ({ seq: m.seq, ...m.message }));
    const seq = fresh.length ? fresh[fresh.length - 1]!.seq : since;
    return c.json({ messages, seq });
  });

  return app;
}
