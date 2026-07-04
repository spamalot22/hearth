// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceCert', () {
    test('a root-issued cert verifies', () async {
      final root = await Identity.generate();
      final device = await Identity.generate(); // stands in for a device subkey
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: "Sam's phone",
      );
      expect(await cert.verify(), isTrue);
      expect(cert.rootKey, root.publicKey);
      expect(cert.deviceKey, device.publicKey);
      expect(cert.name, "Sam's phone");
    });

    test('a cert signed by the wrong key does not verify', () async {
      final root = await Identity.generate();
      final impostor = await Identity.generate();
      final device = await Identity.generate();
      // Issue under the impostor but claim the real root's key.
      final real = await DeviceCert.issue(
        root: impostor,
        deviceKey: device.publicKey,
        name: 'x',
      );
      final forged = DeviceCert(
        rootKey: root.publicKey, // claim the real root
        deviceKey: real.deviceKey,
        name: real.name,
        issuedMs: real.issuedMs,
        signature: real.signature, // but impostor's signature
      );
      expect(await forged.verify(), isFalse);
    });

    test('tampering with a field breaks verification', () async {
      final root = await Identity.generate();
      final device = await Identity.generate();
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'laptop',
      );
      final tampered = DeviceCert(
        rootKey: cert.rootKey,
        deviceKey: cert.deviceKey,
        name: 'PHONE', // changed after signing
        issuedMs: cert.issuedMs,
        signature: cert.signature,
      );
      expect(await tampered.verify(), isFalse);
    });

    test('round-trips through json', () async {
      final root = await Identity.generate();
      final device = await Identity.generate();
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'tablet',
        issuedMs: 1730000000000,
      );
      final back = DeviceCert.fromJson(cert.toJson());
      expect(back.rootKey, cert.rootKey);
      expect(back.deviceKey, cert.deviceKey);
      expect(back.name, 'tablet');
      expect(back.issuedMs, 1730000000000);
      expect(await back.verify(), isTrue);
    });

    test('name is bound by the signature (no field-injection)', () async {
      // Two different names must produce different signed bytes even if a
      // concatenation could collide — CBOR length-prefixes each field.
      final root = await Identity.generate();
      final device = await Identity.generate();
      final a = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'ab',
        issuedMs: 1,
      );
      final b = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'a',
        issuedMs: 1,
      );
      expect(a.signature, isNot(b.signature));
    });
  });

  group('DeviceRevocation', () {
    test('a root-issued revocation verifies; wrong signer does not', () async {
      final root = await Identity.generate();
      final other = await Identity.generate();
      final deviceKey = Uint8List.fromList(
        (await Identity.generate()).publicKey,
      );
      final rev = await DeviceRevocation.issue(
        root: root,
        deviceKey: deviceKey,
      );
      expect(await rev.verify(), isTrue);
      expect(rev.deviceKey, deviceKey);

      final forged = DeviceRevocation(
        rootKey: root.publicKey,
        deviceKey: deviceKey,
        revokedMs: rev.revokedMs,
        signature: (await DeviceRevocation.issue(
          root: other,
          deviceKey: deviceKey,
          revokedMs: rev.revokedMs,
        )).signature,
      );
      expect(await forged.verify(), isFalse);
    });

    test('round-trips through json', () async {
      final root = await Identity.generate();
      final deviceKey = Uint8List.fromList(
        (await Identity.generate()).publicKey,
      );
      final rev = await DeviceRevocation.issue(
        root: root,
        deviceKey: deviceKey,
        revokedMs: 42,
      );
      final back = DeviceRevocation.fromJson(rev.toJson());
      expect(back.deviceKey, deviceKey);
      expect(back.revokedMs, 42);
      expect(await back.verify(), isTrue);
    });
  });
}
