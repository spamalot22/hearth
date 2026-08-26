// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

const _accidentalCompanyDirectory = 'Hearth contributors';
const _productDirectory = 'Hearth';
const _migrationMarker = '.hearth-windows-data-path-v1';
const _secureStorageFile = 'flutter_secure_storage.dat';
const _deviceBox = 'hearth.devices';

/// Repairs the Windows data-directory change shipped in 0.7.26.
///
/// Windows derives application support and secure-storage paths from executable
/// metadata. The temporary CompanyName change moved both stores to a new empty
/// directory. Existing canonical data wins on conflicts, while records created
/// after recovering in 0.7.26 are merged when their keys are new. The source is
/// deliberately retained as a rollback copy.
Future<bool> migrateAccidentalWindowsDataDirectory({
  required String canonicalPath,
  String? roamingAppData,
  bool allowNonWindowsForTest = false,
}) async {
  if (!Platform.isWindows && !allowNonWindowsForTest) return false;

  final roaming = roamingAppData ?? Platform.environment['APPDATA'];
  if (roaming == null || roaming.isEmpty) return false;

  final separator = Platform.pathSeparator;
  final source = Directory(
    [roaming, _accidentalCompanyDirectory, _productDirectory].join(separator),
  );
  final target = Directory(canonicalPath);
  if (!await source.exists() || _samePath(source.path, target.path)) {
    return false;
  }

  final marker = File('${target.path}$separator$_migrationMarker');
  if (await marker.exists()) return false;

  await target.create(recursive: true);
  final sourceFiles = await source
      .list(followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .toList();

  for (final sourceFile in sourceFiles) {
    final fileName = _fileName(sourceFile.path);
    if (fileName == _migrationMarker || fileName.endsWith('.lock')) continue;

    final targetFile = File('${target.path}$separator$fileName');
    if (!fileName.endsWith('.hive')) {
      if (!await targetFile.exists()) await sourceFile.copy(targetFile.path);
      continue;
    }

    final boxName = fileName.substring(0, fileName.length - '.hive'.length);
    if (!await targetFile.exists()) {
      await sourceFile.copy(targetFile.path);
    } else if (boxName != _deviceBox) {
      await _mergeMissingBoxEntries(boxName, source.path, target.path);
    }
  }

  // If an established installation exists, never replace its DPAPI identity.
  // A first install on 0.7.26 reaches the copy-above because the target is empty.
  final sourceSecure = File('${source.path}$separator$_secureStorageFile');
  final targetSecure = File('${target.path}$separator$_secureStorageFile');
  if (await sourceSecure.exists() && !await targetSecure.exists()) {
    await sourceSecure.copy(targetSecure.path);
  }

  await marker.writeAsString(
    'Merged data from ${source.path} without deleting the source.\n',
    flush: true,
  );
  return true;
}

Future<void> _mergeMissingBoxEntries(
  String boxName,
  String sourcePath,
  String targetPath,
) async {
  final sourceBox = await Hive.openBox<dynamic>(boxName, path: sourcePath);
  late final Map<dynamic, dynamic> sourceEntries;
  try {
    sourceEntries = Map<dynamic, dynamic>.from(sourceBox.toMap());
  } finally {
    await sourceBox.close();
  }

  final targetBox = await Hive.openBox<dynamic>(boxName, path: targetPath);
  try {
    for (final entry in sourceEntries.entries) {
      if (!targetBox.containsKey(entry.key)) {
        await targetBox.put(entry.key, entry.value);
      }
    }
    await targetBox.flush();
  } finally {
    await targetBox.close();
  }
}

String _fileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

bool _samePath(String a, String b) =>
    a.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase() ==
    b.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

@visibleForTesting
String accidentalWindowsDataPath(String roamingAppData) => [
  roamingAppData,
  _accidentalCompanyDirectory,
  _productDirectory,
].join(Platform.pathSeparator);
