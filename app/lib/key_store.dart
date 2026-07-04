// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [KeyStore] backed by the platform secure store via `flutter_secure_storage`
/// (Keychain on Apple, Keystore on Android, DPAPI/wincreds on Windows,
/// libsecret on Linux). The identity seed is the only secret Hearth persists.
///
/// Caveat: **web has no hardware-backed secure enclave** — there the seed lives in
/// origin-scoped browser storage, so it's weaker than on native and only as safe
/// as the browser/origin. Prefer a native build for a long-lived identity.
class SecureKeyStore implements KeyStore {
  /// Which secret this store holds — the root identity seed by default, or the
  /// device subkey seed (`'hearth.device.seed'`) for the per-device key.
  final String _seedKey;

  final FlutterSecureStorage _storage;

  SecureKeyStore({
    FlutterSecureStorage? storage,
    this._seedKey = 'hearth.identity.seed',
  }) : _storage = storage ?? const FlutterSecureStorage();

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
