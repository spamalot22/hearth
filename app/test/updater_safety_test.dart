// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/screen_share.dart';
import 'package:hearth/updater_io.dart';
import 'package:open_filex/open_filex.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows updater never deletes the install directory', () {
    final script = buildWindowsUpdateScript();
    expect(script, isNot(contains('rmdir')));
    expect(script, isNot(contains('Remove-Item -LiteralPath \$InstallDir')));
    expect(script, contains('Copy-Item -Destination \$InstallDir'));
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
