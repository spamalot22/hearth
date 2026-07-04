// SPDX-License-Identifier: AGPL-3.0-or-later
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import * as ed from '@noble/ed25519';
import { describe, expect, it } from 'vitest';

import {
  bytesToHex,
  computeId,
  hexToBytes,
  MESSAGE_VERSION,
  signedBytes,
  verifySignature,
  verifyWire,
  type MessageFields,
  type WireMessage,
} from './message';

// The language-neutral vector produced by the Dart `core` tests.
const vector = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL('../../core/test/fixtures/message_vector.json', import.meta.url),
    ),
    'utf8',
  ),
) as {
  input: {
    seedHex: string;
    authorPublicKeyHex: string;
    channel: string;
    prev: string[];
    timestampMs: number;
    payloadUtf8: string;
  };
  expected: { signedBytesHex: string; idHex: string };
};

const fields: MessageFields = {
  version: MESSAGE_VERSION,
  author: hexToBytes(vector.input.authorPublicKeyHex),
  channel: vector.input.channel,
  prev: vector.input.prev.map(hexToBytes),
  timestampMs: vector.input.timestampMs,
  payload: new TextEncoder().encode(vector.input.payloadUtf8),
};

describe('cross-language interop with Dart core', () => {
  it('reproduces the canonical signed bytes byte-for-byte', () => {
    expect(bytesToHex(signedBytes(fields))).toBe(vector.expected.signedBytesHex);
  });

  it('reproduces the content id', () => {
    expect(bytesToHex(computeId(signedBytes(fields)))).toBe(
      vector.expected.idHex,
    );
  });

  it('derives the same public key from the seed', async () => {
    const pub = await ed.getPublicKeyAsync(hexToBytes(vector.input.seedHex));
    expect(bytesToHex(pub)).toBe(vector.input.authorPublicKeyHex);
  });

  it('a signature it produces verifies (Ed25519 is deterministic, so this is '
      + 'also the exact signature Dart would make)', async () => {
    const content = signedBytes(fields);
    const sig = await ed.signAsync(content, hexToBytes(vector.input.seedHex));
    expect(await verifySignature(content, sig, fields.author)).toBe(true);
  });
});

const toB64Url = (b: Uint8Array) => Buffer.from(b).toString('base64url');

/** Builds a wire message; when `deviceSeed` is given, `sig` is by that device. */
async function wire(
  authorSeed: Uint8Array,
  deviceSeed?: Uint8Array,
): Promise<WireMessage> {
  const author = await ed.getPublicKeyAsync(authorSeed);
  const f: MessageFields = {
    version: MESSAGE_VERSION,
    author,
    channel: 'c',
    prev: [],
    timestampMs: 1718900000000,
    payload: new TextEncoder().encode('hi'),
  };
  const content = signedBytes(f);
  const signerSeed = deviceSeed ?? authorSeed;
  const sig = await ed.signAsync(content, signerSeed);
  const device = deviceSeed
    ? await ed.getPublicKeyAsync(deviceSeed)
    : undefined;
  return {
    v: f.version,
    author: toB64Url(author),
    channel: f.channel,
    prev: [],
    timestamp: f.timestampMs,
    payload: toB64Url(f.payload),
    sig: toB64Url(sig),
    id: toB64Url(computeId(content)),
    device: device ? toB64Url(device) : undefined,
  };
}

describe('relay verifyWire — multi-device', () => {
  const rootSeed = hexToBytes('01'.repeat(32));
  const deviceSeed = hexToBytes('02'.repeat(32));

  it('accepts a classic root-signed message', async () => {
    expect(await verifyWire(await wire(rootSeed))).toBe(true);
  });

  it('accepts a device-signed message (sig checked against the device)', async () => {
    expect(await verifyWire(await wire(rootSeed, deviceSeed))).toBe(true);
  });

  it('rejects a device-signed message whose sig is not by the named device', async () => {
    const w = await wire(rootSeed, deviceSeed);
    // Swap in a different device key; the signature no longer matches.
    const otherDevice = await ed.getPublicKeyAsync(hexToBytes('03'.repeat(32)));
    expect(await verifyWire({ ...w, device: toB64Url(otherDevice) })).toBe(
      false,
    );
  });
});
