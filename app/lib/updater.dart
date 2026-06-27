// In-app updater: picks the real `dart:io` implementation everywhere except web,
// where the stub is used (web can't run a native installer and lacks `dart:io`).
export 'updater_stub.dart' if (dart.library.io) 'updater_io.dart';
