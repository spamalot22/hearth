// SPDX-License-Identifier: AGPL-3.0-or-later
import * as ed from '@noble/ed25519';
import { describe, expect, it } from 'vitest';

import { createRelay } from './relay';
import { SignalHub } from './signal';

const aliceHex = 'a'.repeat(64);
const bobHex = 'b'.repeat(64);

describe('SignalHub', () => {
  it('announce returns other live peers, excluding self', () => {
    const hub = new SignalHub();
    expect(hub.announce('general', 'alice', 1000)).toEqual([]);
    expect(hub.announce('general', 'bob', 1000)).toEqual(['alice']);
    expect(hub.announce('general', 'alice', 1000)).toEqual(['bob']);
  });

  it('drops peers past the presence TTL', () => {
    const hub = new SignalHub();
    hub.announce('general', 'alice', 0);
    hub.announce('general', 'bob', 0);
    // 20s later only bob is live; alice has expired.
    expect(hub.announce('general', 'bob', 20_000)).toEqual([]);
  });

  it('returns signed claims only while their peer is live', () => {
    const hub = new SignalHub();
    const claim = { pubkey: aliceHex, ts: 1000, sig: 'c'.repeat(128) };
    hub.announce('general', aliceHex, 1000, claim);

    expect(hub.peerPresence('general', bobHex, 1000)).toEqual([claim]);
    expect(hub.peerPresence('general', bobHex, 20_000)).toEqual([]);
  });

  it('delivers signals to a recipient mailbox by cursor', () => {
    const hub = new SignalHub();
    const seq = hub.postSignal('general', 'bob', 'alice', 'offer', { sdp: 'x' }, 1000);
    expect(seq).toBe(1);

    const got = hub.signalsSince('general', 'bob', 0, 1000);
    expect(got).toHaveLength(1);
    expect(got[0]!.from).toBe('alice');
    expect(hub.signalsSince('general', 'bob', seq, 1000)).toHaveLength(0);
  });

  it('isolates signals by channel', () => {
    const hub = new SignalHub();
    hub.postSignal('general', 'bob', 'alice', 'offer', { sdp: 'g' }, 1000);
    // Bob's 'games' mailbox must not see the 'general' offer.
    expect(hub.signalsSince('games', 'bob', 0, 1000)).toHaveLength(0);
    expect(hub.signalsSince('general', 'bob', 0, 1000)).toHaveLength(1);
  });

  it('prunes signals older than the TTL', () => {
    const hub = new SignalHub();
    hub.postSignal('general', 'bob', 'alice', 'offer', { sdp: 'x' }, 0);
    expect(hub.signalsSince('general', 'bob', 0, 40_000)).toHaveLength(0);
  });

  it('bounds the live token map by evicting the oldest token', () => {
    const hub = new SignalHub();
    const oldest = hub.issueToken('oldest', 1000);
    for (let i = 0; i < 1000; i++) hub.issueToken(`peer-${i}`, 1000);

    expect(hub.verifyToken(oldest, 1001)).toBeNull();
  });
});

