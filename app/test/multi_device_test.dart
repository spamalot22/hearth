// SPDX-License-Identifier: AGPL-3.0-or-later
// A4: two devices of the same root can coexist in a channel's mesh — distinct
// device keys, both resolving to the same root identity for display.
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two devices of the same root have distinct mesh identities', () async {
    final root = await Identity.generate();
    final deviceA = await Identity.generate();
    final deviceB = await Identity.generate();

    // Both devices get certs from the same root.
    final certA = await DeviceCert.issue(
      root: root,
      deviceKey: deviceA.publicKey,
      name: 'Phone',
    );
    final certB = await DeviceCert.issue(
      root: root,
      deviceKey: deviceB.publicKey,
      name: 'Laptop',
    );

    // The mesh identities (device keys) are distinct.
    expect(deviceA.publicKeyHex, isNot(deviceB.publicKeyHex));
    expect(deviceA.publicKeyHex, isNot(root.publicKeyHex));
    expect(deviceB.publicKeyHex, isNot(root.publicKeyHex));

    // Both certs verify against the same root.
    expect(await certA.verify(), isTrue);
    expect(await certB.verify(), isTrue);
    expect(certA.rootKeyHex, root.publicKeyHex);
    expect(certB.rootKeyHex, root.publicKeyHex);
  });

  test('deviceToRoot resolves both devices to the same root', () async {
    final root = await Identity.generate();
    final deviceA = await Identity.generate();
    final deviceB = await Identity.generate();

    final certA = await DeviceCert.issue(
      root: root,
      deviceKey: deviceA.publicKey,
      name: 'Phone',
    );
    final certB = await DeviceCert.issue(
      root: root,
      deviceKey: deviceB.publicKey,
      name: 'Laptop',
    );

    // Simulate messages from two devices of the same root.
    final msgA = await Message.create(
      author: root,
      channel: 'test-channel',
      payload: Uint8List.fromList([1, 2, 3]),
      signingDevice: deviceA,
      deviceCert: certA,
    );
    final msgB = await Message.create(
      author: root,
      channel: 'test-channel',
      payload: Uint8List.fromList([4, 5, 6]),
      signingDevice: deviceB,
      deviceCert: certB,
    );

    // Both verify.
    expect(await msgA.verify(), isTrue);
    expect(await msgB.verify(), isTrue);

    // Both have distinct device keys but the same author.
    expect(hex.encode(msgA.device!), deviceA.publicKeyHex);
    expect(hex.encode(msgB.device!), deviceB.publicKeyHex);
    expect(hex.encode(msgA.author), hex.encode(msgB.author));
    expect(hex.encode(msgA.author), root.publicKeyHex);

    // Build the deviceToRoot map as ChannelSession does.
    final deviceToRoot = <String, String>{};
    for (final msg in [msgA, msgB]) {
      if (msg.device != null && msg.cert != null) {
        deviceToRoot[hex.encode(msg.device!)] = hex.encode(msg.author);
      }
    }

    // Both device keys resolve to the same root.
    expect(deviceToRoot[deviceA.publicKeyHex], root.publicKeyHex);
    expect(deviceToRoot[deviceB.publicKeyHex], root.publicKeyHex);
  });

  test('typing indicator resolves device keys to root via deviceToRoot',
      () async {
    final root = await Identity.generate();
    final deviceA = await Identity.generate();
    final deviceB = await Identity.generate();

    final deviceToRoot = <String, String>{
      deviceA.publicKeyHex: root.publicKeyHex,
      deviceB.publicKeyHex: root.publicKeyHex,
    };

    // Simulate _handleTyping logic: resolve device → root.
    final typingPeers = <String>{};
    for (final deviceHex in [deviceA.publicKeyHex, deviceB.publicKeyHex]) {
      final resolved = deviceToRoot[deviceHex] ?? deviceHex;
      typingPeers.add(resolved);
    }

    // Both devices typing should resolve to a single root entry.
    expect(typingPeers, hasLength(1));
    expect(typingPeers.single, root.publicKeyHex);
  });
}
