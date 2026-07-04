// SPDX-License-Identifier: AGPL-3.0-or-later
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { encode as dagCborEncode } from '@ipld/dag-cbor';
import * as ed from '@noble/ed25519';
import { describe, expect, it } from 'vitest';

import {
  bytesToHex,
  computeId,
  hexToBytes,
  MESSAGE_VERSION,
  signedBytes,
  verifyDeviceCert,
  verifySignature,
  verifyWire,
  type MessageFields,
  type WireDeviceCert,
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

/** A cert binding `deviceSeed`'s device to `rootSeed`'s root, signed by root. */
async function makeCert(
  rootSeed: Uint8Array,
  deviceSeed: Uint8Array,
): Promise<WireDeviceCert> {
  const root = await ed.getPublicKeyAsync(rootSeed);
  const device = await ed.getPublicKeyAsync(deviceSeed);
  const name = 'phone';
  const issued = 1718900000000;
  const bytes = dagCborEncode({
    t: 'hearth/device-cert/v1',
    name,
    root,
    device,
    issued,
  });
  const sig = await ed.signAsync(bytes, rootSeed);
  return {
    root: toB64Url(root),
    device: toB64Url(device),
    name,
    issued,
    sig: toB64Url(sig),
  };
}

/**
 * Builds a wire message authored by `authorSeed`. When `signerSeed`/`cert` are
 * given, it's device-signed by `signerSeed` and carries `cert`.
 */
async function wire(
  authorSeed: Uint8Array,
  opts: { signerSeed?: Uint8Array; cert?: WireDeviceCert } = {},
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
  const sig = await ed.signAsync(content, opts.signerSeed ?? authorSeed);
  const device = opts.signerSeed
    ? await ed.getPublicKeyAsync(opts.signerSeed)
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
    cert: opts.cert,
  };
}

describe('relay verifyWire — multi-device', () => {
  const rootSeed = hexToBytes('01'.repeat(32));
  const deviceSeed = hexToBytes('02'.repeat(32));
  const otherSeed = hexToBytes('03'.repeat(32));

  it('accepts a classic root-signed message', async () => {
    expect(await verifyWire(await wire(rootSeed))).toBe(true);
  });

  it('accepts a device-signed message with a valid cert', async () => {
    const cert = await makeCert(rootSeed, deviceSeed);
    expect(
      await verifyWire(await wire(rootSeed, { signerSeed: deviceSeed, cert })),
    ).toBe(true);
  });

  it('rejects a device-signed message with no cert', async () => {
    const w = await wire(rootSeed, { signerSeed: deviceSeed });
    expect(await verifyWire({ ...w, cert: undefined })).toBe(false);
  });

  it('rejects a cert whose root is not the message author (spoofed author)', async () => {
    // Attacker signs with their own device + a cert under their OWN root, but
    // claims author = victim (rootSeed). cert.root != author → rejected.
    const attackerCert = await makeCert(otherSeed, deviceSeed);
    const w = await wire(rootSeed, {
      signerSeed: deviceSeed,
      cert: attackerCert,
    });
    expect(await verifyWire(w)).toBe(false);
  });

  it('rejects a message signed by a device the cert does not name', async () => {
    const cert = await makeCert(rootSeed, deviceSeed); // cert names deviceSeed
    // …but the message is signed by otherSeed and presents it as the device.
    const w = await wire(rootSeed, { signerSeed: otherSeed, cert });
    expect(await verifyWire(w)).toBe(false);
  });

  it('verifies a cert produced by Dart core (cross-language byte match)', async () => {
    // Golden from core/test/device_test.dart: root seed 01*32, device seed
    // 02*32, name 'phone', issued 1718900000000. If our dag-cbor bytes diverge
    // from Dart's canonical CBOR, this Dart signature fails to verify here.
    const rootPub = hexToBytes(
      '8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c',
    );
    const devicePub = hexToBytes(
      '8139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394',
    );
    const sig = hexToBytes(
      'a700fd21ea8edf0bae433ef77bc933110d7f1e0db8318ab40737e9d196c3d561'
        + '2cee3dec655b51c9b360047ab1683a26c46481a984dde808755a29a24569d00b',
    );
    const cert: WireDeviceCert = {
      root: toB64Url(rootPub),
      device: toB64Url(devicePub),
      name: 'phone',
      issued: 1718900000000,
      sig: toB64Url(sig),
    };
    expect(await verifyDeviceCert(cert, rootPub, devicePub)).toBe(true);
  });
});
