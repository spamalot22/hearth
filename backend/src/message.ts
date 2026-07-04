// SPDX-License-Identifier: AGPL-3.0-or-later
import { createHash } from 'node:crypto';

import { encode as dagCborEncode } from '@ipld/dag-cbor';
import * as ed from '@noble/ed25519';

/** Schema version of the signed content. Mirrors core's kHearthMessageVersion. */
export const MESSAGE_VERSION = 1;

/** Multihash prefix for sha2-256: code 0x12, length 0x20. */
const SHA256_MULTIHASH_PREFIX = Uint8Array.of(0x12, 0x20);

/** The signed (unsigned-by-id/sig) fields of a message. */
export interface MessageFields {
  version: number;
  author: Uint8Array; // 32-byte Ed25519 public key
  channel: string;
  prev: Uint8Array[]; // parent ids
  timestampMs: number;
  payload: Uint8Array;
}

/** The JSON wire envelope (matches core's `Message.toJson()`, base64url fields). */
export interface WireMessage {
  v: number;
  author: string;
  channel: string;
  prev: string[];
  timestamp: number;
  payload: string;
  sig: string;
  id: string;
  // Multi-device: when present, `sig` is by this device subkey (not the author
  // root), and `cert` is the root's authorisation of that device. The relay
  // verifies the cert chain (so `author` stays authenticated); the receiving
  // client additionally enforces revocation.
  device?: string;
  cert?: WireDeviceCert;
}

/** A device cert on the wire (matches core's `DeviceCert.toJson`). */
export interface WireDeviceCert {
  root: string;
  device: string;
  name: string;
  issued: number;
  sig: string;
}

/**
 * Canonical signed bytes of a device cert — must be byte-for-byte identical to
 * core's `DeviceCert._signedBytes` (canonical CBOR, keys t,name,root,device,
 * issued). @ipld/dag-cbor sorts keys canonically, matching the hand-rolled Dart
 * encoder, same as {@link signedBytes} for messages.
 */
function deviceCertSignedBytes(
  root: Uint8Array,
  device: Uint8Array,
  name: string,
  issued: number,
): Uint8Array {
  return dagCborEncode({
    t: 'hearth/device-cert/v1',
    name,
    root,
    device,
    issued,
  });
}

/**
 * Verifies a device cert binds [device] to [author] (== cert.root) and is
 * signed by that root. Returns false on any mismatch or bad signature.
 */
export async function verifyDeviceCert(
  cert: WireDeviceCert,
  author: Uint8Array,
  device: Uint8Array,
): Promise<boolean> {
  const root = b64urlToBytes(cert.root);
  const certDevice = b64urlToBytes(cert.device);
  if (!bytesEqual(root, author)) return false;
  if (!bytesEqual(certDevice, device)) return false;
  const bytes = deviceCertSignedBytes(root, certDevice, cert.name, cert.issued);
  return ed.verifyAsync(b64urlToBytes(cert.sig), bytes, root);
}

/**
 * The canonical bytes that are signed and hashed — must be byte-for-byte
 * identical to core's `Message.signedBytes()`: canonical dag-cbor with map keys
 * in length-then-bytewise order (v, prev, author, channel, payload, timestamp).
 *
 * @ipld/dag-cbor emits canonical dag-cbor (it sorts keys and uses minimal,
 * definite-length encodings), so it matches the hand-rolled Dart encoder. The
 * interop fixture test guards that this stays true.
 */
export function signedBytes(f: MessageFields): Uint8Array {
  return dagCborEncode({
    v: f.version,
    prev: f.prev,
    author: f.author,
    channel: f.channel,
    payload: f.payload,
    timestamp: f.timestampMs,
  });
}

/** `multihash(sha256(content))` — 34 bytes, matching core's `Message.id`. */
export function computeId(content: Uint8Array): Uint8Array {
  const digest = createHash('sha256').update(content).digest();
  return new Uint8Array([...SHA256_MULTIHASH_PREFIX, ...digest]);
}

/** Verifies an Ed25519 signature over the canonical signed bytes. */
export function verifySignature(
  content: Uint8Array,
  signature: Uint8Array,
  publicKey: Uint8Array,
): Promise<boolean> {
  return ed.verifyAsync(signature, content, publicKey);
}

/**
 * Validates a wire message for the relay: recomputes the canonical id (rejecting
 * a forged id) and checks the signature chain. For a device-signed message the
 * cert must bind the device to `author` and the device must have signed the
 * content — so `author` stays authenticated (rate-limiting keys on it). The
 * client additionally enforces device revocation.
 */
export async function verifyWire(w: WireMessage): Promise<boolean> {
  const fields: MessageFields = {
    version: w.v,
    author: b64urlToBytes(w.author),
    channel: w.channel,
    prev: w.prev.map(b64urlToBytes),
    timestampMs: w.timestamp,
    payload: b64urlToBytes(w.payload),
  };
  const content = signedBytes(fields);
  if (!bytesEqual(computeId(content), b64urlToBytes(w.id))) return false;
  if (w.device) {
    const device = b64urlToBytes(w.device);
    if (!w.cert) return false; // device-signed but no authorisation
    if (!(await verifyDeviceCert(w.cert, fields.author, device))) return false;
    return verifySignature(content, b64urlToBytes(w.sig), device);
  }
  return verifySignature(content, b64urlToBytes(w.sig), fields.author);
}

export function b64urlToBytes(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, 'base64url'));
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

export function bytesToHex(b: Uint8Array): string {
  let out = '';
  for (const x of b) out += x.toString(16).padStart(2, '0');
  return out;
}

export function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}
