// SPDX-License-Identifier: AGPL-3.0-or-later
/**
 * Canonical bytes signed for a release manifest.
 *
 * A fixed-field, newline-joined form (NOT `JSON.stringify`) so the TypeScript
 * signer and the Dart client produce byte-identical input independent of JSON
 * key order, whitespace, or serializer quirks. Asset keys are sorted so the
 * order they were passed on the CLI can't change the signature. Mirrored by
 * `manifestSigningBytes` in the app's `update_checker.dart`.
 */
export interface ManifestPayload {
  version: string;
  seq: number;
  assets: Record<string, { file: string; sha256: string }>;
}

export function manifestSigningBytes(p: ManifestPayload): Uint8Array {
  const lines = ['hearth/manifest/v1', String(p.version), String(p.seq)];
  for (const name of Object.keys(p.assets).sort()) {
    const a = p.assets[name]!; // defined — iterating this object's own keys
    lines.push(name, String(a.file), String(a.sha256));
  }
  return new TextEncoder().encode(lines.join('\n'));
}
