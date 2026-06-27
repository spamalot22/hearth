import type { Hono } from 'hono';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const DEFAULT_MANIFEST_PATH = './data/version.json';

/**
 * Serves the signed release manifest at GET /version.
 *
 * The manifest is persisted to disk so it survives relay restarts. The relay is
 * a dumb host — it cannot forge the Ed25519 signature, so a compromised relay
 * can at worst withhold updates.
 */
export class VersionStore {
  private manifest: object | null = null;
  private readonly path: string;

  constructor(path?: string) {
    this.path = path ?? process.env['VERSION_FILE'] ?? DEFAULT_MANIFEST_PATH;
    try {
      if (existsSync(this.path)) {
        this.manifest = JSON.parse(readFileSync(this.path, 'utf-8'));
      }
    } catch {
      // Corrupt or missing file — start empty.
    }
  }

  get() { return this.manifest; }

  set(m: object) {
    this.manifest = m;
    try {
      mkdirSync(dirname(this.path), { recursive: true });
      writeFileSync(this.path, JSON.stringify(m, null, 2));
    } catch {
      // Write failure is non-fatal — manifest is still in memory for this run.
    }
  }
}

export function addVersionRoutes(app: Hono, store: VersionStore): void {
  // Clients poll this to check for updates.
  app.get('/version', (c) => {
    const m = store.get();
    if (!m) return c.json({ error: 'no release published' }, 404);
    return c.json(m);
  });

  // CI pushes the signed manifest here after a release.
  app.post('/version', async (c) => {
    const secret = c.req.header('authorization');
    const expected = process.env['RELEASE_SECRET'];
    if (!expected || secret !== `Bearer ${expected}`) {
      return c.json({ error: 'unauthorized' }, 401);
    }
    const body = await c.req.json();
    if (!body?.version || !body?.seq || !body?.sig) {
      return c.json({ error: 'invalid manifest (need version, seq, sig)' }, 400);
    }
    store.set(body);
    return c.json({ ok: true });
  });
}
