// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/rendezvous.dart';

void main() {
  group('RendezvousIntro', () {
    test('round trips and verifies a root-authorised active device', () async {
      final root = await Identity.generate();
      final device = await Identity.generate();
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'phone',
      );
      final bundle = await DeviceBundle.publish(
        root: root,
        devices: [device.publicKey],
      );

      final decoded = RendezvousIntro.decode(
        HaveFrame([RendezvousIntro(cert: cert, bundle: bundle).encode()]),
      );

      expect(decoded, isNotNull);
      expect(await decoded!.verifyForPeer(device.publicKeyHex), isTrue);
      expect(decoded.cert.rootKeyHex, root.publicKeyHex);
    });

    test('rejects a bundle signed by a different root', () async {
      final root = await Identity.generate();
      final otherRoot = await Identity.generate();
      final device = await Identity.generate();
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'phone',
      );
      final bundle = await DeviceBundle.publish(
        root: otherRoot,
        devices: [device.publicKey],
      );

      expect(
        await RendezvousIntro(
          cert: cert,
          bundle: bundle,
        ).verifyForPeer(device.publicKeyHex),
        isFalse,
      );
    });

    test('rejects a valid bundle that omits the connecting device', () async {
      final root = await Identity.generate();
      final connectingDevice = await Identity.generate();
      final otherDevice = await Identity.generate();
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: connectingDevice.publicKey,
        name: 'phone',
      );
      final bundle = await DeviceBundle.publish(
        root: root,
        devices: [otherDevice.publicKey],
      );

      expect(
        await RendezvousIntro(
          cert: cert,
          bundle: bundle,
        ).verifyForPeer(connectingDevice.publicKeyHex),
        isFalse,
      );
    });
  });
}
