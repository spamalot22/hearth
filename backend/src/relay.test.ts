// SPDX-License-Identifier: AGPL-3.0-or-later
import * as ed from '@noble/ed25519';
import { describe, expect, it } from 'vitest';

import {
  computeId,
  signedBytes,
  type MessageFields,
  type WireMessage,
  verifyWire,
} from './message';
import { IP_RATE_LIMIT } from './limits';
import { createRelay, RelayStore } from './relay';

function b64url(b: Uint8Array): string {
  return Buffer.from(b).toString('base64url');
}

/** Builds a properly signed wire message from a fresh random identity. */
async function makeWire(text: string, channel = 'general'): Promise<WireMessage> {
  const seed = ed.utils.randomPrivateKey();
  const author = await ed.getPublicKeyAsync(seed);
  const fields: MessageFields = {
    version: 1,
    author,
    channel,
    prev: [],
    timestampMs: Date.now(),
    payload: new TextEncoder().encode(text),
  };
  const content = signedBytes(fields);
  return {
    v: fields.version,
    author: b64url(author),
    channel,
    prev: [],
    timestamp: fields.timestampMs,
    payload: b64url(fields.payload),
    sig: b64url(await ed.signAsync(content, seed)),
    id: b64url(computeId(content)),
  };
}

function post(app: ReturnType<typeof createRelay>, wire: WireMessage) {
  return app.request('/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(wire),
  });
}

/** Performs a signed announce and returns the auth token. */
async function getToken(
  app: ReturnType<typeof createRelay>,
  channel = 'general',
): Promise<string> {
  const seed = ed.utils.randomPrivateKey();
  const pubkey = await ed.getPublicKeyAsync(seed);
  const pubkeyHex = Buffer.from(pubkey).toString('hex');
  const ts = Date.now();
  const msg = new TextEncoder().encode(
    `announce|${channel}|${pubkeyHex}|${ts}`,
  );
  const sig = Buffer.from(await ed.signAsync(msg, seed)).toString('hex');
  const res = await app.request('/announce', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ channel, pubkey: pubkeyHex, ts, sig }),
  });
  const body = (await res.json()) as { token: string };
  return body.token;
}

describe('relay', () => {
  it('accepts a valid message and returns it on poll', async () => {
    const app = createRelay();
    const wire = await makeWire('hello');

    expect((await post(app, wire)).status).toBe(200);

    const res = await app.request('/poll?channel=general&since=0');
    const data = (await res.json()) as { messages: WireMessage[]; seq: number };
    expect(data.messages).toHaveLength(1);
    expect(data.messages[0]!.id).toBe(wire.id);
    expect(data.seq).toBe(1);
  });

  it('rejects a tampered message', async () => {
    const app = createRelay();
    const wire = await makeWire('hello');
    wire.payload = Buffer.from('goodbye').toString('base64url'); // forge content

    expect((await post(app, wire)).status).toBe(400);
  });

  it('rejects a malformed body with 400, not 500', async () => {
    const app = createRelay();
    // Valid JSON but missing the signed fields — verifyWire throws on these; the
    // relay must treat that as unverifiable (400), not crash into a 500.
    const res = await app.request('/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ hello: 'world' }),
    });

    expect(res.status).toBe(400);
  });

  it('returns false for non-string parent ids without throwing', async () => {
    const wire = await makeWire('hello');
    (wire as unknown as { prev: unknown[] }).prev = [123];
    await expect(verifyWire(wire)).resolves.toBe(false);
  });

  it('rejects oversized poll channel identifiers', async () => {
    const app = createRelay();
    const channel = 'x'.repeat(257);
    expect((await app.request(`/poll?channel=${channel}`)).status).toBe(400);
  });

  it('returns only messages newer than `since`', async () => {
    const app = createRelay();
    await post(app, await makeWire('m1'));
    const first = (await (await app.request(
      '/poll?channel=general&since=0',
    )).json()) as { seq: number };

    await post(app, await makeWire('m2'));
    const second = (await (await app.request(
      `/poll?channel=general&since=${first.seq}`,
    )).json()) as { messages: WireMessage[] };

    expect(second.messages).toHaveLength(1);
  });

  it('reports one relay epoch across health and courier polling', async () => {
    const app = createRelay(undefined, undefined, undefined, 'test-epoch');
    const health = (await (await app.request('/health')).json()) as {
      relayEpoch: string;
    };
    const poll = (await (await app.request(
      '/poll?channel=general&since=0',
    )).json()) as { relayEpoch: string };

    expect(health.relayEpoch).toBe('test-epoch');
    expect(poll.relayEpoch).toBe('test-epoch');
  });

  it('paginates large backlogs and exposes the channel head', async () => {
    const store = new RelayStore();
    const wire = await makeWire('message');
    for (let i = 0; i < 105; i++) store.append(wire);
    const app = createRelay(store);

    const first = (await (await app.request(
      '/poll?channel=general&since=0',
    )).json()) as {
      messages: WireMessage[];
      seq: number;
      latestSeq: number;
      more: boolean;
    };
    expect(first.messages).toHaveLength(100);
    expect(first.seq).toBe(100);
    expect(first.latestSeq).toBe(105);
    expect(first.more).toBe(true);

    const second = (await (await app.request(
      `/poll?channel=general&since=${first.seq}`,
    )).json()) as typeof first;
    expect(second.messages).toHaveLength(5);
    expect(second.seq).toBe(105);
    expect(second.more).toBe(false);
  });

  it('rejects an oversized body with 413', async () => {
    const app = createRelay();
    const body = 'x'.repeat(70 * 1024); // > MAX_BODY_BYTES (64 KiB)
    const res = await app.request('/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': String(body.length),
      },
      body,
    });

    expect(res.status).toBe(413);
  });

  it('rejects an oversized streaming body without Content-Length', async () => {
    const app = createRelay();
    const chunk = new TextEncoder().encode('x'.repeat(70 * 1024));
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(chunk);
        controller.close();
      },
    });
    const request = new Request('http://localhost/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
      // Required by Node's Request implementation for streaming request bodies.
      duplex: 'half',
    } as RequestInit & { duplex: 'half' });

    expect((await app.request(request)).status).toBe(413);
  });

  it('rate-limits the media-search proxy', async () => {
    const app = createRelay();
    const token = await getToken(app);
    let limited = false;
    for (let i = 0; i < 40; i++) {
      const res = await app.request('/gif/search?q=x', {
        headers: { authorization: `Bearer ${token}` },
      });
      if (res.status === 429) {
        limited = true;
        break;
      }
    }

    expect(limited).toBe(true);
  });

  it('cannot bypass the IP limiter with forged forwarded prefixes', async () => {
    const app = createRelay();
    let lastStatus = 0;
    for (let i = 0; i <= IP_RATE_LIMIT; i++) {
      const res = await app.request('/poll?channel=general', {
        headers: {
          'x-forwarded-for': `198.51.100.${i}, 203.0.113.10`,
        },
      });
      lastStatus = res.status;
    }

    expect(lastStatus).toBe(429);
  });

  it('allows a shared NAT bootstrap burst without starving signalling', async () => {
    const app = createRelay();
    for (let i = 0; i < 100; i++) {
      const route = i % 2 === 0
        ? '/poll?channel=general'
        : `/signal?channel=general&for=${'a'.repeat(64)}`;
      const res = await app.request(route, {
        headers: { 'x-forwarded-for': '198.51.100.2, 203.0.113.10' },
      });
      expect(res.status).not.toBe(429);
    }
  });
});
