// SPDX-License-Identifier: AGPL-3.0-or-later
/**
 * Resource bounds + a small rate limiter for the relay. The relay is public
 * (anyone with the URL can hit it), so these cap the damage a flood can do:
 * bounded memory, bounded payloads, and a ceiling on the media-search proxies so a
 * stranger can't drain your provider quota.
 */

/** Reject request bodies larger than this (signals/messages are tiny). */
export const MAX_BODY_BYTES = 64 * 1024;

/** Decoded encrypted payload limit; leaves room for its signed JSON envelope. */
export const MAX_MESSAGE_PAYLOAD_BYTES = 32 * 1024;

/** Maximum channel/capability identifier length accepted by relay routes. */
export const MAX_CHANNEL_LENGTH = 256;

/** Keep at most this many signals per (channel, recipient) mailbox. */
export const MAX_MAILBOX_SIGNALS = 64;

/** Global signal count across mailboxes (prevents aggregate memory exhaustion). */
export const MAX_TOTAL_SIGNALS = 10_000;

/** Keep at most this many courier messages per channel. */
export const MAX_CHANNEL_MESSAGES = 5000;

/** Maximum courier messages serialized in one poll response. */
export const MAX_POLL_MESSAGES = 100;

/** Global courier-message count across all channels. */
export const MAX_TOTAL_MESSAGES = 20_000;

/** Maximum unique channels before LRU eviction kicks in. */
export const MAX_CHANNELS = 10_000;

/** Media-search requests allowed per [SEARCH_RATE_WINDOW_MS] (relay-wide). */
export const SEARCH_RATE_LIMIT = 30;
export const SEARCH_RATE_WINDOW_MS = 60_000;

/** Per-pubkey: max signal POSTs per window (ICE candidates come in bursts). */
export const SIGNAL_RATE_LIMIT = 60;
export const SIGNAL_RATE_WINDOW_MS = 10_000;

/** Per-pubkey: max message POSTs per window. */
export const MESSAGE_RATE_LIMIT = 30;
export const MESSAGE_RATE_WINDOW_MS = 10_000;

/** Per-IP: global request cap (catches keypair-rotating attackers). */
export const IP_RATE_LIMIT = 60;
export const IP_RATE_WINDOW_MS = 60_000;

/** Per-pair tunnel fragments per window (a 10 MB blob needs about 350). */
export const TUNNEL_RATE_LIMIT = 600;
export const TUNNEL_RATE_WINDOW_MS = 60_000;

/** Per-IP tunnel requests per window; separate from lightweight relay routes. */
export const TUNNEL_IP_RATE_LIMIT = 1200;
export const TUNNEL_IP_RATE_WINDOW_MS = 60_000;

/**
 * A simple sliding-window rate limiter. Keyed (e.g. by pubkey, or a constant for a
 * relay-wide cap). `now` is passed in so it's deterministic to test. In-memory, so
 * it resets on restart — fine for a single-instance relay.
 */
export class RateLimiter {
  private readonly hits = new Map<string, number[]>();
  private static readonly MAX_KEYS = 10_000;

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
  ) {}

  /** True if [key] is under the limit right now; records the hit when allowed. */
  allow(key: string, nowMs: number): boolean {
    const fresh = (this.hits.get(key) ?? []).filter(
      (t) => nowMs - t < this.windowMs,
    );
    if (fresh.length >= this.limit) {
      this.hits.set(key, fresh);
      return false;
    }
    fresh.push(nowMs);
    this.hits.delete(key);
    this.hits.set(key, fresh);
    // Lazy prune: when the map grows large, drop keys with no recent hits.
    if (this.hits.size > 10_000) {
      for (const [k, v] of this.hits) {
        if (v.length === 0 || nowMs - v[v.length - 1]! > this.windowMs) {
          this.hits.delete(k);
        }
      }
      while (this.hits.size > RateLimiter.MAX_KEYS) {
        const oldest = this.hits.keys().next().value;
        if (oldest === undefined) break;
        this.hits.delete(oldest);
      }
    }
    return true;
  }
}
