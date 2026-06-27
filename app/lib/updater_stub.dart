import 'update_checker.dart';

/// Web stub — there's no in-app install on the web (it updates by reload), and
/// `dart:io` isn't available, so this just refuses. The UI only offers Install on
/// Android/Windows, so this is never reached in practice.
Future<void> downloadAndInstall(
  UpdateInfo info,
  Uri relayUrl, {
  void Function(double progress)? onProgress,
}) async {
  throw UnsupportedError('Auto-update is not available on this platform.');
}
