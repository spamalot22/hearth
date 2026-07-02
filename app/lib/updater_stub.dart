// SPDX-License-Identifier: AGPL-3.0-or-later
import 'update_checker.dart';

/// No-op on web.
Future<void> cleanupOldUpdates() async {}

/// No-op on web (no background download to resume).
Future<UpdateInfo?> resumePendingUpdate({
  void Function(double progress)? onProgress,
}) async => null;

/// Web stub — there's no in-app install on the web (it updates by reload), and
/// `dart:io` isn't available, so this just refuses. The UI only offers Install on
/// Android/Windows, so this is never reached in practice.
Future<void> downloadAndInstall(
  UpdateInfo info, {
  void Function(double progress)? onProgress,
}) async {
  throw UnsupportedError('Auto-update is not available on this platform.');
}
