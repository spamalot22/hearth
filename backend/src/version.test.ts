// SPDX-License-Identifier: AGPL-3.0-or-later
import { describe, expect, it, beforeEach } from 'vitest';
import { randomBytes } from 'node:crypto';
import { createRelay, RelayStore } from './relay';
import { SignalHub } from './signal';
import { VersionStore } from './version';

describe('/version', () => {
  let app: ReturnType<typeof createRelay>;
  let versionStore: VersionStore;

  beforeEach(() => {
    // Non-existent path — guarantees empty store.
    const tempFile = `/tmp/.hearth-test-${randomBytes(4).toString('hex')}.json`;
    versionStore = new VersionStore(tempFile);
    app = createRelay(new RelayStore(), new SignalHub(), versionStore);
  });

  it('returns 404 when no manifest is set', async () => {
    const res = await app.request('/version');
    expect(res.status).toBe(404);
  });

  it('rejects POST without auth', async () => {
    const res = await app.request('/version', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ version: '0.1.0', seq: 1, sig: 'abc' }),
    });
    expect(res.status).toBe(401);
  });

  it('accepts POST with valid auth and serves manifest on GET', async () => {
    process.env['RELEASE_SECRET'] = 'test-secret';
    const manifest = { version: '0.2.0', seq: 2, assets: {}, sig: 'deadbeef' };
    const postRes = await app.request('/version', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer test-secret',
      },
      body: JSON.stringify(manifest),
    });
    expect(postRes.status).toBe(200);

    const getRes = await app.request('/version');
    expect(getRes.status).toBe(200);
    const body = await getRes.json() as { version: string; seq: number; sig: string };
    expect(body.version).toBe('0.2.0');
    expect(body.seq).toBe(2);
    expect(body.sig).toBe('deadbeef');
    delete process.env['RELEASE_SECRET'];
  });

  it('rejects manifest missing required fields', async () => {
    process.env['RELEASE_SECRET'] = 'test-secret';
    const res = await app.request('/version', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer test-secret',
      },
      body: JSON.stringify({ version: '0.1.0' }), // missing seq + sig
    });
    expect(res.status).toBe(400);
    delete process.env['RELEASE_SECRET'];
  });
});
