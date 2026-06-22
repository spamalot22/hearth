import { Hono } from 'hono';

/**
 * Tenor GIF search, proxied through the relay so the API key lives server-side
 * — set `TENOR_KEY` on the relay (the operator's concern, one key), never in
 * clients. With no key configured the search just returns empty, i.e. the
 * feature is unavailable on this relay; everything else still works.
 */
export function addGifRoutes(app: Hono): void {
  app.get('/gif/search', async (c) => {
    const key = process.env.TENOR_KEY;
    if (!key) return c.json({ gifs: [], configured: false });
    const q = c.req.query('q')?.trim();
    if (!q) return c.json({ gifs: [], configured: true });

    const url = new URL('https://tenor.googleapis.com/v2/search');
    url.search = new URLSearchParams({
      key,
      q,
      limit: '24',
      media_filter: 'gif,tinygif',
      contentfilter: 'medium',
    }).toString();

    try {
      const res = await fetch(url);
      if (!res.ok) return c.json({ gifs: [], configured: true }, 502);
      const data = (await res.json()) as {
        results?: Array<{ media_formats?: Record<string, { url?: string }> }>;
      };
      const gifs = (data.results ?? [])
        .map((r) => {
          const formats = r.media_formats ?? {};
          const full = formats.gif?.url;
          const preview = (formats.tinygif ?? formats.gif)?.url;
          return full && preview ? { url: full, preview } : null;
        })
        .filter((g): g is { url: string; preview: string } => g !== null);
      return c.json({ gifs, configured: true });
    } catch {
      return c.json({ gifs: [], configured: true }, 502);
    }
  });
}
