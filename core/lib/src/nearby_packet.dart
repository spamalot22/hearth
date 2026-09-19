// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'identity.dart';

/// An opaque courier envelope, separate from channel sync and its storage ACKs.
/// The body must be an encrypted *whole* signed Message, not plaintext text.
/// A carrier signature establishes integrity, not channel membership or final
/// delivery. Recipients must decrypt and verify the enclosed Message separately.
class NearbyPacket {
  NearbyPacket._(
    this.route,
    this.createdMs,
    this.expiresMs,
    Uint8List body,
    Uint8List sender,
    Uint8List signature,
    this.id,
  ) : body = Uint8List.fromList(body).asUnmodifiableView(),
      sender = Uint8List.fromList(sender).asUnmodifiableView(),
      signature = Uint8List.fromList(signature).asUnmodifiableView();

  static const maxBodyBytes = 20 * 1024;
  static const maxWireBytes = 32 * 1024;
  static const maxLifetime = Duration(hours: 24);
  static const clockSkew = Duration(minutes: 5);
  static final _hex32 = RegExp(r'^[0-9a-f]{64}$');

  /// Opaque rendezvous identifier. Never a handle, contact list, or channel key.
  /// It still permits traffic correlation; this is not an anonymity protocol.
  final String route;
  final int createdMs;
  final int expiresMs;
  final Uint8List body;
  final Uint8List sender;
  final Uint8List signature;
  final String id;

  static Uint8List _signingBytes(
    String route,
    int created,
    int expires,
    List<int> body,
    List<int> sender,
  ) => Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        'hearth/nearby-text/v1',
        route,
        created,
        expires,
        base64Url.encode(body),
        base64Url.encode(sender),
      ]),
    ),
  );

  static Future<NearbyPacket> create({
    required Identity sender,
    required String route,
    required Uint8List encryptedBody,
    required DateTime now,
    Duration lifetime = maxLifetime,
  }) async {
    final created = now.millisecondsSinceEpoch;
    final expires = created + lifetime.inMilliseconds;
    if (!_shapeValid(route, created, expires, encryptedBody.length) ||
        sender.publicKey.length != 32) {
      throw ArgumentError('invalid nearby envelope');
    }
    // Copy before awaiting: caller mutation must not change signed content.
    final body = Uint8List.fromList(encryptedBody);
    final key = Uint8List.fromList(sender.publicKey);
    final bytes = _signingBytes(route, created, expires, body, key);
    final sig = await sender.sign(bytes);
    return NearbyPacket._(
      route,
      created,
      expires,
      body,
      key,
      sig,
      hex.encode(await sha256Digest(bytes)),
    );
  }

  bool expired(DateTime now) => expiresMs <= now.millisecondsSinceEpoch;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'route': route,
        'created': createdMs,
        'expires': expiresMs,
        'body': base64Url.encode(body),
        'sender': base64Url.encode(sender),
        'sig': base64Url.encode(signature),
        'id': id,
      }),
    ),
  );

  /// Bounds bytes before JSON/base64 work. Authenticates expiry and content
  /// before a packet is eligible for storage, inventory, or forwarding.
  static Future<NearbyPacket?> decode(
    List<int> wire, {
    required DateTime now,
  }) async {
    if (wire.length > maxWireBytes) return null;
    try {
      final json = jsonDecode(utf8.decode(wire));
      if (json is! Map<String, dynamic> ||
          json['v'] is! int ||
          json['v'] != 1) {
        return null;
      }
      final route = json['route'];
      final created = json['created'];
      final expires = json['expires'];
      final rawBody = json['body'];
      final rawSender = json['sender'];
      final rawSig = json['sig'];
      final id = json['id'];
      if (route is! String ||
          created is! int ||
          expires is! int ||
          rawBody is! String ||
          rawSender is! String ||
          rawSig is! String ||
          id is! String ||
          !_hex32.hasMatch(id) ||
          rawSender.length != 44 ||
          rawSig.length != 88 ||
          rawBody.length > ((maxBodyBytes + 2) ~/ 3) * 4) {
        return null;
      }
      final body = base64Url.decode(rawBody);
      if (!_shapeValid(route, created, expires, body.length) ||
          expires <= now.millisecondsSinceEpoch ||
          created > now.millisecondsSinceEpoch + clockSkew.inMilliseconds) {
        return null;
      }
      final sender = base64Url.decode(rawSender);
      final sig = base64Url.decode(rawSig);
      if (sender.length != 32 || sig.length != 64) return null;
      final bytes = _signingBytes(route, created, expires, body, sender);
      if (hex.encode(await sha256Digest(bytes)) != id ||
          !await Identity.verifySignature(
            bytes,
            signature: sig,
            publicKey: sender,
          )) {
        return null;
      }
      return NearbyPacket._(route, created, expires, body, sender, sig, id);
    } catch (_) {
      return null;
    }
  }

  static bool _shapeValid(String route, int created, int expires, int size) =>
      _hex32.hasMatch(route) &&
      created >= 0 &&
      expires > created &&
      expires - created <= maxLifetime.inMilliseconds &&
      size >= 28 &&
      size <= maxBodyBytes;
}
