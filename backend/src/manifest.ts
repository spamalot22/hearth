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

export interface SignedManifest extends ManifestPayload {
  sig: string;
}

export function manifestSigningBytes(p: ManifestPayload): Uint8Array {
  const lines = ['hearth/manifest/v1', String(p.version), String(p.seq)];
  for (const name of Object.keys(p.assets).sort()) {
    const a = p.assets[name]!; // defined — iterating this object's own keys
    lines.push(name, String(a.file), String(a.sha256));
  }
  return new TextEncoder().encode(lines.join('\n'));
}

const HEX_32 = /^[0-9a-f]{64}$/i;
const HEX_SIG = /^[0-9a-f]{128}$/i;

export function parseSignedManifest(raw: unknown): SignedManifest | null {
  if (!raw || typeof raw !== 'object') return null;
  const m = raw as Record<string, unknown>;
  const seq = m.seq;
  if (
    typeof m.version !== 'string' ||
    !m.version ||
    typeof seq !== 'number' ||
    !Number.isSafeInteger(seq) ||
    typeof m.sig !== 'string' ||
    !HEX_SIG.test(m.sig) ||
    !m.assets ||
    typeof m.assets !== 'object' ||
    Array.isArray(m.assets)
  ) {
    return null;
  }
  const assets: Record<string, { file: string; sha256: string }> = {};
  for (const [name, value] of Object.entries(
    m.assets as Record<string, unknown>,
  )) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    const asset = value as Record<string, unknown>;
    if (
      !name ||
      typeof asset.file !== 'string' ||
      !asset.file ||
      typeof asset.sha256 !== 'string' ||
      !HEX_32.test(asset.sha256)
    ) {
      return null;
    }
    assets[name] = { file: asset.file, sha256: asset.sha256 };
  }
  return {
    version: m.version,
    seq,
    assets,
    sig: m.sig,
  };
}
