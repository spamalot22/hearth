import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [KeyStore] backed by the platform secure store via `flutter_secure_storage`
/// (Keychain on Apple, Keystore on Android, DPAPI/wincreds on Windows,
/// libsecret on Linux). The identity seed is the only secret Hearth persists.
class SecureKeyStore implements KeyStore {
  static const String _seedKey = 'hearth.identity.seed';

  final FlutterSecureStorage _storage;

  SecureKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> writeSeed(Uint8List seed) =>
      _storage.write(key: _seedKey, value: base64Encode(seed));

  @override
  Future<Uint8List?> readSeed() async {
    final value = await _storage.read(key: _seedKey);
    return value == null ? null : Uint8List.fromList(base64Decode(value));
  }

  @override
  Future<void> deleteSeed() => _storage.delete(key: _seedKey);
}
