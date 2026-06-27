// SPDX-License-Identifier: AGPL-3.0-or-later
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { createRelay } from './relay';

describe('GIF proxy', () => {
  const original = process.env.GIPHY_KEY;

  beforeEach(() => {
    delete process.env.GIPHY_KEY;
  });
  afterEach(() => {
    if (original === undefined) delete process.env.GIPHY_KEY;
    else process.env.GIPHY_KEY = original;
  });

  it('reports not-configured when the relay has no Giphy key', async () => {
    const res = await createRelay().request('/gif/search?q=cat');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ gifs: [], configured: false });
  });

  it('is configured (but empty) for a blank query — no upstream call', async () => {
    process.env.GIPHY_KEY = 'fake-key';
    const res = await createRelay().request('/gif/search?q=');
    expect(await res.json()).toEqual({ gifs: [], configured: true });
  });
});
