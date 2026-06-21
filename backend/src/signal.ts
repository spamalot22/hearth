import { Hono } from 'hono';

/**
 * WebRTC signalling + presence for the relay. Peers announce themselves in a
 * channel, discover each other, and exchange SDP offers/answers + ICE
 * candidates through per-recipient mailboxes — just enough rendezvous to open a
 * direct peer-to-peer data channel, after which the backend is out of the loop.
 *
 * The relay is a dumb pipe — it does not verify `from`. Clients now sign each
 * signal with their Ed25519 identity and verify it on receipt (see the app's
 * `signal_auth`), so a malicious relay can't impersonate a peer or swap a DTLS
 * fingerprint. It can still see metadata (who announces, IPs) and drop traffic.
 */

const PRESENCE_TTL_MS = 15_000;
const SIGNAL_TTL_MS = 30_000;

interface StoredSignal {
  seq: number;
  from: string;
  kind: string; // 'offer' | 'answer' | 'ice'
  data: unknown;
  ts: number;
}

export class SignalHub {
  // channel -> (pubkey -> lastSeenMs)
  private readonly presence = new Map<string, Map<string, number>>();
  // recipient pubkey -> pending signals
  private readonly mailboxes = new Map<string, StoredSignal[]>();
  private seq = 0;

  /** Marks [pubkey] present in [channel] and returns the other live peers. */
  announce(channel: string, pubkey: string, nowMs: number): string[] {
    let chan = this.presence.get(channel);
    if (!chan) {
      chan = new Map();
      this.presence.set(channel, chan);
    }
    chan.set(pubkey, nowMs);
    return this.peers(channel, pubkey, nowMs);
  }

  /** Live peers in [channel], excluding [exclude] and anyone past the TTL. */
  peers(channel: string, exclude: string, nowMs: number): string[] {
    const chan = this.presence.get(channel);
    if (!chan) return [];
    const live: string[] = [];
    for (const [pubkey, seen] of chan) {
      if (nowMs - seen > PRESENCE_TTL_MS) {
        chan.delete(pubkey);
      } else if (pubkey !== exclude) {
        live.push(pubkey);
      }
    }
    return live;
  }

  postSignal(
    to: string,
    from: string,
    kind: string,
    data: unknown,
    nowMs: number,
  ): number {
    const box = this.mailboxes.get(to) ?? [];
    const stored: StoredSignal = {
      seq: ++this.seq,
      from,
      kind,
      data,
      ts: nowMs,
    };
    box.push(stored);
    this.mailboxes.set(to, box);
    return stored.seq;
  }

  // Returns fresh signals past [since], pruning ones older than the TTL so a
  // long-lived relay never replays stale offers to a freshly-loaded client.
  signalsSince(to: string, since: number, nowMs: number): StoredSignal[] {
    const box = this.mailboxes.get(to);
    if (!box) return [];
    const fresh = box.filter((s) => nowMs - s.ts <= SIGNAL_TTL_MS);
    if (fresh.length !== box.length) this.mailboxes.set(to, fresh);
    return fresh.filter((s) => s.seq > since);
  }
}

/** Mounts the signalling routes onto [app]. `now` is injectable for tests. */
export function addSignalingRoutes(
  app: Hono,
  hub: SignalHub,
  now: () => number = Date.now,
): void {
  // Announce presence in a channel; returns the other live peers to connect to.
  app.post('/announce', async (c) => {
    const body = (await c.req.json()) as { channel?: string; pubkey?: string };
    if (!body.channel || !body.pubkey) {
      return c.json({ error: 'channel and pubkey required' }, 400);
    }
    return c.json({ peers: hub.announce(body.channel, body.pubkey, now()) });
  });

  app.get('/peers', (c) => {
    const channel = c.req.query('channel');
    if (!channel) return c.json({ error: 'channel required' }, 400);
    const exclude = c.req.query('pubkey') ?? '';
    return c.json({ peers: hub.peers(channel, exclude, now()) });
  });

  // Drop an SDP/ICE signal into a recipient's mailbox.
  app.post('/signal', async (c) => {
    const body = (await c.req.json()) as {
      to?: string;
      from?: string;
      kind?: string;
      data?: unknown;
    };
    if (!body.to || !body.from || !body.kind) {
      return c.json({ error: 'to, from, kind required' }, 400);
    }
    const seq = hub.postSignal(body.to, body.from, body.kind, body.data, now());
    return c.json({ ok: true, seq });
  });

  // Short-poll a recipient's signal mailbox.
  app.get('/signal', (c) => {
    const forPubkey = c.req.query('for');
    if (!forPubkey) return c.json({ error: 'for required' }, 400);
    const since = Number(c.req.query('since') ?? '0');
    const signals = hub.signalsSince(forPubkey, since, now());
    const seq = signals.length ? signals[signals.length - 1]!.seq : since;
    return c.json({ signals, seq });
  });
}
