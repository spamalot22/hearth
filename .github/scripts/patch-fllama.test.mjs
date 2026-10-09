// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { patches, patchFllama } from './patch-fllama.mjs';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'hearth-native-patch-'));
  await mkdir(join(root, 'hook'));
  await mkdir(join(root, 'src'));
  const files = new Map();
  for (const patch of patches) {
    files.set(patch.file, (files.get(patch.file) ?? '') +
      Array(patch.count ?? 1).fill(patch.before).join('\n') + '\n');
  }
  for (const [file, source] of files) await writeFile(join(root, file), source);
  return root;
}

test('native patch is idempotent and covers all safety options', async () => {
  const root = await fixture();
  try {
    await patchFllama(root);
    const first = await readFile(join(root, 'hook/build.dart'), 'utf8');
    const modified = (await stat(join(root, 'hook/build.dart'))).mtimeMs;
    await patchFllama(root);
    assert.equal(await readFile(join(root, 'hook/build.dart'), 'utf8'), first);
    assert.equal((await stat(join(root, 'hook/build.dart'))).mtimeMs, modified);
    for (const patch of patches) {
      assert.ok((await readFile(join(root, patch.file), 'utf8')).includes(patch.after));
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('patch matches the actual pinned dependency', {
  skip: !process.env.FLLAMA_TEST_SOURCE,
}, async () => {
  const root = await fixture();
  try {
    for (const file of new Set(patches.map(patch => patch.file))) {
      await writeFile(join(root, file), await readFile(join(process.env.FLLAMA_TEST_SOURCE, file)));
    }
    await patchFllama(root);
    await patchFllama(root);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('dependency drift fails before any file is modified', async () => {
  const root = await fixture();
  try {
    const hook = await readFile(join(root, 'hook/build.dart'), 'utf8');
    await writeFile(join(root, 'src/fllama_inference_queue.h'), 'changed upstream');
    await assert.rejects(patchFllama(root), /no longer matches/);
    assert.equal(await readFile(join(root, 'hook/build.dart'), 'utf8'), hook);
  } finally { await rm(root, { recursive: true, force: true }); }
});
