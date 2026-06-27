// SPDX-License-Identifier: AGPL-3.0-or-later
import type { Hono } from 'hono';

/**
 * Release download proxy. The app binaries live on a *private* GitHub repo, so
 * clients can't fetch them directly. The relay holds a read-only GitHub token and
 * streams the requested release asset through — the token never leaves the relay,
 * and the bytes are verified client-side against the signed manifest's SHA-256, so
 * a tampering relay would be caught.
 *
 * Open by design: anyone who can reach the relay can download a release — the
 * relay *is* the distribution channel for the private build.
 */
export function addDownloadRoutes(
  app: Hono,
  getConfig: () => { repo: string; token: string },
): void {
  app.get('/download', async (c) => {
    const version = c.req.query('version');
    const asset = c.req.query('asset');
    if (!version || !asset) {
      return c.json({ error: 'version and asset required' }, 400);
    }
    const { repo, token } = getConfig();
    if (!repo) {
      return c.json({ error: 'downloads not configured' }, 503);
    }

    const gh: Record<string, string> = { 'user-agent': 'hearth-relay' };
    if (token) gh['authorization'] = `Bearer ${token}`;

    // Resolve the release by tag, then find the asset by name.
    const relRes = await fetch(
      `https://api.github.com/repos/${repo}/releases/tags/${encodeURIComponent(version)}`,
      { headers: { ...gh, accept: 'application/vnd.github+json' } },
    );
    if (!relRes.ok) return c.json({ error: 'release not found' }, 404);
    const rel = (await relRes.json()) as {
      assets?: Array<{ name: string; url: string }>;
    };
    const found = rel.assets?.find((a) => a.name === asset);
    if (!found) return c.json({ error: 'asset not found' }, 404);

    // Fetch the asset bytes (the API URL + octet-stream Accept yields the binary,
    // via a redirect that fetch follows).
    const assetRes = await fetch(found.url, {
      headers: { ...gh, accept: 'application/octet-stream' },
    });
    if (!assetRes.ok || !assetRes.body) {
      return c.json({ error: 'asset fetch failed' }, 502);
    }
    return new Response(assetRes.body, {
      headers: {
        'content-type': 'application/octet-stream',
        'content-disposition': `attachment; filename="${asset}"`,
      },
    });
  });
}
