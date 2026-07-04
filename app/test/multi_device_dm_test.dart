// SPDX-License-Identifier: AGPL-3.0-or-later
// B3: MultiDeviceDmCipher encrypts per-device when bundle available, falls back
// to PairBox when no bundle exists.
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';

void main() {
  group('MultiDeviceDmCipher', () {
    test('encrypts via MultiDeviceBox when bundle available', () async {
      final aliceRoot = await Identity.generate();
      final aliceDevice = await Identity.generate();
      final bobRoot = await Identity.generate();
      final bobDevice = await Identity.generate();

      // Bob has published a bundle listing his device.
      final bobBundle = await DeviceBundle.publish(
        root: bobRoot,
        devices: [bobDevice.publicKey],
      );

      final cipher = MultiDeviceDmCipher(
        selfDevice: aliceDevice,
        selfRoot: aliceRoot,
        peerRootKey: bobRoot.publicKey,
        peerBundleLookup: () => bobBundle,
        ownDeviceKeys: () => [aliceDevice.publicKey],
      );

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final boxed = await cipher.encrypt(plaintext);

      // It should start with version byte 1 (MultiDeviceBox format).
      expect(boxed[0], 1, reason: 'should use MultiDeviceBox format');

      // Bob's device can decrypt it.
      final bobCipher = MultiDeviceDmCipher(
        selfDevice: bobDevice,
        selfRoot: bobRoot,
        peerRootKey: aliceRoot.publicKey,
        peerBundleLookup: () => DeviceBundle(
          rootKey: aliceRoot.publicKey,
          devices: [aliceDevice.publicKey],
          publishedMs: 0,
          signature: Uint8List(64), // not verified during decrypt
        ),
        ownDeviceKeys: () => [bobDevice.publicKey],
      );
      final decrypted = await bobCipher.decrypt(boxed);
      expect(decrypted, plaintext);
    });

    test('falls back to PairBox when no bundle available', () async {
      final aliceRoot = await Identity.generate();
      final aliceDevice = await Identity.generate();
      final bobRoot = await Identity.generate();

      final cipher = MultiDeviceDmCipher(
        selfDevice: aliceDevice,
        selfRoot: aliceRoot,
        peerRootKey: bobRoot.publicKey,
        peerBundleLookup: () => null, // no bundle
        ownDeviceKeys: () => [aliceDevice.publicKey],
      );

      final plaintext = Uint8List.fromList([10, 20, 30]);
      final boxed = await cipher.encrypt(plaintext);

      // Should NOT start with version byte 1 (PairBox starts with random nonce).
      // Decrypt with a plain DmChannelCipher (PairBox) should work.
      final legacy = DmChannelCipher(bobRoot, aliceRoot.publicKey);
      final decrypted = await legacy.decrypt(boxed);
      expect(decrypted, plaintext);
    });

    test('decrypts legacy PairBox messages via fallback', () async {
      final aliceRoot = await Identity.generate();
      final bobRoot = await Identity.generate();
      final bobDevice = await Identity.generate();

      // Alice sends a legacy PairBox message (before she had a bundle).
      final legacy = DmChannelCipher(aliceRoot, bobRoot.publicKey);
      final plaintext = Uint8List.fromList([99]);
      final boxed = await legacy.encrypt(plaintext);

      // Bob decrypts with MultiDeviceDmCipher — should fall through to PairBox.
      final bobCipher = MultiDeviceDmCipher(
        selfDevice: bobDevice,
        selfRoot: bobRoot,
        peerRootKey: aliceRoot.publicKey,
        peerBundleLookup: () => null,
        ownDeviceKeys: () => [bobDevice.publicKey],
      );
      final decrypted = await bobCipher.decrypt(boxed);
      expect(decrypted, plaintext);
    });

    test('sender can decrypt own MultiDeviceBox messages (self-sync)',
        () async {
      final aliceRoot = await Identity.generate();
      final aliceDevice = await Identity.generate();
      final bobRoot = await Identity.generate();
      final bobDevice = await Identity.generate();

      final bobBundle = await DeviceBundle.publish(
        root: bobRoot,
        devices: [bobDevice.publicKey],
      );

      final cipher = MultiDeviceDmCipher(
        selfDevice: aliceDevice,
        selfRoot: aliceRoot,
        peerRootKey: bobRoot.publicKey,
        peerBundleLookup: () => bobBundle,
        ownDeviceKeys: () => [aliceDevice.publicKey],
      );

      final plaintext = Uint8List.fromList([42]);
      final boxed = await cipher.encrypt(plaintext);

      // Alice's own device can also decrypt (included in recipient list).
      final decrypted = await cipher.decrypt(boxed);
      expect(decrypted, plaintext);
    });
  });

  group('MultiDeviceDmCipher - offline root mode', () {
    test('encrypts via MultiDeviceBox without root (bundle available)',
        () async {
      final aliceDevice = await Identity.generate();
      final bobRoot = await Identity.generate();
      final bobDevice = await Identity.generate();

      final bobBundle = await DeviceBundle.publish(
        root: bobRoot,
        devices: [bobDevice.publicKey],
      );

      // No selfRoot — offline mode.
      final cipher = MultiDeviceDmCipher(
        selfDevice: aliceDevice,
        selfRoot: null,
        peerRootKey: bobRoot.publicKey,
        peerBundleLookup: () => bobBundle,
        ownDeviceKeys: () => [aliceDevice.publicKey],
      );

      final plaintext = Uint8List.fromList([7, 8, 9]);
      final boxed = await cipher.encrypt(plaintext);
      expect(boxed[0], 1, reason: 'MultiDeviceBox format');

      // Bob decrypts.
      final bobCipher = MultiDeviceDmCipher(
        selfDevice: bobDevice,
        selfRoot: null,
        peerRootKey: Uint8List(32), // doesn't matter — won't use PairBox
        peerBundleLookup: () => DeviceBundle(
          rootKey: Uint8List(32),
          devices: [aliceDevice.publicKey],
          publishedMs: 0,
          signature: Uint8List(64),
        ),
        ownDeviceKeys: () => [bobDevice.publicKey],
      );
      expect(await bobCipher.decrypt(boxed), plaintext);
    });

    test('encrypt throws when no bundle and root is offline', () async {
      final device = await Identity.generate();
      final peerRoot = await Identity.generate();

      final cipher = MultiDeviceDmCipher(
        selfDevice: device,
        selfRoot: null, // offline
        peerRootKey: peerRoot.publicKey,
        peerBundleLookup: () => null, // no bundle
        ownDeviceKeys: () => [device.publicKey],
      );

      expect(
        () => cipher.encrypt(Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
    });

    test('decrypt throws FormatException for PairBox message when root offline',
        () async {
      final aliceRoot = await Identity.generate();
      final bobRoot = await Identity.generate();
      final bobDevice = await Identity.generate();

      // Alice sends a PairBox message.
      final legacy = DmChannelCipher(aliceRoot, bobRoot.publicKey);
      final boxed = await legacy.encrypt(Uint8List.fromList([1]));

      // Bob tries to decrypt with offline root — should fail gracefully.
      final bobCipher = MultiDeviceDmCipher(
        selfDevice: bobDevice,
        selfRoot: null, // offline
        peerRootKey: aliceRoot.publicKey,
        peerBundleLookup: () => null,
        ownDeviceKeys: () => [bobDevice.publicKey],
      );

      expect(
        () => bobCipher.decrypt(boxed),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
