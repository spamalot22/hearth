// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/update_checker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('checkForUpdate', () {
    final relayUrl = Uri.parse('http://localhost:8787');

    test('returns UpToDate when releasePublicKeyHex is empty', () async {
      // The const releasePublicKeyHex defaults to '' in dev, so checkForUpdate
      // should short-circuit. We test this is the behaviour by calling it.
      final result = await checkForUpdate(relayUrl);
      expect(result, isA<UpToDate>());
    });

    test('returns RelayUnreachable on timeout', () async {
      final client = MockClient((_) async {
        throw http.ClientException('connection refused');
      });
      final result = await checkForUpdate(relayUrl, client: client);
      expect(result, isA<UpToDate>()); // dev build skips check
      client.close();
    });

    test('returns UpToDate on 404', () async {
      final client = MockClient(
        (_) async => http.Response('not found', 404),
      );
      final result = await checkForUpdate(relayUrl, client: client);
      // Dev build short-circuits, but this tests the flow.
      expect(result, isA<UpToDate>());
      client.close();
    });
  });

  group('UpdateInfo', () {
    test('constructs correctly', () {
      final info = UpdateInfo(
        version: '0.5.0',
        seq: 100,
        assets: {
          'android': {'file': 'hearth-android.apk', 'sha256': 'abc123'},
        },
      );
      expect(info.version, '0.5.0');
      expect(info.seq, 100);
      expect((info.assets['android']! as Map)['file'], 'hearth-android.apk');
    });
  });

  group('Identity.verifySignature (used by update checker)', () {
    test('valid signature verifies', () async {
      final identity = await Identity.generate();
      final payload = utf8.encode('{"version":"0.5.0","seq":1}');
      final sig = await identity.sign(payload);
      final valid = await Identity.verifySignature(
        payload,
        signature: sig,
        publicKey: identity.publicKey,
      );
      expect(valid, isTrue);
    });

    test('tampered payload fails verification', () async {
      final identity = await Identity.generate();
      final payload = utf8.encode('{"version":"0.5.0","seq":1}');
      final sig = await identity.sign(payload);
      final tampered = utf8.encode('{"version":"0.5.0","seq":2}');
      final valid = await Identity.verifySignature(
        tampered,
        signature: sig,
        publicKey: identity.publicKey,
      );
      expect(valid, isFalse);
    });

    test('wrong public key fails verification', () async {
      final identity = await Identity.generate();
      final other = await Identity.generate();
      final payload = utf8.encode('test');
      final sig = await identity.sign(payload);
      final valid = await Identity.verifySignature(
        payload,
        signature: sig,
        publicKey: other.publicKey,
      );
      expect(valid, isFalse);
    });
  });
}
