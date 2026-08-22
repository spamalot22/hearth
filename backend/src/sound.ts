// SPDX-License-Identifier: AGPL-3.0-or-later
import { Hono } from 'hono';

const MAX_QUERY_LENGTH = 100;
const PROVIDER_TIMEOUT_MS = 5000;

function isHttpsUrl(value: string | undefined): value is string {
  if (!value) return false;
  try {
    return new URL(value).protocol === 'https:';
  } catch {
    return false;
  }
}

/**
 * Freesound search, proxied through the relay so the API token stays server-side
 * — set `FREESOUND_KEY` on the relay, never in clients. Filtered to Creative
 * Commons 0 so every result is safe to redistribute P2P. With no key the search
 * reports not-configured (the client then just shows nothing / uploads instead).
 */
export function addSoundRoutes(app: Hono): void {
  app.get('/sound/search', async (c) => {
    const key = process.env.FREESOUND_KEY;
    if (!key) return c.json({ sounds: [], configured: false });
    const q = c.req.query('q')?.trim();
    if (!q) return c.json({ sounds: [], configured: true });
    if (q.length > MAX_QUERY_LENGTH) {
      return c.json({ error: 'query too long' }, 400);
    }

    const url = new URL('https://freesound.org/apiv2/search/text/');
    url.search = new URLSearchParams({
      query: q,
      token: key,
      filter: 'license:"Creative Commons 0"',
      fields: 'name,previews',
      page_size: '24',
    }).toString();

    try {
      const res = await fetch(url, {
        signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      });
      if (!res.ok) return c.json({ sounds: [], configured: true }, 502);
      const data = (await res.json()) as {
        results?: Array<{ name?: string; previews?: Record<string, string> }>;
      };
      const sounds = (data.results ?? [])
        .map((r) => {
          const preview =
            r.previews?.['preview-hq-mp3'] ?? r.previews?.['preview-lq-mp3'];
          return r.name && isHttpsUrl(preview)
            ? { name: r.name.slice(0, 200), preview }
            : null;
        })
        .filter((s): s is { name: string; preview: string } => s !== null);
      return c.json({ sounds, configured: true });
    } catch {
      return c.json({ sounds: [], configured: true }, 502);
    }
  });
}
