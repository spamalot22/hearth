#!/usr/bin/env tsx
// SPDX-License-Identifier: AGPL-3.0-or-later
/**
 * Release signing tool for Hearth auto-updates.
 *
 * Usage:
 *   tsx src/sign-release.ts keygen              → prints new keypair (hex)
 *   tsx src/sign-release.ts sign <manifest.json> <private-key-hex>
 *       → prints the manifest with `sig` field added
 *
 * The manifest JSON must contain:
 *   { "version": "0.2.0", "seq": 3, "assets": { ... } }
 *
 * `seq` is a monotonically-increasing integer that prevents downgrade attacks:
 * the client rejects any manifest with seq ≤ its last-seen seq.
 */
import * as ed from '@noble/ed25519';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { basename } from 'node:path';

// noble/ed25519 v2 requires you to set the sha512 sync function.
ed.etc.sha512Sync = (...m) => createHash('sha512').update(ed.etc.concatBytes(...m)).digest();

const [, , cmd, ...args] = process.argv;

if (cmd === 'keygen') {
  const priv = ed.utils.randomPrivateKey();
  const pub = ed.getPublicKey(priv);
  console.log(JSON.stringify({
    privateKey: Buffer.from(priv).toString('hex'),
    publicKey: Buffer.from(pub).toString('hex'),
  }, null, 2));
  console.error('⚠️  Store the privateKey somewhere safe. The publicKey goes in the app.');
} else if (cmd === 'sign') {
  const [file, privHex] = args;
  if (!file || !privHex) {
    console.error('Usage: sign-release.ts sign <manifest.json> <private-key-hex>');
    process.exit(1);
  }
  const manifest = JSON.parse(readFileSync(file, 'utf-8'));
  // The signed payload is the canonical JSON of version + seq + assets (no sig).
  const { sig: _, ...payload } = manifest;
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const signature = ed.sign(bytes, privHex);
  console.log(JSON.stringify({ ...payload, sig: Buffer.from(signature).toString('hex') }, null, 2));
} else if (cmd === 'manifest') {
  // Build + sign a manifest straight from the built asset files, computing each
  // one's SHA-256. CI calls this after a release:
  //   manifest <version> <seq> <priv-hex> <name=file> [<name=file>...]
  const [version, seqStr, privHex, ...assetArgs] = args;
  if (!version || !seqStr || !privHex || assetArgs.length === 0) {
    console.error(
      'Usage: sign-release.ts manifest <version> <seq> <priv-hex> <name=file> [<name=file>...]',
    );
    process.exit(1);
  }
  const assets: Record<string, { file: string; sha256: string }> = {};
  for (const a of assetArgs) {
    const eq = a.indexOf('=');
    if (eq < 0) {
      console.error(`Bad asset arg (need name=file): ${a}`);
      process.exit(1);
    }
    const name = a.slice(0, eq);
    const file = a.slice(eq + 1);
    const sha256 = createHash('sha256').update(readFileSync(file)).digest('hex');
    assets[name] = { file: basename(file), sha256 };
  }
  // Canonical payload (compact, insertion-ordered) — must byte-match the client's
  // jsonEncode of the same fields, so the signature verifies cross-language.
  const payload = { version, seq: Number(seqStr), assets };
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const sig = Buffer.from(ed.sign(bytes, privHex)).toString('hex');
  console.log(JSON.stringify({ ...payload, sig }, null, 2));
} else {
  console.error(
    'Commands: keygen | sign <manifest.json> <priv-hex> | manifest <version> <seq> <priv-hex> <name=file>...',
  );
  process.exit(1);
}
