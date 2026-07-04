// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'codec.dart';
import 'identity.dart';

/// A **device certificate**: your root identity's signed statement that a device
/// subkey belongs to you.
///
/// Your identity is still the root Ed25519 key ([rootKey]) — that's your id
/// everywhere (message authorship, contacts, membership, DM keys). Each device
/// (phone, laptop) holds its *own* subkey ([deviceKey]) and this cert, signed by
/// the root, saying "this device is me". Peers verify a device-signed message by
/// checking: the cert is validly signed by the claimed root, the message is
/// signed by [deviceKey], and the device isn't revoked ([DeviceRevocation]).
///
/// The root signature is over canonical CBOR of the fields (not JSON), so the
/// signed bytes are byte-for-byte stable across languages/versions — the same
/// discipline as [Message.signedBytes].
class DeviceCert {
  DeviceCert({
    required this.rootKey,
    required this.deviceKey,
    required this.name,
    required this.issuedMs,
    required this.signature,
  });

  /// The root identity pubkey that issued this cert (== the user's id).
  final Uint8List rootKey;

  /// The device subkey pubkey this cert authorises.
  final Uint8List deviceKey;

  /// A friendly, self-chosen device name ("Sam's phone"). Advisory display only.
  final String name;

  /// When the root issued this cert (unix epoch ms).
  final int issuedMs;

  /// The root's Ed25519 signature over [_signedBytes].
  final Uint8List signature;

  static Uint8List _signedBytes(
    Uint8List rootKey,
    Uint8List deviceKey,
    String name,
    int issuedMs,
  ) =>
      (CanonicalCbor()
            ..mapHeader(5)
            ..text('t')
            ..text('hearth/device-cert/v1')
            ..text('root')
            ..bytes(rootKey)
            ..text('device')
            ..bytes(deviceKey)
            ..text('name')
            ..text(name)
            ..text('issued')
            ..uint(issuedMs))
          .takeBytes();

  /// Issues a cert for [deviceKey] under the [root] identity.
  static Future<DeviceCert> issue({
    required Identity root,
    required Uint8List deviceKey,
    required String name,
    int? issuedMs,
  }) async {
    final ts = issuedMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final sig = await root.sign(
      _signedBytes(root.publicKey, deviceKey, name, ts),
    );
    return DeviceCert(
      rootKey: root.publicKey,
      deviceKey: deviceKey,
      name: name,
      issuedMs: ts,
      signature: sig,
    );
  }

  /// True iff [signature] is a valid signature by [rootKey] over this cert's
  /// fields — i.e. the root really did authorise this device.
  Future<bool> verify() => Identity.verifySignature(
    _signedBytes(rootKey, deviceKey, name, issuedMs),
    signature: signature,
    publicKey: rootKey,
  );

  String get deviceKeyHex => hex.encode(deviceKey);
  String get rootKeyHex => hex.encode(rootKey);

  Map<String, Object?> toJson() => {
    'root': base64Url.encode(rootKey),
    'device': base64Url.encode(deviceKey),
    'name': name,
    'issued': issuedMs,
    'sig': base64Url.encode(signature),
  };

  static DeviceCert fromJson(Map<String, Object?> j) => DeviceCert(
    rootKey: base64Url.decode(j['root']! as String),
    deviceKey: base64Url.decode(j['device']! as String),
    name: j['name']! as String,
    issuedMs: j['issued']! as int,
    signature: base64Url.decode(j['sig']! as String),
  );
}

/// A root-signed revocation of a device subkey. Once a valid revocation for a
/// device is seen, honest peers reject that device's messages and connections.
/// The root signs it, so only you can revoke your own devices; it propagates
/// epidemically like any signed statement.
class DeviceRevocation {
  DeviceRevocation({
    required this.rootKey,
    required this.deviceKey,
    required this.revokedMs,
    required this.signature,
  });

  final Uint8List rootKey;
  final Uint8List deviceKey;
  final int revokedMs;
  final Uint8List signature;

  static Uint8List _signedBytes(
    Uint8List rootKey,
    Uint8List deviceKey,
    int revokedMs,
  ) =>
      (CanonicalCbor()
            ..mapHeader(4)
            ..text('t')
            ..text('hearth/device-revoke/v1')
            ..text('root')
            ..bytes(rootKey)
            ..text('device')
            ..bytes(deviceKey)
            ..text('revoked')
            ..uint(revokedMs))
          .takeBytes();

  static Future<DeviceRevocation> issue({
    required Identity root,
    required Uint8List deviceKey,
    int? revokedMs,
  }) async {
    final ts = revokedMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final sig = await root.sign(_signedBytes(root.publicKey, deviceKey, ts));
    return DeviceRevocation(
      rootKey: root.publicKey,
      deviceKey: deviceKey,
      revokedMs: ts,
      signature: sig,
    );
  }

  Future<bool> verify() => Identity.verifySignature(
    _signedBytes(rootKey, deviceKey, revokedMs),
    signature: signature,
    publicKey: rootKey,
  );

  String get deviceKeyHex => hex.encode(deviceKey);

  Map<String, Object?> toJson() => {
    'root': base64Url.encode(rootKey),
    'device': base64Url.encode(deviceKey),
    'revoked': revokedMs,
    'sig': base64Url.encode(signature),
  };

  static DeviceRevocation fromJson(Map<String, Object?> j) => DeviceRevocation(
    rootKey: base64Url.decode(j['root']! as String),
    deviceKey: base64Url.decode(j['device']! as String),
    revokedMs: j['revoked']! as int,
    signature: base64Url.decode(j['sig']! as String),
  );
}
