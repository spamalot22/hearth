// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/screen_share.dart';
import 'package:hearth/updater_io.dart';

void main() {
  test('Windows updater never deletes the install directory', () {
    final script = buildWindowsUpdateScript();
    expect(script, isNot(contains('rmdir')));
    expect(script, isNot(contains('Remove-Item -LiteralPath \$InstallDir')));
    expect(script, contains('Copy-Item -Destination \$InstallDir'));
  });

  test('screen mesh is named by the authenticated sharer device', () {
    expect(screenMeshChannel('group', 'device-key'), 'screen:group:device-key');
  });
}
