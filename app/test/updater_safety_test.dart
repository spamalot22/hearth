// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/screen_share.dart';
import 'package:hearth/updater_io.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_filex/open_filex.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cleanup recognises only Hearth update package basenames', () {
    expect(isUpdatePackageName('hearth-android.apk'), isTrue);
    expect(isUpdatePackageName('hearth-windows-setup.exe'), isTrue);
    expect(isUpdatePackageName('unrelated.exe'), isFalse);
    expect(isUpdatePackageName('not-hearth.exe'), isFalse);
    expect(isUpdatePackageName('hearth-web.zip'), isFalse);
  });

  group('streamed update download', () {
    late Directory dir;
    late File file;
    final uri = Uri.parse('https://example.test/update.exe');
    final bytes = utf8.encode('verified installer');
    final hash = sha256.convert(bytes).toString();

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hearth-download-test-');
      file = File('${dir.path}/update.exe');
    });
    tearDown(() => dir.delete(recursive: true));

    test('writes and verifies streamed bytes', () async {
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.length,
        ),
      );
      addTearDown(client.close);
      await downloadVerifiedUpdate(uri, file, hash, client: client);
      expect(await file.readAsBytes(), bytes);
    });

    test('stalled stream times out and removes partial installer', () async {
      final stream = StreamController<List<int>>();
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(stream.stream, 200),
      );
      addTearDown(client.close);
      addTearDown(stream.close);
      stream.add(bytes.take(4).toList());
      await expectLater(
        downloadVerifiedUpdate(
          uri,
          file,
          hash,
          client: client,
          idleTimeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(await file.exists(), isFalse);
    });

    test('corruption and oversized streams are removed', () async {
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(Stream.value(bytes), 200),
      );
      addTearDown(client.close);
      await expectLater(
        downloadVerifiedUpdate(uri, file, '0' * 64, client: client),
        throwsStateError,
      );
      expect(await file.exists(), isFalse);
      await expectLater(
        downloadVerifiedUpdate(uri, file, hash, client: client, maxBytes: 4),
        throwsStateError,
      );
      expect(await file.exists(), isFalse);
    });
  });

  test('Windows installer runs silently with recovery logging', () {
    final args = windowsInstallerArguments(r'C:\logs\update.log');

    expect(args, contains('/VERYSILENT'));
    expect(args, contains('/CLOSEAPPLICATIONS'));
    expect(args, contains(r'/LOG=C:\logs\update.log'));
  });

  test('screen mesh is named by the authenticated sharer device', () {
    expect(screenMeshChannel('group', 'device-key'), 'screen:group:device-key');
  });

  test(
    'verified Android APK schedules durable cleanup before install',
    () async {
      const downloader = MethodChannel('hearth/downloader');
      final calls = <MethodCall>[];
      final events = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(downloader, (call) async {
            calls.add(call);
            events.add(call.method);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(downloader, null),
      );

      final dir = await Directory.systemTemp.createTemp('hearth-update-test-');
      addTearDown(() => dir.delete(recursive: true));
      final bytes = utf8.encode('verified apk');
      final apk = File('${dir.path}/hearth-android.apk');
      await apk.writeAsBytes(bytes);
      var pendingCleared = false;

      await verifyAndInstallDownloadedApk(
        42,
        apk.path,
        sha256.convert(bytes).toString(),
        clearPending: () async {
          pendingCleared = true;
          events.add('clearPending');
        },
        openFile: (path) async {
          expect(path, apk.path);
          expect(pendingCleared, isTrue);
          events.add('openInstaller');
          return OpenResult();
        },
      );

      expect(events, ['scheduleCleanup', 'clearPending', 'openInstaller']);
      expect(calls, hasLength(1));
      expect(calls.single.arguments, {'id': 42, 'delayMs': 120000});
    },
  );

  test(
    'rejected Android APK is removed from DownloadManager and disk',
    () async {
      const downloader = MethodChannel('hearth/downloader');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(downloader, (call) async {
            calls.add(call);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(downloader, null),
      );

      final dir = await Directory.systemTemp.createTemp('hearth-update-test-');
      addTearDown(() => dir.delete(recursive: true));
      final apk = File('${dir.path}/hearth-android.apk');
      await apk.writeAsString('tampered apk');

      await expectLater(
        verifyAndInstallDownloadedApk(
          43,
          apk.path,
          sha256.convert(utf8.encode('expected apk')).toString(),
          clearPending: () async {},
          openFile: (_) async => OpenResult(),
        ),
        throwsStateError,
      );

      expect(calls.map((call) => call.method), ['cancel']);
      expect(await apk.exists(), isFalse);
    },
  );
}
