import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { createRelay } from './relay';

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
    const res = await createRelay().request('/sound/search?q=airhorn');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ sounds: [], configured: false });
  });

  it('is configured (but empty) for a blank query — no upstream call', async () => {
    process.env.FREESOUND_KEY = 'fake-key';
    const res = await createRelay().request('/sound/search?q=');
    expect(await res.json()).toEqual({ sounds: [], configured: true });
  });
});
