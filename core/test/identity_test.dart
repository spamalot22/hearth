// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('Identity', () {
    test('generates a 32-byte Ed25519 public key', () async {
      final id = await Identity.generate();
      expect(id.publicKey.length, 32);
    });

    test('two generated identities differ', () async {
      final a = await Identity.generate();
      final b = await Identity.generate();
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });

    test('sign / verify round-trips', () async {
      final id = await Identity.generate();
      final msg = Uint8List.fromList([1, 2, 3, 4]);
      final sig = await id.sign(msg);
      expect(sig.length, 64);
      expect(
        await Identity.verifySignature(
          msg,
          signature: sig,
          publicKey: id.publicKey,
        ),
        isTrue,
      );
    });

    test('verification rejects a tampered message', () async {
      final id = await Identity.generate();
      final sig = await id.sign(Uint8List.fromList([1, 2, 3, 4]));
      expect(
        await Identity.verifySignature(
          Uint8List.fromList([1, 2, 3, 5]),
          signature: sig,
          publicKey: id.publicKey,
        ),
        isFalse,
      );
    });

    test('seed restores the same identity', () async {
      final id = await Identity.generate();
      final restored = await Identity.fromSeed(await id.extractSeed());
      expect(restored.publicKey, id.publicKey);
      expect(restored.fingerprint, id.fingerprint);
    });

    test('KeyStore persists and reloads an identity', () async {
      final store = InMemoryKeyStore();
      final id = await Identity.generate();
      await store.writeSeed(await id.extractSeed());

      final seed = await store.readSeed();
      expect(seed, isNotNull);
      final restored = await Identity.fromSeed(seed!);
      expect(restored.publicKey, id.publicKey);

      await store.deleteSeed();
      expect(await store.readSeed(), isNull);
    });

    test(
      'loadOrCreate generates once, then restores the same identity',
      () async {
        final store = InMemoryKeyStore();
        final first = await Identity.loadOrCreate(store);
        final second = await Identity.loadOrCreate(store);
        expect(second.publicKey, first.publicKey);
        expect(second.publicKeyHex, first.publicKeyHex);
      },
    );
  });
}
