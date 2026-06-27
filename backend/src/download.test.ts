// SPDX-License-Identifier: AGPL-3.0-or-later
import { Hono } from 'hono';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { addDownloadRoutes } from './download';

function appWith(config: { repo: string; token: string }): Hono {
  const app = new Hono();
  addDownloadRoutes(app, () => config);
  return app;
}

describe('download proxy', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('400 without version/asset', async () => {
    const res = await appWith({ repo: 'o/r', token: 't' }).request('/download');
    expect(res.status).toBe(400);
  });

  it('503 when no GitHub token is configured', async () => {
    const res = await appWith({ repo: '', token: '' }).request(
      '/download?version=0.2.0&asset=a.apk',
    );
    expect(res.status).toBe(503);
  });

  it('streams the asset bytes, authenticating to GitHub', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({ assets: [{ name: 'a.apk', url: 'https://api/asset/1' }] }),
          { status: 200 },
        ),
      )
      .mockResolvedValueOnce(new Response('BINARY', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const res = await appWith({ repo: 'o/r', token: 't' }).request(
      '/download?version=0.2.0&asset=a.apk',
    );
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('BINARY');
    expect(String(fetchMock.mock.calls[0]![0])).toContain('/releases/tags/0.2.0');
    expect(
      (fetchMock.mock.calls[0]![1] as RequestInit).headers,
    ).toMatchObject({ authorization: 'Bearer t' });
  });

  it('404 when the asset name is absent from the release', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ assets: [{ name: 'other.apk', url: 'x' }] }), {
          status: 200,
        }),
      );
    vi.stubGlobal('fetch', fetchMock);

    const res = await appWith({ repo: 'o/r', token: 't' }).request(
      '/download?version=0.2.0&asset=a.apk',
    );
    expect(res.status).toBe(404);
  });

  it('404 when the release tag is missing', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response('nope', { status: 404 }));
    vi.stubGlobal('fetch', fetchMock);

    const res = await appWith({ repo: 'o/r', token: 't' }).request(
      '/download?version=9.9.9&asset=a.apk',
    );
    expect(res.status).toBe(404);
  });
});
