// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// Deterministic identity: seed = 32 bytes of 0x01. Gives a fixed public key,
/// so the signed-bytes vector below is reproducible.
Future<Identity> _fixedIdentity() =>
    Identity.fromSeed(Uint8List(32)..fillRange(0, 32, 1));

void main() {
  group('Message', () {
    test('create produces a verifiable, content-addressed message', () async {
      final author = await Identity.generate();
      final m = await Message.create(
        author: author,
        channel: 'general',
        payload: _utf8('hello'),
      );
      expect(m.author, author.publicKey);
      expect(m.signature.length, 64);
      expect(m.id.length, 34); // 2-byte multihash prefix + 32-byte sha256
      expect(m.id.sublist(0, 2), [0x12, 0x20]);
      expect(await m.verify(), isTrue);
    });

    test('verify fails when a signed field is altered (tamper)', () async {
      final author = await _fixedIdentity();
      final m = await Message.create(
        author: author,
        channel: 'general',
        payload: _utf8('hello'),
        timestampMs: 1718900000000,
      );
      // Keep the original signature + id, swap the payload.
      final forged = Message.fromJson({
        ...m.toJson(),
        'payload': base64Url.encode(utf8.encode('goodbye')),
      });
      expect(await forged.verify(), isFalse);
    });

    test('JSON envelope round-trips and stays verifiable', () async {
      final author = await Identity.generate();
      final m = await Message.create(
        author: author,
        channel: 'general',
        payload: _utf8('hi'),
      );
      final back = Message.fromJson(
        jsonDecode(jsonEncode(m.toJson())) as Map<String, Object?>,
      );
      expect(back.id, m.id);
      expect(await back.verify(), isTrue);
    });

    test('signed bytes are deterministic for identical inputs', () async {
      final author = await _fixedIdentity();
      Future<Message> build() => Message.create(
        author: author,
        channel: 'general',
        payload: _utf8('hello'),
        timestampMs: 1718900000000,
      );
      final a = await build();
      final b = await build();
      expect(a.signedBytes(), b.signedBytes());
      expect(a.id, b.id); // Ed25519 is deterministic, so id is stable too.
    });

    test('signed bytes match the locked interop vector', () async {
      // CROSS-LANGUAGE CANARY. The TypeScript backend must reproduce these exact
      // bytes (canonical dag-cbor) to verify a signature. If this hex ever
      // changes, the wire format changed and every signature in the wild just
      // broke — treat with care. Mirrored in test/fixtures/message_vector.json.
      const lockedSignedBytes =
          'a661760164707265768066617574686f7258208a88e3dd7409f195fd52db2d3c'
          'ba5d72ca6709bf1d94121bf3748801b40f6f5c676368616e6e656c6767656e65'
          '72616c677061796c6f61644568656c6c6f6974696d657374616d701b00000190'
          '366c8500';
      const lockedId =
          '12207ccdd3b5326ef7058d17c87e0018ad43527b57e04b6146903a507a4ce56a'
          '43d2';

      final author = await _fixedIdentity();
      final m = await Message.create(
        author: author,
        channel: 'general',
        payload: _utf8('hello'),
        prev: const [],
        timestampMs: 1718900000000,
      );
      expect(hex.encode(m.signedBytes()), lockedSignedBytes);
      expect(m.idHex, lockedId);
      expect(await m.verify(), isTrue);
    });

    test('canonical encoder handles every integer-size branch', () async {
      // Payload length drives the CBOR byte-string header size, and the fixed
      // timestamp exercises the 8-byte branch — together covering all of
      // _head() in codec.dart (1-, 2-, 4- and 8-byte argument encodings).
      final author = await _fixedIdentity();
      for (final size in [23, 200, 5000, 70000]) {
        final m = await Message.create(
          author: author,
          channel: 'c',
          payload: Uint8List(size),
          timestampMs: 1718900000000,
        );
        expect(await m.verify(), isTrue);
      }
    });
  });
}
