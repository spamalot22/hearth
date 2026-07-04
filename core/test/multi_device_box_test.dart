// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('MultiDeviceBox', () {
    test('encrypts and decrypts for a single recipient device', () async {
      final sender = await Identity.generate();
      final recipientDevice = await Identity.generate();

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final boxed = await MultiDeviceBox.encrypt(
        plaintext,
        senderDevice: sender,
        recipientDeviceKeys: [recipientDevice.publicKey],
      );

      final decrypted = await MultiDeviceBox.decrypt(
        boxed,
        recipientDevice: recipientDevice,
        senderDeviceEd: sender.publicKey,
      );
      expect(decrypted, plaintext);
    });

    test('encrypts for multiple devices — each can decrypt', () async {
      final sender = await Identity.generate();
      final deviceA = await Identity.generate();
      final deviceB = await Identity.generate();
      final deviceC = await Identity.generate();

      final plaintext = Uint8List.fromList([10, 20, 30]);
      final boxed = await MultiDeviceBox.encrypt(
        plaintext,
        senderDevice: sender,
        recipientDeviceKeys: [
          deviceA.publicKey,
          deviceB.publicKey,
          deviceC.publicKey,
        ],
      );

      // All three can decrypt.
      for (final device in [deviceA, deviceB, deviceC]) {
        final decrypted = await MultiDeviceBox.decrypt(
          boxed,
          recipientDevice: device,
          senderDeviceEd: sender.publicKey,
        );
        expect(decrypted, plaintext);
      }
    });

    test('a device not in the recipient list cannot decrypt', () async {
      final sender = await Identity.generate();
      final included = await Identity.generate();
      final excluded = await Identity.generate();

      final boxed = await MultiDeviceBox.encrypt(
        Uint8List.fromList([42]),
        senderDevice: sender,
        recipientDeviceKeys: [included.publicKey],
      );

      expect(
        () => MultiDeviceBox.decrypt(
          boxed,
          recipientDevice: excluded,
          senderDeviceEd: sender.publicKey,
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('no wrap found'),
        )),
      );
    });

    test('tampering with ciphertext causes decryption failure', () async {
      final sender = await Identity.generate();
      final recipient = await Identity.generate();

      final boxed = await MultiDeviceBox.encrypt(
        Uint8List.fromList([1, 2, 3]),
        senderDevice: sender,
        recipientDeviceKeys: [recipient.publicKey],
      );

      // Flip a byte in the ciphertext area (after the wraps + nonce + mac).
      final tampered = Uint8List.fromList(boxed);
      tampered[tampered.length - 1] ^= 0xff;

      expect(
        () => MultiDeviceBox.decrypt(
          tampered,
          recipientDevice: recipient,
          senderDeviceEd: sender.publicKey,
        ),
        throwsA(anything),
      );
    });

    test('sender can also be a recipient (for self-sync)', () async {
      final sender = await Identity.generate();
      final otherDevice = await Identity.generate();

      final plaintext = Uint8List.fromList([99]);
      final boxed = await MultiDeviceBox.encrypt(
        plaintext,
        senderDevice: sender,
        // Include the sender's own device so it can read its own message.
        recipientDeviceKeys: [sender.publicKey, otherDevice.publicKey],
      );

      // Sender reads back its own message.
      final decrypted = await MultiDeviceBox.decrypt(
        boxed,
        recipientDevice: sender,
        senderDeviceEd: sender.publicKey,
      );
      expect(decrypted, plaintext);
    });

    test('throws on empty recipient list', () {
      final sender = Identity.generate();
      expect(
        () async => MultiDeviceBox.encrypt(
          Uint8List.fromList([1]),
          senderDevice: await sender,
          recipientDeviceKeys: [],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
