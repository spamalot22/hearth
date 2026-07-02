// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'update_checker.dart';

/// Bridge to Android's system DownloadManager (see MainActivity.kt).
const MethodChannel _downloader = MethodChannel('hearth/downloader');

// android.app.DownloadManager status codes.
const int _dlSuccessful = 8;
const int _dlFailed = 16;

/// Deletes any leftover update APKs/ZIPs from previous downloads.
Future<void> cleanupOldUpdates() async {
  try {
    final dir = await getTemporaryDirectory();
    for (final f in dir.listSync()) {
      if (f is File &&
          (f.path.endsWith('.apk') || f.path.endsWith('.zip')) &&
          f.path.contains('hearth')) {
        f.deleteSync();
      }
    }
  } catch (_) {}
}

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
  final url =
      'https://github.com/spamalot22/hearth/releases/download/'
      '${info.version}/$fileName';

  // Android: hand off to the system DownloadManager so the download survives the
  // app being backgrounded, screen-locked, or closed (and resumes across
  // connectivity drops). Everything else streams in-process (Windows).
  if (defaultTargetPlatform == TargetPlatform.android) {
    final id = await _downloader.invokeMethod<int>('enqueue', {
      'url': url,
      'fileName': fileName,
    });
    if (id == null) throw StateError('failed to start download');
    await _savePending(id, info);
    await _awaitAndroidDownload(id, expectedHash, onProgress);
    return;
  }

  final uri = Uri.parse(url);
  final dir = await getTemporaryDirectory();
  final outFile = File('${dir.path}${Platform.pathSeparator}$fileName');
  final client = http.Client();
  try {
    final resp = await client.send(http.Request('GET', uri));
    if (resp.statusCode != 200) {
      throw http.ClientException(
        'download failed: HTTP ${resp.statusCode}',
        uri,
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

/// Polls the DownloadManager until the download finishes, then verifies its
/// SHA-256 against the signed manifest and hands it to the installer. Runs while
/// the app is foregrounded; if the app is closed first, [resumePendingUpdate]
/// finishes it on next launch.
Future<void> _awaitAndroidDownload(
  int id,
  String expectedHash,
  void Function(double progress)? onProgress,
) async {
  while (true) {
    final s = await _downloader.invokeMapMethod<String, dynamic>('status', {
      'id': id,
    });
    if (s == null) {
      await _clearPending();
      throw StateError('download was cancelled');
    }
    final status = (s['status'] as num?)?.toInt() ?? 0;
    final total = (s['total'] as num?)?.toDouble() ?? 0;
    final done = (s['downloaded'] as num?)?.toDouble() ?? 0;
    if (total > 0) onProgress?.call((done / total).clamp(0.0, 1.0));
    if (status == _dlSuccessful) {
      final path = s['path'] as String?;
      await _clearPending(); // terminal — clear before verify so we don't loop
      if (path == null) throw StateError('downloaded file not found');
      await _verifyAndInstallApk(path, expectedHash);
      return;
    }
    if (status == _dlFailed) {
      await _clearPending();
      throw StateError('download failed (reason ${s['reason']})');
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
}

/// Stream-hashes the downloaded APK, rejects it on mismatch, else installs it.
Future<void> _verifyAndInstallApk(String path, String expectedHash) async {
  final file = File(path);
  final digestSink = AccumulatorSink<Digest>();
  final input = sha256.startChunkedConversion(digestSink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  if (digestSink.events.single.toString() != expectedHash) {
    try {
      await file.delete();
    } catch (_) {}
    throw StateError('update hash mismatch — download rejected');
  }
  await OpenFilex.open(path);
}

/// If an update download was in flight when the app closed, decide what to do on
/// the next launch: a completed one is verified + installed and a failed one is
/// cleared (both here, silently); a still-running one returns its [UpdateInfo]
/// so the caller can show the update gate + progress bar and then drive it to
/// completion with [attachPendingDownload]. Returns null when there's nothing to
/// resume. Safe on any platform (no-op unless there's a pending Android one).
Future<UpdateInfo?> resumePendingUpdate() async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final pending = await _loadPending();
    if (pending == null) return null;
    final (id, info) = pending;
    final hash = (_platformAsset(info.assets)?['sha256'] as String?)
        ?.toLowerCase();
    if (hash == null) {
      await _clearPending();
      return null;
    }
    final s = await _downloader.invokeMapMethod<String, dynamic>('status', {
      'id': id,
    });
    if (s == null) {
      await _clearPending();
      return null;
    }
    final status = (s['status'] as num?)?.toInt() ?? 0;
    if (status == _dlSuccessful) {
      final path = s['path'] as String?;
      await _clearPending();
      if (path != null) {
        try {
          await _verifyAndInstallApk(path, hash);
        } catch (_) {}
      }
      return null;
    } else if (status == _dlFailed) {
      await _clearPending();
      return null;
    }
    // Still downloading — the caller shows the gate and calls
    // attachPendingDownload to drive/finish it (with proper error handling).
    return info;
  } catch (_) {
    return null;
  }
}

/// Drives the persisted, still-running download to completion (verify + install),
/// reporting [onProgress]. Throws on failure so the caller can reset the UI and
/// surface an error. Call after [resumePendingUpdate] returns non-null.
Future<void> attachPendingDownload({
  void Function(double progress)? onProgress,
}) async {
  final pending = await _loadPending();
  if (pending == null) return;
  final (id, info) = pending;
  final hash = (_platformAsset(info.assets)?['sha256'] as String?)
      ?.toLowerCase();
  if (hash == null) {
    await _clearPending();
    return;
  }
  await _awaitAndroidDownload(id, hash, onProgress);
}

// --- pending-download persistence (survives an app close mid-download) ---

Future<Box<dynamic>> _pendingBox() async {
  await Hive.initFlutter();
  return Hive.openBox<dynamic>('hearth.update_dl');
}

Future<void> _savePending(int id, UpdateInfo info) async {
  final box = await _pendingBox();
  await box.putAll({
    'id': id,
    'version': info.version,
    'seq': info.seq,
    'assets': jsonEncode(info.assets),
  });
}

Future<(int, UpdateInfo)?> _loadPending() async {
  final box = await _pendingBox();
  final id = box.get('id');
  final version = box.get('version');
  final seq = box.get('seq');
  final assetsRaw = box.get('assets');
  if (id is int && version is String && seq is int && assetsRaw is String) {
    try {
      final assets = (jsonDecode(assetsRaw) as Map).cast<String, dynamic>();
      return (id, UpdateInfo(version: version, seq: seq, assets: assets));
    } catch (_) {
      return null;
    }
  }
  return null;
}

Future<void> _clearPending() async {
  final box = await _pendingBox();
  await box.clear();
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
      // Clean up after a short delay (the system installer reads the file async).
      Future.delayed(const Duration(minutes: 2), () {
        try {
          File(path).deleteSync();
        } catch (_) {}
      });
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
  // The script below rmdir's exeDir, so refuse to run if it's a drive root or a
  // suspiciously short path — a portable build launched from an odd location
  // must not self-destruct its parent. A normal install lives in a dedicated
  // subfolder (the running hearth.exe is inside exeDir).
  if (RegExp(r'^[A-Za-z]:\\?$').hasMatch(exeDir) || exeDir.length < 4) {
    throw StateError('refusing to self-update from unexpected dir: $exeDir');
  }
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
    // Abort if the extract failed (don't wipe a working install).
    ..writeln(
      'if not exist "$extractDir\\hearth.exe" (echo Extract failed & exit /b 1)',
    )
    // Wipe old install (handles removed DLLs), then copy new build in.
    ..writeln('rmdir /S /Q "$exeDir" 2>nul')
    ..writeln('mkdir "$exeDir"')
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
