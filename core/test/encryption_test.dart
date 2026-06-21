import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('SealedBox', () {
    test('the Ed25519→X25519 conversion matches the derived keypair', () async {
      // The whole scheme rests on this: a peer's X25519 public key derived from
      // their Ed25519 id (sender side) must equal the one derived from their seed
      // (recipient side). If these agree, ECDH agrees and decryption works.
      final id = await Identity.generate();
      final fromId = ed25519PublicToX25519(id.publicKey);
      final fromSeed = await id.x25519PublicKey();
      expect(fromId, fromSeed);
    });

    test('seal then open round-trips the plaintext', () async {
      final bob = await Identity.generate();
      final message = _b('hello bob 🔒');
      final sealed = await SealedBox.seal(
        message,
        recipientEd25519PublicKey: bob.publicKey,
      );
      expect(sealed, isNot(containsAllInOrder(message))); // not plaintext
      final opened = await SealedBox.open(sealed, recipient: bob);
      expect(opened, message);
    });

    test('a different recipient cannot open it', () async {
      final bob = await Identity.generate();
      final eve = await Identity.generate();
      final sealed = await SealedBox.seal(
        _b('for bob only'),
        recipientEd25519PublicKey: bob.publicKey,
      );
      await expectLater(
        SealedBox.open(sealed, recipient: eve),
        throwsA(anything),
      );
    });

    test('tampering with the ciphertext is detected', () async {
      final bob = await Identity.generate();
      final sealed = await SealedBox.seal(
        _b('integrity matters'),
        recipientEd25519PublicKey: bob.publicKey,
      );
      sealed[sealed.length - 1] ^= 0x01; // flip a ciphertext bit
      await expectLater(
        SealedBox.open(sealed, recipient: bob),
        throwsA(anything),
      );
    });

    test('each seal is fresh (random ephemeral key + nonce)', () async {
      final bob = await Identity.generate();
      final a = await SealedBox.seal(
        _b('x'),
        recipientEd25519PublicKey: bob.publicKey,
      );
      final b = await SealedBox.seal(
        _b('x'),
        recipientEd25519PublicKey: bob.publicKey,
      );
      expect(a, isNot(b)); // same plaintext, different ciphertext
    });
  });

  group('PairBox (DM shared key)', () {
    test('both parties — and only they — read every message', () async {
      final a = await Identity.generate();
      final b = await Identity.generate();
      final eve = await Identity.generate();
      final boxed = await PairBox.encrypt(
        _b('hi from a'),
        self: a,
        peerEd25519PublicKey: b.publicKey,
      );

      // B reads A's message...
      expect(
        await PairBox.decrypt(
          boxed,
          self: b,
          peerEd25519PublicKey: a.publicKey,
        ),
        _b('hi from a'),
      );
      // ...and A reads back its OWN message (the win over a sealed box)...
      expect(
        await PairBox.decrypt(
          boxed,
          self: a,
          peerEd25519PublicKey: b.publicKey,
        ),
        _b('hi from a'),
      );
      // ...but an outsider cannot.
      await expectLater(
        PairBox.decrypt(boxed, self: eve, peerEd25519PublicKey: a.publicKey),
        throwsA(anything),
      );
    });

    test('tampering is detected', () async {
      final a = await Identity.generate();
      final b = await Identity.generate();
      final boxed = await PairBox.encrypt(
        _b('integrity'),
        self: a,
        peerEd25519PublicKey: b.publicKey,
      );
      boxed[boxed.length - 1] ^= 0x01;
      await expectLater(
        PairBox.decrypt(boxed, self: b, peerEd25519PublicKey: a.publicKey),
        throwsA(anything),
      );
    });
  });
}
