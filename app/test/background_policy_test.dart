// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/background_policy.dart';

void main() {
  test(
    'background notifications honor blocked roots and root-scoped revocations',
    () async {
      final root = await Identity.generate();
      final other = await Identity.generate();
      final device = await Identity.generate();
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'Phone',
      );
      final message = await Message.create(
        author: root,
        channel: 'room',
        signingDevice: device,
        deviceCert: cert,
        payload: Uint8List(0),
      );
      final author = base64Url.encode(root.publicKey);
      bool allowed({
        Set<String>? authors,
        Set<String> revoked = const {},
        String? self,
      }) => backgroundSenderAllowed(
        message,
        allowedAuthors: authors ?? {author},
        revokedDevices: revoked,
        selfAuthor: self,
      );
      expect(allowed(), isTrue);
      expect(allowed(authors: {}), isFalse);
      expect(allowed(self: author), isFalse);
      expect(
        allowed(revoked: {'$author:${base64Url.encode(device.publicKey)}'}),
        isFalse,
      );
      expect(
        allowed(
          revoked: {
            '${base64Url.encode(other.publicKey)}:${base64Url.encode(device.publicKey)}',
          },
        ),
        isTrue,
      );
    },
  );
}
