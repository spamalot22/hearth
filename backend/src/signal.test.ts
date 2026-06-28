// SPDX-License-Identifier: AGPL-3.0-or-later
import { describe, expect, it } from 'vitest';

import { createRelay } from './relay';
import { SignalHub } from './signal';

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
    const peers = hub.announce('general', 'bob', Date.now());
    hub.announce('general', 'alice', Date.now());
    expect(peers).toEqual([]); // bob is first

    const aliceToken = hub.issueToken('alice', Date.now());
    const bobToken = hub.issueToken('bob', Date.now());

    await postJson(app, '/signal', {
      channel: 'general',
      to: 'bob',
      from: 'alice',
      kind: 'offer',
      data: { sdp: 'x' },
      token: aliceToken,
    });

    const sigRes = await app.request(
      `/signal?channel=general&for=bob&since=0&token=${bobToken}`,
    );
    const sig = (await sigRes.json()) as {
      signals: { from: string; kind: string }[];
      seq: number;
    };
    expect(sig.signals).toHaveLength(1);
    expect(sig.signals[0]!.from).toBe('alice');
    expect(sig.signals[0]!.kind).toBe('offer');
  });
});
