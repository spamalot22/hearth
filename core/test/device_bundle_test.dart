// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceBundle', () {
    test('a root-signed bundle verifies', () async {
      final root = await Identity.generate();
      final d1 = (await Identity.generate()).publicKey;
      final d2 = (await Identity.generate()).publicKey;

      final bundle = await DeviceBundle.publish(
        root: root,
        devices: [d1, d2],
      );

      expect(await bundle.verify(), isTrue);
      expect(bundle.rootKey, root.publicKey);
      expect(bundle.devices, hasLength(2));
      expect(bundle.devices[0], d1);
      expect(bundle.devices[1], d2);
    });

    test('a tampered bundle does not verify', () async {
      final root = await Identity.generate();
      final d1 = (await Identity.generate()).publicKey;

      final bundle = await DeviceBundle.publish(
        root: root,
        devices: [d1],
      );

      // Tamper: swap the device key.
      final tampered = DeviceBundle(
        rootKey: bundle.rootKey,
        devices: [(await Identity.generate()).publicKey],
        publishedMs: bundle.publishedMs,
        signature: bundle.signature,
      );
      expect(await tampered.verify(), isFalse);
    });

    test('a bundle signed by the wrong root does not verify', () async {
      final root = await Identity.generate();
      final impostor = await Identity.generate();
      final d1 = (await Identity.generate()).publicKey;

      final real = await DeviceBundle.publish(root: impostor, devices: [d1]);
      final forged = DeviceBundle(
        rootKey: root.publicKey, // claim the real root
        devices: real.devices,
        publishedMs: real.publishedMs,
        signature: real.signature, // impostor's signature
      );
      expect(await forged.verify(), isFalse);
    });

    test('round-trips through JSON', () async {
      final root = await Identity.generate();
      final d1 = (await Identity.generate()).publicKey;
      final d2 = (await Identity.generate()).publicKey;

      final bundle = await DeviceBundle.publish(
        root: root,
        devices: [d1, d2],
        publishedMs: 1730000000000,
      );

      final back = DeviceBundle.fromJson(bundle.toJson());
      expect(back.rootKey, bundle.rootKey);
      expect(back.devices, hasLength(2));
      expect(back.devices[0], d1);
      expect(back.devices[1], d2);
      expect(back.publishedMs, 1730000000000);
      expect(await back.verify(), isTrue);
    });

    test('rejects non-32-byte device keys', () {
      expect(
        () async => DeviceBundle.publish(
          root: await Identity.generate(),
          devices: [Uint8List(16)], // too short
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('monotonic: a newer bundle supersedes an older one', () async {
      final root = await Identity.generate();
      final d1 = (await Identity.generate()).publicKey;
      final d2 = (await Identity.generate()).publicKey;

      final older = await DeviceBundle.publish(
        root: root,
        devices: [d1],
        publishedMs: 1000,
      );
      final newer = await DeviceBundle.publish(
        root: root,
        devices: [d1, d2],
        publishedMs: 2000,
      );

      // Newer supersedes older (publishedMs is higher).
      expect(newer.publishedMs, greaterThan(older.publishedMs));
      expect(newer.devices, hasLength(2));
    });
  });
}
