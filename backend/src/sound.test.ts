// SPDX-License-Identifier: AGPL-3.0-or-later
import * as ed from '@noble/ed25519';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { createRelay } from './relay';

async function getToken(app: ReturnType<typeof createRelay>): Promise<string> {
  const seed = ed.utils.randomPrivateKey();
  const pub = Buffer.from(await ed.getPublicKeyAsync(seed)).toString('hex');
  const ts = Date.now();
  const msg = new TextEncoder().encode(`announce|ch|${pub}|${ts}`);
  const sig = Buffer.from(await ed.signAsync(msg, seed)).toString('hex');
  const res = await app.request('/announce', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ channel: 'ch', pubkey: pub, ts, sig }),
  });
  return ((await res.json()) as { token: string }).token;
}

describe('Sound proxy', () => {
  const original = process.env.FREESOUND_KEY;

  beforeEach(() => {
    delete process.env.FREESOUND_KEY;
  });
  afterEach(() => {
    if (original === undefined) delete process.env.FREESOUND_KEY;
    else process.env.FREESOUND_KEY = original;
  });

  it('reports not-configured when the relay has no Freesound key', async () => {
    const app = createRelay();
    const token = await getToken(app);
    const res = await app.request(`/sound/search?q=airhorn&token=${token}`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ sounds: [], configured: false });
  });

  it('is configured (but empty) for a blank query — no upstream call', async () => {
    process.env.FREESOUND_KEY = 'fake-key';
    const app = createRelay();
    const token = await getToken(app);
    const res = await app.request(`/sound/search?q=&token=${token}`);
    expect(await res.json()).toEqual({ sounds: [], configured: true });
  });
});
