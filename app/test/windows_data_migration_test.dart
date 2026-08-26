// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/windows_data_migration.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows application-data identity remains backward compatible', () {
    final resource = File('windows/runner/Runner.rc').readAsStringSync();

    expect(resource, contains('VALUE "CompanyName", "com.example"'));
    expect(resource, contains('VALUE "ProductName", "Hearth"'));
  });

  test(
    'migration merges records but preserves the established identity',
    () async {
      final temp = await Directory.systemTemp.createTemp('hearth-win-data-');
      addTearDown(() async {
        await Hive.close();
        await temp.delete(recursive: true);
      });

      final canonical = Directory('${temp.path}/com.example/Hearth');
      final accidental = Directory(accidentalWindowsDataPath(temp.path));
      await canonical.create(recursive: true);
      await accidental.create(recursive: true);

      await _writeBox(canonical.path, 'hearth.contacts', {
        'existing': 'Original contact',
      });
      await _writeBox(accidental.path, 'hearth.contacts', {
        'existing': 'Replacement contact',
        'recovered': 'Recovered contact',
      });
      await _writeBox(canonical.path, 'hearth.devices', {'certs': 'original'});
      await _writeBox(accidental.path, 'hearth.devices', {
        'certs': 'replacement',
      });
      await File(
        '${canonical.path}/flutter_secure_storage.dat',
      ).writeAsString('original identity');
      await File(
        '${accidental.path}/flutter_secure_storage.dat',
      ).writeAsString('replacement identity');

      expect(
        await migrateAccidentalWindowsDataDirectory(
          canonicalPath: canonical.path,
          roamingAppData: temp.path,
          allowNonWindowsForTest: true,
        ),
        isTrue,
      );

      expect(await _readBox(canonical.path, 'hearth.contacts'), {
        'existing': 'Original contact',
        'recovered': 'Recovered contact',
      });
      expect(await _readBox(canonical.path, 'hearth.devices'), {
        'certs': 'original',
      });
      expect(
        await File(
          '${canonical.path}/flutter_secure_storage.dat',
        ).readAsString(),
        'original identity',
      );

      // The marker makes retries harmless and the source remains a rollback copy.
      expect(
        await migrateAccidentalWindowsDataDirectory(
          canonicalPath: canonical.path,
          roamingAppData: temp.path,
          allowNonWindowsForTest: true,
        ),
        isFalse,
      );
      expect(await accidental.exists(), isTrue);
    },
  );

  test('migration copies a first install created on 0.7.26', () async {
    final temp = await Directory.systemTemp.createTemp('hearth-win-first-');
    addTearDown(() async {
      await Hive.close();
      await temp.delete(recursive: true);
    });

    final canonical = Directory('${temp.path}/com.example/Hearth');
    final accidental = Directory(accidentalWindowsDataPath(temp.path));
    await accidental.create(recursive: true);
    await _writeBox(accidental.path, 'hearth.contacts', {'new': 'New user'});
    await File(
      '${accidental.path}/flutter_secure_storage.dat',
    ).writeAsString('new identity');

    await migrateAccidentalWindowsDataDirectory(
      canonicalPath: canonical.path,
      roamingAppData: temp.path,
      allowNonWindowsForTest: true,
    );

    expect(await _readBox(canonical.path, 'hearth.contacts'), {
      'new': 'New user',
    });
    expect(
      await File('${canonical.path}/flutter_secure_storage.dat').readAsString(),
      'new identity',
    );
  });
}

Future<void> _writeBox(
  String path,
  String name,
  Map<String, String> values,
) async {
  final box = await Hive.openBox<String>(name, path: path);
  await box.putAll(values);
  await box.close();
}

Future<Map<dynamic, dynamic>> _readBox(String path, String name) async {
  final box = await Hive.openBox<dynamic>(name, path: path);
  try {
    return Map<dynamic, dynamic>.from(box.toMap());
  } finally {
    await box.close();
  }
}
