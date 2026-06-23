import { Hono } from 'hono';

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

    const url = new URL('https://freesound.org/apiv2/search/text/');
    url.search = new URLSearchParams({
      query: q,
      token: key,
      filter: 'license:"Creative Commons 0"',
      fields: 'name,previews',
      page_size: '24',
    }).toString();

    try {
      const res = await fetch(url);
      if (!res.ok) return c.json({ sounds: [], configured: true }, 502);
      const data = (await res.json()) as {
        results?: Array<{ name?: string; previews?: Record<string, string> }>;
      };
      const sounds = (data.results ?? [])
        .map((r) => {
          const preview =
            r.previews?.['preview-hq-mp3'] ?? r.previews?.['preview-lq-mp3'];
          return r.name && preview ? { name: r.name, preview } : null;
        })
        .filter((s): s is { name: string; preview: string } => s !== null);
      return c.json({ sounds, configured: true });
    } catch {
      return c.json({ sounds: [], configured: true }, 502);
    }
  });
}
