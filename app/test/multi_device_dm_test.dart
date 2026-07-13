// SPDX-License-Identifier: AGPL-3.0-or-later
// MultiDeviceDmCipher tests — no legacy PairBox, MultiDeviceBox only.
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';

void main() {
  group('MultiDeviceDmCipher', () {
    test('encrypts via MultiDeviceBox when bundle available', () async {
      final aliceDevice = await Identity.generate();
      final bobDevice = await Identity.generate();
      final bobRoot = await Identity.generate();

      final bobBundle = await DeviceBundle.publish(
        root: bobRoot,
        devices: [bobDevice.publicKey],
      );

      final cipher = MultiDeviceDmCipher(
        selfDevice: aliceDevice,
        peerBundleLookup: () => bobBundle,
        ownDeviceKeys: () => [aliceDevice.publicKey],
      );

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final boxed = await cipher.encrypt(plaintext);
      expect(boxed[0], 1, reason: 'MultiDeviceBox format');

      // Bob decrypts.
      final aliceRoot = await Identity.generate();
      final aliceBundle = await DeviceBundle.publish(
        root: aliceRoot,
        devices: [aliceDevice.publicKey],
      );
      final bobCipher = MultiDeviceDmCipher(
        selfDevice: bobDevice,
        peerBundleLookup: () => aliceBundle,
        ownDeviceKeys: () => [bobDevice.publicKey],
      );
      final decrypted = await bobCipher.decrypt(boxed);
      expect(decrypted, plaintext);
    });

    test('throws when no bundle available (peer must update)', () async {
      final device = await Identity.generate();

      final cipher = MultiDeviceDmCipher(
        selfDevice: device,
        peerBundleLookup: () => null,
        ownDeviceKeys: () => [device.publicKey],
      );

      expect(
        () => cipher.encrypt(Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
    });

    test('sender can decrypt own messages (self-sync)', () async {
      final aliceDevice = await Identity.generate();
      final bobRoot = await Identity.generate();
      final bobDevice = await Identity.generate();

      final bobBundle = await DeviceBundle.publish(
        root: bobRoot,
        devices: [bobDevice.publicKey],
      );

      final cipher = MultiDeviceDmCipher(
        selfDevice: aliceDevice,
        peerBundleLookup: () => bobBundle,
        ownDeviceKeys: () => [aliceDevice.publicKey],
      );

      final plaintext = Uint8List.fromList([42]);
      final boxed = await cipher.encrypt(plaintext);
      final decrypted = await cipher.decrypt(boxed);
      expect(decrypted, plaintext);
    });

    test('decrypt uses senderDevice hint for O(1) lookup', () async {
      final aliceDevice = await Identity.generate();
      final bobDevice = await Identity.generate();
      final bobRoot = await Identity.generate();

      final bobBundle = await DeviceBundle.publish(
        root: bobRoot,
        devices: [bobDevice.publicKey],
      );

      final cipher = MultiDeviceDmCipher(
        selfDevice: aliceDevice,
        peerBundleLookup: () => bobBundle,
        ownDeviceKeys: () => [aliceDevice.publicKey],
      );

      final boxed = await cipher.encrypt(Uint8List.fromList([7, 8, 9]));

      // Decrypt with explicit sender device (O(1) path).
      final bobCipher = MultiDeviceDmCipher(
        selfDevice: bobDevice,
        peerBundleLookup: () => DeviceBundle(
          rootKey: Uint8List(32),
          devices: [aliceDevice.publicKey],
          publishedMs: 0,
          signature: Uint8List(64),
        ),
        ownDeviceKeys: () => [bobDevice.publicKey],
      );
      final decrypted = await bobCipher.decrypt(
        boxed,
        senderDevice: aliceDevice.publicKey,
      );
      expect(decrypted, Uint8List.fromList([7, 8, 9]));
    });
  });

  group('DM mesh admission', () {
    test('allows only roots and active device keys', () async {
      final ownRoot = await Identity.generate();
      final ownDevice = await Identity.generate();
      final peerRoot = await Identity.generate();
      final peerDevice = await Identity.generate();
      final stranger = await Identity.generate();
      final peerBundle = await DeviceBundle.publish(
        root: peerRoot,
        devices: [peerDevice.publicKey],
      );
      final manager = ChannelManager(
        identity: ownRoot,
        meshIdentity: ownDevice,
        relayUrl: Uri.parse('http://localhost:8787'),
        live: false,
        onUpdate: () {},
        peerBundleLookup: (rootHex) =>
            rootHex == peerRoot.publicKeyHex ? peerBundle : null,
        ownDeviceKeys: () => [ownDevice.publicKey],
      );

      await manager.openDm(peerRoot.publicKey);
      final channelId = manager.activeId!;
      expect(
        manager.isPeerAllowedForChannel(channelId, ownRoot.publicKeyHex),
        isTrue,
      );
      expect(
        manager.isPeerAllowedForChannel(channelId, ownDevice.publicKeyHex),
        isTrue,
      );
      expect(
        manager.isPeerAllowedForChannel(channelId, peerRoot.publicKeyHex),
        isTrue,
      );
      expect(
        manager.isPeerAllowedForChannel(channelId, peerDevice.publicKeyHex),
        isTrue,
      );
      expect(
        manager.isPeerAllowedForChannel(channelId, stranger.publicKeyHex),
        isFalse,
      );
      await manager.close();
    });

    test('group channel membership remains capability-based', () async {
      final ownRoot = await Identity.generate();
      final stranger = await Identity.generate();
      final manager = ChannelManager(
        identity: ownRoot,
        relayUrl: Uri.parse('http://localhost:8787'),
        live: false,
        onUpdate: () {},
      );

      await manager.openGroup('group-id', Uint8List(32));
      expect(
        manager.isPeerAllowedForChannel('group-id', stranger.publicKeyHex),
        isTrue,
      );
      await manager.close();
    });

    test('rejects relay messages authored by a DM outsider', () async {
      final me = await Identity.generate();
      final peer = await Identity.generate();
      final outsider = await Identity.generate();
      final manager = ChannelManager(
        identity: me,
        relayUrl: Uri.parse('http://localhost:8787'),
        live: false,
        onUpdate: () {},
      );
      await manager.openDm(peer.publicKey);
      final session = manager.active!;

      await session.engine.receive(
        await Message.create(
          author: outsider,
          channel: session.channelId,
          payload: Uint8List.fromList([1, 2, 3]),
        ),
      );

      expect(session.repository.length, 0);
      await manager.close();
    });
  });
}
