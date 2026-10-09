// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { patches, patchWebRtc } from './patch-webrtc.mjs';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'hearth-webrtc-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const files = new Map();
  for (const patch of patches) {
    files.set(patch.file, (files.get(patch.file) ?? '') + patch.before + '\n');
  }
  for (const [file, source] of files) {
    await mkdir(dirname(join(root, file)), { recursive: true });
    await writeFile(join(root, file), source);
  }
  return { root, files };
}

test('retains receiver tracks and streams; lookup and removal are synchronized', async t => {
  const { root } = await fixture(t);
  await patchWebRtc(root);
  for (const patch of patches) {
    const source = await readFile(join(root, patch.file), 'utf8');
    assert.ok(source.includes(patch.after));
  }
  const source = await readFile(join(root, 'common/cpp/src/flutter_peerconnection.cc'), 'utf8');
  assert.match(source, /receiver_tracks_\[track->id\(\)\.std_string\(\)\] = track/);
  assert.match(source, /receiver_tracks_\.erase/);
  assert.match(source, /receiver_streams_\.erase/);
});

test('receiver patch is idempotent', async t => {
  const { root, files } = await fixture(t);
  await patchWebRtc(root);
  const first = new Map();
  for (const file of files.keys()) first.set(file, await readFile(join(root, file), 'utf8'));
  await patchWebRtc(root);
  for (const [file, source] of first) assert.equal(await readFile(join(root, file), 'utf8'), source);
});

test('source drift aborts without partially writing files', async t => {
  const { root, files } = await fixture(t);
  const file = patches.at(-1).file;
  const source = files.get(file).replace(patches.at(-1).before, 'unexpected upstream source');
  await writeFile(join(root, file), source);
  files.set(file, source);
  await assert.rejects(patchWebRtc(root), /no longer matches/);
  for (const [path, original] of files) assert.equal(await readFile(join(root, path), 'utf8'), original);
});
