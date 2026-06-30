// SPDX-License-Identifier: AGPL-3.0-or-later
import { Hono } from 'hono';
import { randomBytes } from 'node:crypto';

import {
  MAX_CHANNELS,
  MAX_MAILBOX_SIGNALS,
  RateLimiter,
  SIGNAL_RATE_LIMIT,
  SIGNAL_RATE_WINDOW_MS,
} from './limits';
import { hexToBytes, verifySignature } from './message';

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
const TOKEN_TTL_MS = 30 * 60_000; // 30 minutes — long enough for background fetch cycles

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
  // Auth tokens: token -> { pubkey, expiresMs }
  private readonly tokens = new Map<string, { pubkey: string; expiresMs: number }>();
  private seq = 0;

  /** Marks [pubkey] present in [channel] and returns the other live peers. */
  announce(channel: string, pubkey: string, nowMs: number): string[] {
    let chan = this.presence.get(channel);
    if (!chan) {
      chan = new Map();
      // LRU eviction: cap unique channels in the presence map.
      if (this.presence.size > MAX_CHANNELS) {
        const oldest = this.presence.keys().next().value!;
        this.presence.delete(oldest);
      }
    } else {
      // Touch: move to end for LRU ordering.
      this.presence.delete(channel);
    }
    this.presence.set(channel, chan);
    chan.set(pubkey, nowMs);
    return this.peers(channel, pubkey, nowMs);
  }

  /** Issues a short-lived token for [pubkey], valid for TOKEN_TTL_MS. */
  issueToken(pubkey: string, nowMs: number): string {
    const token = randomBytes(16).toString('hex');
    this.tokens.set(token, { pubkey, expiresMs: nowMs + TOKEN_TTL_MS });
    // Prune expired tokens lazily (keep map bounded).
    if (this.tokens.size > 1000) {
      for (const [t, v] of this.tokens) {
        if (v.expiresMs < nowMs) this.tokens.delete(t);
      }
    }
    return token;
  }

  /** Returns the pubkey for [token] if valid and unexpired, else null. */
  verifyToken(token: string, nowMs: number): string | null {
    const entry = this.tokens.get(token);
    if (!entry || entry.expiresMs < nowMs) {
      if (entry) this.tokens.delete(token);
      return null;
    }
    return entry.pubkey;
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

  // Mailboxes are keyed by (channel, recipient): a peer runs one connection per
  // channel, so signals must not leak across channels — otherwise one channel's
  // mesh grabs another's offer and the handshake cross-talks.
  private mailboxKey(channel: string, to: string): string {
    return `${channel}\0${to}`;
  }

  postSignal(
    channel: string,
    to: string,
    from: string,
    kind: string,
    data: unknown,
    nowMs: number,
  ): number {
    const key = this.mailboxKey(channel, to);
    const box = this.mailboxes.get(key) ?? [];
    const stored: StoredSignal = {
      seq: ++this.seq,
      from,
      kind,
      data,
      ts: nowMs,
    };
    box.push(stored);
    if (box.length > MAX_MAILBOX_SIGNALS) {
      box.splice(0, box.length - MAX_MAILBOX_SIGNALS);
    }
    this.mailboxes.set(key, box);
    return stored.seq;
  }

  // Returns fresh signals past [since], pruning ones older than the TTL so a
  // long-lived relay never replays stale offers to a freshly-loaded client.
  signalsSince(
    channel: string,
    to: string,
    since: number,
    nowMs: number,
  ): StoredSignal[] {
    const key = this.mailboxKey(channel, to);
    const box = this.mailboxes.get(key);
    if (!box) return [];
    const fresh = box.filter((s) => nowMs - s.ts <= SIGNAL_TTL_MS);
    if (fresh.length !== box.length) this.mailboxes.set(key, fresh);
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
  // Requires an Ed25519 signature over "announce|<channel>|<pubkey>|<ts>".
  app.post('/announce', async (c) => {
    const body = (await c.req.json()) as {
      channel?: string;
      pubkey?: string;
      ts?: number;
      sig?: string;
    };
    if (!body.channel || !body.pubkey) {
      return c.json({ error: 'channel and pubkey required' }, 400);
    }
    // Verify identity: sig over "announce|channel|pubkey|ts".
    if (body.sig && body.ts) {
      const msg = new TextEncoder().encode(
        `announce|${body.channel}|${body.pubkey}|${body.ts}`,
      );
      const valid = await verifySignature(
        msg,
        hexToBytes(body.sig),
        hexToBytes(body.pubkey),
      );
      if (!valid) return c.json({ error: 'invalid signature' }, 403);
      // Reject stale timestamps (>30s old).
      if (Math.abs(now() - body.ts) > 30_000) {
        return c.json({ error: 'timestamp too old' }, 403);
      }
      const peers = hub.announce(body.channel, body.pubkey, now());
      const token = hub.issueToken(body.pubkey, now());
      return c.json({ peers, token });
    }
    // Unsigned announce — reject (no backward compat needed).
    return c.json({ error: 'signature required' }, 403);
  });

  // Drop an SDP/ICE signal into a recipient's mailbox.
  const signalLimiter = new RateLimiter(SIGNAL_RATE_LIMIT, SIGNAL_RATE_WINDOW_MS);
  app.post('/signal', async (c) => {
    const body = (await c.req.json()) as {
      channel?: string;
      to?: string;
      from?: string;
      kind?: string;
      data?: unknown;
      token?: string;
    };
    if (!body.channel || !body.to || !body.from || !body.kind) {
      return c.json({ error: 'channel, to, from, kind required' }, 400);
    }
    // Authenticate sender via token.
    if (!body.token) return c.json({ error: 'token required' }, 403);
    const owner = hub.verifyToken(body.token, now());
    if (owner !== body.from) {
      return c.json({ error: 'invalid or expired token' }, 403);
    }
    if (!signalLimiter.allow(body.from, now())) {
      return c.json({ error: 'rate limited' }, 429);
    }
    const seq = hub.postSignal(
      body.channel,
      body.to,
      body.from,
      body.kind,
      body.data,
      now(),
    );
    return c.json({ ok: true, seq });
  });

  // Short-poll a recipient's per-channel signal mailbox. Requires a valid token
  // from a signed announce (proves you own the pubkey you're reading).
  app.get('/signal', (c) => {
    const channel = c.req.query('channel');
    const forPubkey = c.req.query('for');
    const token = c.req.query('token');
    if (!channel || !forPubkey) {
      return c.json({ error: 'channel and for required' }, 400);
    }
    if (!token) return c.json({ error: 'token required' }, 403);
    const owner = hub.verifyToken(token, now());
    if (owner !== forPubkey) {
      return c.json({ error: 'invalid or expired token' }, 403);
    }
    const sinceRaw = Number(c.req.query('since') ?? '0');
    const since = Number.isFinite(sinceRaw) ? sinceRaw : 0;
    const signals = hub.signalsSince(channel, forPubkey, since, now());
    const seq = signals.length ? signals[signals.length - 1]!.seq : since;
    return c.json({ signals, seq });
  });
}
