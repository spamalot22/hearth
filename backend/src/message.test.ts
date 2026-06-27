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
  type MessageFields,
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
