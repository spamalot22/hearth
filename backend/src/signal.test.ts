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
    const seq = hub.postSignal('bob', 'alice', 'offer', { sdp: 'x' });
    expect(seq).toBe(1);

    const got = hub.signalsSince('bob', 0);
    expect(got).toHaveLength(1);
    expect(got[0]!.from).toBe('alice');
    expect(hub.signalsSince('bob', seq)).toHaveLength(0); // cursor advanced
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

  it('announce -> peers -> signal round-trips', async () => {
    const app = createRelay();

    await postJson(app, '/announce', { channel: 'general', pubkey: 'alice' });
    await postJson(app, '/announce', { channel: 'general', pubkey: 'bob' });

    const peersRes = await app.request('/peers?channel=general&pubkey=alice');
    const peers = (await peersRes.json()) as { peers: string[] };
    expect(peers.peers).toContain('bob');

    await postJson(app, '/signal', {
      to: 'bob',
      from: 'alice',
      kind: 'offer',
      data: { sdp: 'x' },
    });

    const sigRes = await app.request('/signal?for=bob&since=0');
    const sig = (await sigRes.json()) as {
      signals: { from: string; kind: string }[];
      seq: number;
    };
    expect(sig.signals).toHaveLength(1);
    expect(sig.signals[0]!.from).toBe('alice');
    expect(sig.signals[0]!.kind).toBe('offer');
  });
});
