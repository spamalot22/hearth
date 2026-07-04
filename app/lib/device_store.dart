// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Persists the set of known devices for the local identity and any revocations.
/// Populated from:
///   - This device's own cert (on boot).
///   - Certs carried on received device-signed messages (remote devices of the
///     same root — i.e. your other devices).
///   - Revocations gossipped through the mesh.
class DeviceStore {
  DeviceStore._(this._box);

  final Box<String> _box;

  static const _certsKey = 'certs';
  static const _revocationsKey = 'revocations';

  static Future<DeviceStore> open() async {
    final box = await Hive.openBox<String>('hearth.devices');
    return DeviceStore._(box);
  }

  /// All known device certs for this identity (including this device).
  List<DeviceCert> get certs {
    final raw = _box.get(_certsKey);
    if (raw == null || raw.isEmpty) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((j) => DeviceCert.fromJson(j.cast<String, Object?>())).toList();
  }

  /// Adds a cert if we haven't seen this device key before. Returns true if new.
  Future<bool> addCert(DeviceCert cert) async {
    final existing = certs;
    if (existing.any((c) => c.deviceKeyHex == cert.deviceKeyHex)) return false;
    existing.add(cert);
    await _box.put(_certsKey, jsonEncode(existing.map((c) => c.toJson()).toList()));
    return true;
  }

  /// Replaces the cert for a given device key (e.g. rename).
  Future<void> updateCert(DeviceCert cert) async {
    final existing = certs;
    existing.removeWhere((c) => c.deviceKeyHex == cert.deviceKeyHex);
    existing.add(cert);
    await _box.put(_certsKey, jsonEncode(existing.map((c) => c.toJson()).toList()));
  }

  /// All known revocations for this identity.
  List<DeviceRevocation> get revocations {
    final raw = _box.get(_revocationsKey);
    if (raw == null || raw.isEmpty) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((j) => DeviceRevocation.fromJson(j.cast<String, Object?>())).toList();
  }

  /// The set of revoked device key hex strings (for quick lookup).
  Set<String> get revokedDeviceKeys =>
      revocations.map((r) => r.deviceKeyHex).toSet();

  /// Adds a revocation if not already known. Returns true if new.
  Future<bool> addRevocation(DeviceRevocation rev) async {
    final existing = revocations;
    if (existing.any((r) => r.deviceKeyHex == rev.deviceKeyHex)) return false;
    existing.add(rev);
    await _box.put(
      _revocationsKey,
      jsonEncode(existing.map((r) => r.toJson()).toList()),
    );
    return true;
  }

  /// Whether a specific device has been revoked.
  bool isRevoked(String deviceKeyHex) => revokedDeviceKeys.contains(deviceKeyHex);
}
