import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { createRelay } from './relay';

describe('GIF proxy', () => {
  const original = process.env.TENOR_KEY;

  beforeEach(() => {
    delete process.env.TENOR_KEY;
  });
  afterEach(() => {
    if (original === undefined) delete process.env.TENOR_KEY;
    else process.env.TENOR_KEY = original;
  });

  it('reports not-configured when the relay has no Tenor key', async () => {
    const res = await createRelay().request('/gif/search?q=cat');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ gifs: [], configured: false });
  });

  it('is configured (but empty) for a blank query — no upstream call', async () => {
    process.env.TENOR_KEY = 'fake-key';
    const res = await createRelay().request('/gif/search?q=');
    expect(await res.json()).toEqual({ gifs: [], configured: true });
  });
});
