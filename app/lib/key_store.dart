// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
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
    String seedKey = 'hearth.identity.seed',
  }) : _seedKey = seedKey,
       _storage = storage ?? const FlutterSecureStorage();

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

/// A [KeyStore] that syncs across the user's devices via platform keychain:
/// - **Apple (iOS/macOS):** iCloud Keychain (`synchronizable: true`). The seed
///   syncs automatically to all devices signed into the same Apple ID.
/// - **Android:** encrypted SharedPreferences with Auto Backup enabled. The seed
///   syncs to the user's Google account and restores on new devices.
/// - **Windows/Linux/Web:** falls back to local-only (no cross-device sync).
///
/// This is separate from the device-only [SecureKeyStore] used for the device
/// subkey. The synced store holds the **root seed** so enrolling a new device
/// is automatic (no phrase entry needed) — the phrase remains as disaster recovery.
class SyncedKeyStore implements KeyStore {
  static const _key = 'hearth.root.synced';

  FlutterSecureStorage get _storage {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const FlutterSecureStorage(
        iOptions: IOSOptions(
          synchronizable: true,
          accessibility: KeychainAccessibility.first_unlock,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return const FlutterSecureStorage(
        mOptions: MacOsOptions(
          synchronizable: true,
          accessibility: KeychainAccessibility.first_unlock,
        ),
      );
    }
    // Android: default encrypted storage + Android Auto Backup.
    // Windows/Linux/Web: local-only (no sync — phrase is the fallback).
    return const FlutterSecureStorage();
  }

  @override
  Future<void> writeSeed(Uint8List seed) =>
      _storage.write(key: _key, value: base64Encode(seed));

  @override
  Future<Uint8List?> readSeed() async {
    try {
      final value = await _storage.read(key: _key);
      return value == null ? null : Uint8List.fromList(base64Decode(value));
    } catch (_) {
      // Platform doesn't support synced storage or keychain unavailable.
      return null;
    }
  }

  @override
  Future<void> deleteSeed() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}
