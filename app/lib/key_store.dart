// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  }) : _seedKey = seedKey, // ignore: prefer_initializing_formals
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
///   Note: Apple requires `first_unlock` accessibility for synchronizable items
///   (`unlocked` cannot sync). This is the most restrictive level that works.
/// - **Android (API 34+):** Credential Manager API. The seed is stored as a
///   custom credential in Google Password Manager, which syncs E2E-encrypted
///   across all the user's Android devices (and Chrome on desktop).
/// - **Android (<34) / Windows/Linux/Web:** falls back to null (no sync).
///   The user enters their 24-word phrase on new devices.
///
/// This is separate from the device-only [SecureKeyStore] used for the device
/// subkey. The synced store holds the **root seed** so enrolling a new device
/// is automatic (no phrase entry needed) — the phrase remains as disaster recovery.
class SyncedKeyStore implements KeyStore {
  static const _key = 'hearth.root.synced';
  static const _channel = MethodChannel('hearth/credentials');

  // Apple iCloud Keychain storage (iOS/macOS only).
  static final FlutterSecureStorage? _appleStorage = () {
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
    return null;
  }();

  static bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  static bool get _isApple =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<void> writeSeed(Uint8List seed) async {
    if (_isApple && _appleStorage != null) {
      await _appleStorage!.write(key: _key, value: base64Encode(seed));
    } else if (_isAndroid) {
      try {
        await _channel.invokeMethod('write', {'seed': base64Encode(seed)});
      } on PlatformException {
        // API <34 or user declined — not critical, phrase is the fallback.
      }
    }
  }

  @override
  Future<Uint8List?> readSeed() async {
    if (_isApple && _appleStorage != null) {
      return _readApple();
    } else if (_isAndroid) {
      return _readAndroid();
    }
    return null;
  }

  Future<Uint8List?> _readApple() async {
    try {
      final value = await _appleStorage!.read(key: _key);
      if (value == null) return null;
      return Uint8List.fromList(base64Decode(value));
    } on FormatException {
      try {
        await _appleStorage!.delete(key: _key);
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readAndroid() async {
    try {
      final result = await _channel.invokeMethod<String?>('read');
      if (result == null) return null;
      return Uint8List.fromList(base64Decode(result));
    } on PlatformException {
      // API <34 or credential manager unavailable.
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> deleteSeed() async {
    if (_isApple && _appleStorage != null) {
      try {
        await _appleStorage!.delete(key: _key);
      } catch (_) {}
    } else if (_isAndroid) {
      try {
        await _channel.invokeMethod('delete');
      } on PlatformException {
        // Best effort.
      }
    }
  }
}
