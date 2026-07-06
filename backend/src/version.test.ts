// SPDX-License-Identifier: AGPL-3.0-or-later
import { describe, expect, it, beforeEach } from 'vitest';
import { randomBytes } from 'node:crypto';
import * as ed from '@noble/ed25519';
import { manifestSigningBytes } from './manifest';
import { createRelay, RelayStore } from './relay';
import { SignalHub } from './signal';
import { VersionStore } from './version';

describe('/version', () => {
  let app: ReturnType<typeof createRelay>;
  let versionStore: VersionStore;
  const unsignedManifest = {
    version: '0.2.0',
    seq: 2,
    assets: {
      android: {
        file: 'hearth-android.apk',
        sha256: 'a'.repeat(64),
      },
    },
  };

  beforeEach(() => {
    delete process.env['RELEASE_SECRET'];
    delete process.env['RELEASE_PUBLIC_KEY'];
    // Non-existent path — guarantees empty store.
    const tempFile = `/tmp/.hearth-test-${randomBytes(4).toString('hex')}.json`;
    versionStore = new VersionStore(tempFile);
    app = createRelay(new RelayStore(), new SignalHub(), versionStore);
  });

  async function signedManifest(seed = ed.utils.randomPrivateKey()) {
    const sig = await ed.signAsync(manifestSigningBytes(unsignedManifest), seed);
    return {
      ...unsignedManifest,
      sig: Buffer.from(sig).toString('hex'),
    };
  }

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
    const manifest = await signedManifest();
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
    expect(body.sig).toBe(manifest.sig);
  });

  it('validates the manifest signature when RELEASE_PUBLIC_KEY is configured', async () => {
    process.env['RELEASE_SECRET'] = 'test-secret';
    const seed = ed.utils.randomPrivateKey();
    process.env['RELEASE_PUBLIC_KEY'] = Buffer.from(
      await ed.getPublicKeyAsync(seed),
    ).toString('hex');
    const manifest = await signedManifest(seed);

    const valid = await app.request('/version', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer test-secret',
      },
      body: JSON.stringify(manifest),
    });
    expect(valid.status).toBe(200);

    const forged = await app.request('/version', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer test-secret',
      },
      body: JSON.stringify({ ...manifest, seq: 3 }),
    });
    expect(forged.status).toBe(400);
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
  });

  it('rejects malformed manifest json', async () => {
    process.env['RELEASE_SECRET'] = 'test-secret';
    const res = await app.request('/version', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer test-secret',
      },
      body: '{',
    });
    expect(res.status).toBe(400);
  });
});
