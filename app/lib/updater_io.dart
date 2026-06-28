// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'update_checker.dart';

/// Downloads this platform's release asset directly from GitHub Releases,
/// verifies its SHA-256 against the signed manifest, then launches the platform
/// install. A tampered download is caught by hash mismatch.
/// Reports download progress (0–1) via [onProgress].
///
/// On Windows this replaces the running install and relaunches (it calls
/// `exit(0)`, so it does not return). On Android it hands the verified APK to the
/// system package installer.
Future<void> downloadAndInstall(
  UpdateInfo info, {
  void Function(double progress)? onProgress,
}) async {
  final asset = _platformAsset(info.assets);
  if (asset == null) {
    throw UnsupportedError('No update asset for this platform.');
  }
  final fileName = asset['file'] as String;
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(fileName)) {
    throw StateError('unsafe update asset filename: $fileName');
  }
  final expectedHash = (asset['sha256'] as String).toLowerCase();

  // Download directly from the public GitHub release.
  final url = Uri.parse(
    'https://github.com/spamalot22/hearth/releases/download/${info.version}/$fileName',
  );
  final dir = await getTemporaryDirectory();
  final outFile = File('${dir.path}${Platform.pathSeparator}$fileName');
  final client = http.Client();
  try {
    final resp = await client.send(http.Request('GET', url));
    if (resp.statusCode != 200) {
      throw http.ClientException(
        'download failed: HTTP ${resp.statusCode}',
        url,
      );
    }
    final total = resp.contentLength ?? 0;
    // Hash while streaming to disk so the whole file never sits in memory.
    final digestSink = AccumulatorSink<Digest>();
    final hashInput = sha256.startChunkedConversion(digestSink);
    final sink = outFile.openWrite();
    var received = 0;
    await for (final chunk in resp.stream) {
      hashInput.add(chunk);
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
    hashInput.close();

    if (digestSink.events.single.toString() != expectedHash) {
      await outFile.delete();
      throw StateError('update hash mismatch — download rejected');
    }
    await _install(outFile.path);
  } finally {
    client.close();
  }
}

Map<String, dynamic>? _platformAsset(Map<String, dynamic> assets) {
  final key = switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.windows => 'windows',
    _ => null,
  };
  if (key == null) return null;
  final a = assets[key];
  return a is Map ? a.cast<String, dynamic>() : null;
}

Future<void> _install(String path) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      // Hands the APK to the system installer (needs REQUEST_INSTALL_PACKAGES +
      // the user's "install unknown apps" grant for Hearth).
      await OpenFilex.open(path);
    case TargetPlatform.windows:
      await _installWindows(path);
    default:
      throw UnsupportedError('Auto-install not supported on this platform.');
  }
}

/// Windows can't overwrite a running .exe, so we hand off to a detached script
/// that waits for us to exit, extracts the new build over the install dir, and
/// relaunches. We then quit.
Future<void> _installWindows(String zipPath) async {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final extractDir = '${Directory.systemTemp.path}\\hearth_update';
  final batPath = '${Directory.systemTemp.path}\\hearth_update.bat';
  final script = StringBuffer()
    ..writeln('@echo off')
    ..writeln('timeout /t 2 /nobreak >nul')
    ..writeln('rmdir /S /Q "$extractDir" 2>nul')
    ..writeln(
      'powershell -NoProfile -Command "Expand-Archive -LiteralPath '
      "'$zipPath' -DestinationPath '$extractDir' -Force\"",
    )
    ..writeln('xcopy /E /Y /I "$extractDir\\*" "$exeDir" >nul')
    ..writeln('rmdir /S /Q "$extractDir" 2>nul')
    ..writeln('start "" "$exeDir\\hearth.exe"')
    ..writeln('del "%~f0"');
  await File(batPath).writeAsString(script.toString());
  await Process.start(
    'cmd',
    ['/c', batPath],
    mode: ProcessStartMode.detached,
    runInShell: true,
  );
  exit(0);
}
