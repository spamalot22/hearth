import { Hono } from 'hono';
import { cors } from 'hono/cors';

import { type WireMessage, verifyWire } from './message';
import { SignalHub, addSignalingRoutes } from './signal';

interface StoredMessage {
  seq: number;
  message: WireMessage;
}

/**
 * In-memory channel store. Phase 1 only — this is the seam where Firestore
 * slots in later (same interface, durable + shared).
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
 * The rendezvous relay as a portable Hono app. Hosted on plain Node now, this
 * same app wraps as a Firebase Cloud Function later. It is a *dumb relay*: it
 * verifies each message's signature + id (so it can't be spammed with garbage)
 * but never decrypts or owns history — the clients are the source of truth.
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

  // Accept a signed message: verify it, then store it.
  app.post('/messages', async (c) => {
    let body: WireMessage;
    try {
      body = (await c.req.json()) as WireMessage;
    } catch {
      return c.json({ error: 'invalid json' }, 400);
    }
    if (!(await verifyWire(body))) {
      return c.json({ error: 'verification failed' }, 400);
    }
    return c.json({ ok: true, seq: store.append(body) });
  });

  // Short-poll: messages in a channel with seq greater than `since`.
  app.get('/poll', (c) => {
    const channel = c.req.query('channel');
    if (!channel) return c.json({ error: 'channel required' }, 400);
    const since = Number(c.req.query('since') ?? '0');
    const fresh = store.since(channel, since);
    const messages = fresh.map((m) => ({ seq: m.seq, ...m.message }));
    const seq = fresh.length ? fresh[fresh.length - 1]!.seq : since;
    return c.json({ messages, seq });
  });

  return app;
}
