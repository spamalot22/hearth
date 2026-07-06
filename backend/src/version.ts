// SPDX-License-Identifier: AGPL-3.0-or-later
import type { Hono } from 'hono';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { timingSafeEqual } from 'node:crypto';
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
        console.log(`[version] loaded manifest from ${this.path}`);
      } else {
        console.log(`[version] no manifest at ${this.path}, will try GitHub`);
        this.fetchFromGitHub();
      }
    } catch (e) {
      console.error(`[version] failed to read ${this.path}:`, e);
      this.fetchFromGitHub();
    }
  }

  /** Fetches manifest.json from the latest GitHub release as a fallback. */
  private fetchFromGitHub() {
    const repo = process.env['GITHUB_REPO'];
    if (!repo) return;
    const url =
      `https://github.com/${repo}/releases/latest/download/manifest.json`;
    fetch(url)
      .then(async (res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const m = (await res.json()) as Record<string, unknown>;
        if (m.version && m.seq && m.sig) {
          this.set(m as object);
          console.log(`[version] recovered manifest from GitHub (${m.version})`);
        }
      })
      .catch((e) => {
        console.log(`[version] GitHub fallback failed: ${e}`);
      });
  }

  get() { return this.manifest; }

  set(m: object) {
    this.manifest = m;
    try {
      mkdirSync(dirname(this.path), { recursive: true });
      writeFileSync(this.path, JSON.stringify(m, null, 2));
      console.log(`[version] persisted manifest to ${this.path}`);
    } catch (e) {
      console.error(`[version] failed to persist manifest to ${this.path}:`, e);
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
    if (!expected || !secret) {
      return c.json({ error: 'unauthorized' }, 401);
    }
    const expectedFull = `Bearer ${expected}`;
    if (
      secret.length !== expectedFull.length ||
      !timingSafeEqual(Buffer.from(secret), Buffer.from(expectedFull))
    ) {
      return c.json({ error: 'unauthorized' }, 401);
    }
    let body: { version?: unknown; seq?: unknown; sig?: unknown };
    try {
      body = (await c.req.json()) as typeof body;
    } catch {
      return c.json({ error: 'invalid json' }, 400);
    }
    if (!body?.version || !body?.seq || !body?.sig) {
      return c.json({ error: 'invalid manifest (need version, seq, sig)' }, 400);
    }
    store.set(body);
    return c.json({ ok: true });
  });
}
