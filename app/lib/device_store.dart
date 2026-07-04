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
///
/// Caches decoded lists in memory so hot-path lookups (per-message revocation
/// check) are O(1) set lookups, not repeated JSON decode cycles.
class DeviceStore {
  DeviceStore._(this._box) {
    _loadCerts();
    _loadRevocations();
  }

  final Box<String> _box;

  static const _certsKey = 'certs';
  static const _revocationsKey = 'revocations';

  // In-memory caches — rebuilt from Hive on construction, invalidated on write.
  List<DeviceCert> _certsCache = [];
  List<DeviceRevocation> _revocationsCache = [];
  Set<String> _revokedCache = {};

  static Future<DeviceStore> open() async {
    final box = await Hive.openBox<String>('hearth.devices');
    return DeviceStore._(box);
  }

  void _loadCerts() {
    final raw = _box.get(_certsKey);
    if (raw == null || raw.isEmpty) {
      _certsCache = [];
      return;
    }
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _certsCache =
          list.map((j) => DeviceCert.fromJson(j.cast<String, Object?>())).toList();
    } catch (_) {
      _certsCache = [];
    }
  }

  void _loadRevocations() {
    final raw = _box.get(_revocationsKey);
    if (raw == null || raw.isEmpty) {
      _revocationsCache = [];
      _revokedCache = {};
      return;
    }
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _revocationsCache = list
          .map((j) => DeviceRevocation.fromJson(j.cast<String, Object?>()))
          .toList();
      _revokedCache = _revocationsCache.map((r) => r.deviceKeyHex).toSet();
    } catch (_) {
      _revocationsCache = [];
      _revokedCache = {};
    }
  }

  /// All known device certs for this identity (including this device).
  List<DeviceCert> get certs => List.unmodifiable(_certsCache);

  /// Adds a cert if we haven't seen this device key before. Returns true if new.
  Future<bool> addCert(DeviceCert cert) async {
    if (_certsCache.any((c) => c.deviceKeyHex == cert.deviceKeyHex)) {
      return false;
    }
    _certsCache.add(cert);
    await _persistCerts();
    return true;
  }

  /// Replaces the cert for a given device key (e.g. rename).
  Future<void> updateCert(DeviceCert cert) async {
    _certsCache.removeWhere((c) => c.deviceKeyHex == cert.deviceKeyHex);
    _certsCache.add(cert);
    await _persistCerts();
  }

  Future<void> _persistCerts() =>
      _box.put(_certsKey, jsonEncode(_certsCache.map((c) => c.toJson()).toList()));

  /// All known revocations for this identity.
  List<DeviceRevocation> get revocations => List.unmodifiable(_revocationsCache);

  /// The set of revoked device key hex strings (O(1) lookup).
  Set<String> get revokedDeviceKeys => _revokedCache;

  /// Adds a revocation if not already known. Returns true if new.
  Future<bool> addRevocation(DeviceRevocation rev) async {
    if (_revokedCache.contains(rev.deviceKeyHex)) return false;
    _revocationsCache.add(rev);
    _revokedCache.add(rev.deviceKeyHex);
    await _box.put(
      _revocationsKey,
      jsonEncode(_revocationsCache.map((r) => r.toJson()).toList()),
    );
    return true;
  }

  /// Whether a specific device has been revoked.
  bool isRevoked(String deviceKeyHex) => _revokedCache.contains(deviceKeyHex);
}