describe('signalling routes', () => {
  function postJson(
    app: ReturnType<typeof createRelay>,
    path: string,
    body: unknown,
    token?: string,
  ) {
    return app.request(path, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });
  }

  async function signedAnnounce(
    channel: string,
    cap?: string,
    voice = false,
  ) {
    const seed = ed.utils.randomPrivateKey();
    const pubkey = Buffer.from(await ed.getPublicKeyAsync(seed)).toString('hex');
    const ts = Date.now();
    const sig = Buffer.from(
      await ed.signAsync(
        new TextEncoder().encode(`announce|${channel}|${pubkey}|${ts}`),
        seed,
      ),
    ).toString('hex');
    const voiceSig = voice
      ? Buffer.from(
        await ed.signAsync(
          new TextEncoder().encode(
            `voice-presence|${channel}|${pubkey}|${ts}|1`,
          ),
          seed,
        ),
      ).toString('hex')
      : undefined;
    return {
      channel,
      pubkey,
      ts,
      sig,
      ...(cap ? { cap } : {}),
      ...(voiceSig ? { voice: true, voiceSig } : {}),
    };
  }

  it('returns verifiable relay-presence evidence unchanged', async () => {
    const app = createRelay();
    const channel = 'presence-room';
    const cap = 'd'.repeat(64);
    const alice = await signedAnnounce(channel, cap);
    const bob = await signedAnnounce(channel);

    expect((await postJson(app, '/announce', alice)).status).toBe(200);
    const response = await postJson(app, '/announce', bob);
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      peers: string[];
      presence: Array<{ pubkey: string; ts: number; sig: string; cap?: string }>;
    };

    expect(body.peers).toContain(alice.pubkey);
    expect(body.presence).toEqual([
      {
        pubkey: alice.pubkey,
        ts: alice.ts,
        sig: alice.sig,
        cap,
      },
    ]);
  });

  it('rejects malformed relay-presence capabilities', async () => {
    const app = createRelay();
    const claim = await signedAnnounce('presence-room');
    const response = await postJson(app, '/announce', {
      ...claim,
      cap: 'not-a-capability',
    });

    expect(response.status).toBe(400);
  });

  it('relays only correctly signed voice presence assertions', async () => {
    const app = createRelay();
    const channel = 'voice-status-room';
    const alice = await signedAnnounce(channel, undefined, true);
    const bob = await signedAnnounce(channel);

    expect((await postJson(app, '/announce', alice)).status).toBe(200);
    const response = await postJson(app, '/announce', bob);
    const body = (await response.json()) as {
      presence: Array<{ voice?: boolean; voiceSig?: string }>;
    };
    expect(body.presence[0]?.voice).toBe(true);
    expect(body.presence[0]?.voiceSig).toBe(alice.voiceSig);

    const forged = await signedAnnounce('forged-voice-room');
    const rejected = await postJson(app, '/announce', {
      ...forged,
      voice: true,
      voiceSig: '0'.repeat(128),
    });
    expect(rejected.status).toBe(403);
  });

  it('announce -> signal round-trips', async () => {
    const hub = new SignalHub();
    const app = createRelay(undefined, hub);

    // Announce directly via hub (bypasses signature check for unit test).
    const peers = hub.announce('general', bobHex, Date.now());
    hub.announce('general', aliceHex, Date.now());
    expect(peers).toEqual([]); // bob is first

    const aliceToken = hub.issueToken(aliceHex, Date.now());
    const bobToken = hub.issueToken(bobHex, Date.now());

    await postJson(
      app,
      '/signal',
      {
        channel: 'general',
        to: bobHex,
        from: aliceHex,
        kind: 'offer',
        data: { sdp: 'x' },
      },
      aliceToken,
    );

    const sigRes = await app.request(
      `/signal?channel=general&for=${bobHex}&since=0`,
      {
        headers: { authorization: `Bearer ${bobToken}` },
      },
    );
    const sig = (await sigRes.json()) as {
      signals: { from: string; kind: string }[];
      seq: number;
      relayEpoch: string;
    };
    expect(sig.signals).toHaveLength(1);
    expect(sig.signals[0]!.from).toBe(aliceHex);
    expect(sig.signals[0]!.kind).toBe('offer');
    expect(sig.relayEpoch).toMatch(/^[0-9a-f]{32}$/);
  });

  it('rejects malformed signal json and invalid signal kinds', async () => {
    const hub = new SignalHub();
    const app = createRelay(undefined, hub);
    const aliceToken = hub.issueToken(aliceHex, Date.now());

    const malformed = await app.request('/signal', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{',
    });
    expect(malformed.status).toBe(400);

    const badKind = await postJson(
      app,
      '/signal',
      {
        channel: 'general',
        to: bobHex,
        from: aliceHex,
        kind: 'restart',
        data: {},
      },
      aliceToken,
    );
    expect(badKind.status).toBe(400);
  });

  it('rejects oversized signalling channel identifiers', async () => {
    const hub = new SignalHub();
    const app = createRelay(undefined, hub);
    const aliceToken = hub.issueToken(aliceHex, Date.now());
    const oversized = 'x'.repeat(257);

    const posted = await postJson(
      app,
      '/signal',
      {
        channel: oversized,
        to: bobHex,
        from: aliceHex,
        kind: 'offer',
        data: {},
      },
      aliceToken,
    );
    expect(posted.status).toBe(400);

    const polled = await app.request(
      `/signal?channel=${oversized}&for=${aliceHex}`,
      { headers: { authorization: `Bearer ${aliceToken}` } },
    );
    expect(polled.status).toBe(400);
  });
});
