import { Hono } from 'hono';

/**
 * GIF search, proxied through the relay so the API key lives server-side — set
 * `GIPHY_KEY` on the relay, never in clients. (We use Giphy: Google is
 * discontinuing the Tenor API in 2026.) With no key the search reports
 * not-configured and the client falls back to pasting a GIF URL.
 */
export function addGifRoutes(app: Hono): void {
  app.get('/gif/search', async (c) => {
    const key = process.env.GIPHY_KEY;
    if (!key) return c.json({ gifs: [], configured: false });
    const q = c.req.query('q')?.trim();
    if (!q) return c.json({ gifs: [], configured: true });

    const url = new URL('https://api.giphy.com/v1/gifs/search');
    url.search = new URLSearchParams({
      api_key: key,
      q,
      limit: '24',
      rating: 'pg-13',
    }).toString();

    try {
      const res = await fetch(url);
      if (!res.ok) return c.json({ gifs: [], configured: true }, 502);
      const data = (await res.json()) as {
        data?: Array<{ images?: Record<string, { url?: string }> }>;
      };
      const gifs = (data.data ?? [])
        .map((g) => {
          const images = g.images ?? {};
          const full = (images.downsized ?? images.fixed_height)?.url;
          const preview = (images.fixed_width_small ?? images.fixed_height)?.url;
          return full && preview ? { url: full, preview } : null;
        })
        .filter((g): g is { url: string; preview: string } => g !== null);
      return c.json({ gifs, configured: true });
    } catch {
      return c.json({ gifs: [], configured: true }, 502);
    }
  });
}
