// SPDX-License-Identifier: AGPL-3.0-or-later
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
});

describe('signalling routes', () => {
  function postJson(
    app: ReturnType<typeof createRelay>,
    path: string,
    body: unknown,
  ) {
    return app.request(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
  }

  it('announce -> signal round-trips', async () => {
    const hub = new SignalHub();
    const app = createRelay(undefined, hub);

    // Announce directly via hub (bypasses signature check for unit test).
    const peers = hub.announce('general', bobHex, Date.now());
    hub.announce('general', aliceHex, Date.now());
    expect(peers).toEqual([]); // bob is first

    const aliceToken = hub.issueToken(aliceHex, Date.now());
    const bobToken = hub.issueToken(bobHex, Date.now());

    await postJson(app, '/signal', {
      channel: 'general',
      to: bobHex,
      from: aliceHex,
      kind: 'offer',
      data: { sdp: 'x' },
      token: aliceToken,
    });

    const sigRes = await app.request(
      `/signal?channel=general&for=${bobHex}&since=0&token=${bobToken}`,
    );
    const sig = (await sigRes.json()) as {
      signals: { from: string; kind: string }[];
      seq: number;
    };
    expect(sig.signals).toHaveLength(1);
    expect(sig.signals[0]!.from).toBe(aliceHex);
    expect(sig.signals[0]!.kind).toBe('offer');
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

    const badKind = await postJson(app, '/signal', {
      channel: 'general',
      to: bobHex,
      from: aliceHex,
      kind: 'restart',
      data: {},
      token: aliceToken,
    });
    expect(badKind.status).toBe(400);
  });
});
