// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/device_store.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hearth-device-store-');
    Hive.init(temp.path);
  });

  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test('revocations survive bundle removal and remain root-scoped', () async {
    final legitimateRoot = await Identity.generate();
    final otherRoot = await Identity.generate();
    final device = await Identity.generate();
    var store = await DeviceStore.open();

    expect(
      await store.setBundle(
        await DeviceBundle.publish(
          root: legitimateRoot,
          devices: [device.publicKey],
          publishedMs: 1000,
        ),
      ),
      isTrue,
    );
    expect(
      await store.setBundle(
        await DeviceBundle.publish(
          root: legitimateRoot,
          devices: const [],
          publishedMs: 2000,
        ),
      ),
      isTrue,
    );

    // Reopen to prove the removed device's root relationship is persisted.
    await Hive.close();
    Hive.init(temp.path);
    store = await DeviceStore.open();
    final revocation = await DeviceRevocation.issue(
      root: legitimateRoot,
      deviceKey: device.publicKey,
      revokedMs: 3000,
    );
    expect(await store.addRevocation(revocation), isTrue);
    expect(
      store.isRevoked(legitimateRoot.publicKeyHex, device.publicKeyHex),
      isTrue,
    );
    expect(
      store.isRevoked(otherRoot.publicKeyHex, device.publicKeyHex),
      isFalse,
    );
  });

  test(
    'stale bundles add authorised devices without replacing latest',
    () async {
      final root = await Identity.generate();
      final oldDevice = await Identity.generate();
      final newDevice = await Identity.generate();
      final store = await DeviceStore.open();

      final latest = await DeviceBundle.publish(
        root: root,
        devices: [newDevice.publicKey],
        publishedMs: 2000,
      );
      final stale = await DeviceBundle.publish(
        root: root,
        devices: [oldDevice.publicKey],
        publishedMs: 1000,
      );

      expect(await store.setBundle(latest), isTrue);
      expect(await store.setBundle(stale), isTrue);
      expect(store.bundleFor(root.publicKeyHex)?.publishedMs, 2000);
      expect(
        store
            .authorizedDeviceKeys(root.publicKeyHex)
            .map((key) => key.toList()),
        unorderedEquals([oldDevice.publicKey, newDevice.publicKey]),
      );
      expect(store.rootForDevice(oldDevice.publicKeyHex), root.publicKeyHex);

      final revocation = await DeviceRevocation.issue(
        root: root,
        deviceKey: oldDevice.publicKey,
        revokedMs: 3000,
      );
      expect(await store.addRevocation(revocation), isTrue);
      expect(
        store
            .authorizedDeviceKeys(root.publicKeyHex)
            .map((key) => key.toList()),
        [newDevice.publicKey],
      );
    },
  );
}
