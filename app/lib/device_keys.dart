// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';

/// This install's **device keys**: a per-device Ed25519 subkey ([device]) and
/// the [cert] proving your root identity authorised it.
///
/// Your identity is still the root key. Each device holds its own subkey, and
/// messages are *authored* by the root but *signed* by this device (carrying the
/// cert). Two devices of one identity therefore have distinct keys — the basis
/// for concurrent multi-device and per-device revocation.
class DeviceKeys {
  DeviceKeys(this.device, this.cert);

  final Identity device;
  final DeviceCert cert;

  Uint8List get publicKey => device.publicKey;
  String get publicKeyHex => device.publicKeyHex;

  /// Loads (or creates) this device's stable subkey from [deviceStore] and
  /// (re-)issues its cert under [root]. The subkey persists; the cert is cheap
  /// to re-mint each launch (the root is on-device in phase A), so only the
  /// device key needs durable storage here. [name] is the initial friendly name.
  static Future<DeviceKeys> loadOrCreate(
    Identity root,
    KeyStore deviceStore, {
    String? name,
  }) async {
    final device = await Identity.loadOrCreate(deviceStore);
    final cert = await DeviceCert.issue(
      root: root,
      deviceKey: device.publicKey,
      name: name ?? defaultDeviceName(),
    );
    return DeviceKeys(device, cert);
  }

  /// A sensible default name for this platform, until the user renames it.
  static String defaultDeviceName() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android device',
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows PC',
    TargetPlatform.linux => 'Linux device',
    _ => 'This device',
  };
}
