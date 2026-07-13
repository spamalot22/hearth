// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/update_checker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A manifest signed over the canonical bytes (what the backend + both client
/// paths now use). Optionally sign the OLD way (jsonEncode of the payload) to
/// reproduce a pre-2026-07-02 signature.
Future<Map<String, dynamic>> _manifest(
  Identity id, {
  String version = '0.6.1',
  int seq = 100,
  bool legacyScheme = false,
}) async {
  final androidHash = List.filled(64, 'a').join();
  final windowsHash = List.filled(64, 'b').join();
  final assets = {
    'android': {'file': 'a.apk', 'sha256': androidHash},
    'windows': {'file': 'w.zip', 'sha256': windowsHash},
  };
  final bytes = legacyScheme
      ? utf8.encode(
          jsonEncode({'version': version, 'seq': seq, 'assets': assets}),
        )
      : manifestSigningBytes(version, seq, assets);
  final sig = await id.sign(bytes);
  return {
    'version': version,
    'seq': seq,
    'assets': assets,
    'sig': hex.encode(sig),
  };
}

void main() {
  group('manifestSigningBytes', () {
    // Must stay byte-identical to backend/src/manifest.test.ts's `expected`
    // literal, or release signatures won't verify cross-language.
    test('is the canonical newline form with sorted asset keys', () {
      final androidHash = List.filled(64, 'a').join();
      final windowsHash = List.filled(64, 'b').join();
      final bytes = manifestSigningBytes('0.5.9', 3, {
        // windows-first to prove the output sorts to android first
        'windows': {'file': 'w.zip', 'sha256': windowsHash},
        'android': {'file': 'a.apk', 'sha256': androidHash},
      });
      expect(
        utf8.decode(bytes),
        'hearth/manifest/v1\n0.5.9\n3\nandroid\na.apk\n$androidHash\n'
        'windows\nw.zip\n$windowsHash',
      );
    });
  });

  // verifyManifest is the single verification the GitHub check AND the P2P
  // VersionControl path both route through — so these guard both against a
  // signing-format regression. The canonical/legacy split is exactly the
  // 2026-07-02 change that stranded pre-canonical clients (e.g. 0.5.26).
  group('verifyManifest (shared by relay + P2P paths)', () {
    test('accepts a canonically-signed manifest', () async {
      final id = await Identity.generate();
      final info = await verifyManifest(await _manifest(id), id.publicKeyHex);
      expect(info, isNotNull);
      expect(info!.version, '0.6.1');
      expect(info.seq, 100);
    });

    test('rejects an old jsonEncode-signed manifest', () async {
      // The pre-2026-07-02 scheme. A client on the canonical verifier must
      // reject it — this is *why* 0.5.26 (old signer) can't be verified by new
      // clients and vice-versa; changing the format is a breaking change.
      final id = await Identity.generate();
      final legacy = await _manifest(id, legacyScheme: true);
      expect(await verifyManifest(legacy, id.publicKeyHex), isNull);
    });

    test('rejects a tampered manifest (seq bumped after signing)', () async {
      final id = await Identity.generate();
      final m = await _manifest(id, seq: 100)
        ..['seq'] = 999;
      expect(await verifyManifest(m, id.publicKeyHex), isNull);
    });

    test('rejects the wrong signer', () async {
      final id = await Identity.generate();
      final other = await Identity.generate();
      expect(
        await verifyManifest(await _manifest(id), other.publicKeyHex),
        isNull,
      );
    });

    test('rejects a manifest missing fields', () async {
      final id = await Identity.generate();
      final m = await _manifest(id)
        ..remove('assets');
      expect(await verifyManifest(m, id.publicKeyHex), isNull);
    });

    test('rejects malformed signature hex without throwing', () async {
      final id = await Identity.generate();
      final m = await _manifest(id)
        ..['sig'] = 'not-hex';
      expect(await verifyManifest(m, id.publicKeyHex), isNull);
    });

    test('rejects malformed field types without throwing', () async {
      final id = await Identity.generate();
      final m = await _manifest(id)
        ..['assets'] = ['not', 'a', 'map'];
      expect(await verifyManifest(m, id.publicKeyHex), isNull);
    });
  });

  group('checkForUpdate', () {
    final manifestUrl = Uri.parse('https://example.test/manifest.json');

    test('returns UpToDate when releasePublicKeyHex is empty', () async {
      // The const releasePublicKeyHex defaults to '' in dev, so checkForUpdate
      // should short-circuit. We test this is the behaviour by calling it.
      final result = await checkForUpdate();
      expect(result, isA<UpToDate>());
    });

    test('offers a correctly signed newer GitHub release', () async {
      final signer = await Identity.generate();
      final manifest = await _manifest(signer, version: '0.7.16', seq: 200);
      final client = MockClient((request) async {
        expect(request.url, manifestUrl);
        return http.Response(jsonEncode(manifest), 200);
      });

      final result = await checkForUpdate(
        manifestUrl: manifestUrl,
        client: client,
        currentVersion: '0.7.15',
        publicKeyHex: signer.publicKeyHex,
        readLastSeq: () async => 100,
        writeLastSeq: (_) async {},
      );

      expect(result, isA<UpdateAvailable>());
      expect((result as UpdateAvailable).info.version, '0.7.16');
      client.close();
    });

    test('never treats an older signed release as an update', () async {
      final signer = await Identity.generate();
      final manifest = await _manifest(signer, version: '0.7.14', seq: 999);
      final client = MockClient(
        (_) async => http.Response(jsonEncode(manifest), 200),
      );

      final result = await checkForUpdate(
        manifestUrl: manifestUrl,
        client: client,
        currentVersion: '0.7.15',
        publicKeyHex: signer.publicKeyHex,
        readLastSeq: () async => 0,
        writeLastSeq: (_) async {},
      );

      expect(result, isA<UpToDate>());
      client.close();
    });

    test('records the sequence for the currently installed release', () async {
      final signer = await Identity.generate();
      final manifest = await _manifest(signer, version: 'v0.7.15', seq: 200);
      final client = MockClient(
        (_) async => http.Response(jsonEncode(manifest), 200),
      );
      var persisted = 0;

      final result = await checkForUpdate(
        manifestUrl: manifestUrl,
        client: client,
        currentVersion: '0.7.15',
        publicKeyHex: signer.publicKeyHex,
        readLastSeq: () async => 100,
        writeLastSeq: (seq) async => persisted = seq,
      );

      expect(result, isA<UpToDate>());
      expect(persisted, 200);
      client.close();
    });

    test('returns unavailable on connection failure', () async {
      final signer = await Identity.generate();
      final client = MockClient((_) async {
        throw http.ClientException('connection refused');
      });
      final result = await checkForUpdate(
        manifestUrl: manifestUrl,
        client: client,
        currentVersion: '0.7.15',
        publicKeyHex: signer.publicKeyHex,
      );
      expect(result, isA<UpdateCheckUnavailable>());
      client.close();
    });

    test('returns unavailable when GitHub has no manifest', () async {
      final signer = await Identity.generate();
      final client = MockClient((_) async => http.Response('not found', 404));
      final result = await checkForUpdate(
        manifestUrl: manifestUrl,
        client: client,
        currentVersion: '0.7.15',
        publicKeyHex: signer.publicKeyHex,
      );
      expect(result, isA<UpdateCheckUnavailable>());
      client.close();
    });
  });

  group('ReleaseVersion', () {
    test('compares numeric components and accepts an optional v prefix', () {
      expect(isNewerRelease('0.7.16', '0.7.15'), isTrue);
      expect(isNewerRelease('0.10.0', '0.9.9'), isTrue);
      expect(isNewerRelease('v0.7.15', '0.7.15'), isFalse);
      expect(isNewerRelease('0.7.14', 'v0.7.15'), isFalse);
    });

    test('rejects malformed and prerelease tags', () {
      expect(ReleaseVersion.tryParse('dev'), isNull);
      expect(ReleaseVersion.tryParse('0.7.16-beta.1'), isNull);
      expect(ReleaseVersion.tryParse('01.7.16'), isNull);
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
