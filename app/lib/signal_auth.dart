// SPDX-License-Identifier: AGPL-3.0-or-later
/// Authenticated WebRTC signalling — binding the handshake to the Ed25519
/// identity so a relay or man-in-the-middle can't impersonate a peer, swap the
/// DTLS fingerprint inside an SDP, or replay a signal to a different recipient.
///
/// We sign the security-critical payload — the SDP (which carries the DTLS
/// fingerprint) for offers/answers, or the candidate for ICE — bound to the
/// signal kind and the intended recipient. The receiver verifies against the
/// sender's public key (their mesh id): the DTLS channel can then only terminate
/// at the holder of that key. (It does *not* establish that the key is who you
/// want — that's the petname/TOFU layer; here we only stop interception between
/// two peers that do connect.)
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:crypto/crypto.dart';

const String signalCapabilityField = 'cap';

List<int> presenceSigningBytes(
  String channel,
  String pubkey,
  int timestampMs,
) => utf8.encode('announce|$channel|$pubkey|$timestampMs');

String createPresenceCapabilityProof(
  List<int> channelKey,
  String pubkey,
  String channel,
  int timestampMs,
) {
  if (channelKey.length != 32) {
    throw ArgumentError.value(channelKey.length, 'channelKey');
  }
  return Hmac(sha256, channelKey)
      .convert(
        utf8.encode(
          'hearth/presence-capability/v1\n$pubkey\n$channel\n$timestampMs',
        ),
      )
      .toString();
}

bool verifyPresenceCapabilityProof(
  List<int> channelKey,
  String pubkey,
  String channel,
  int timestampMs,
  Object? supplied,
) {
  if (supplied is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(supplied)) {
    return false;
  }
  try {
    final expected = createPresenceCapabilityProof(
      channelKey,
      pubkey,
      channel,
      timestampMs,
    );
    return _constantTimeBytes(
      Uint8List.fromList(hex.decode(supplied)),
      Uint8List.fromList(hex.decode(expected)),
    );
  } catch (_) {
    return false;
  }
}

Future<bool> verifyRelayPresenceClaim({
  required String channel,
  required String pubkey,
  required int timestampMs,
  required String signatureHex,
  List<int>? channelKey,
  Object? capability,
  DateTime? now,
  Duration maxAge = const Duration(seconds: 30),
}) async {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey) ||
      !RegExp(r'^[0-9a-f]{128}$').hasMatch(signatureHex) ||
      timestampMs < 0) {
    return false;
  }
  final currentMs = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
  if ((currentMs - timestampMs).abs() > maxAge.inMilliseconds) return false;
  if (channelKey != null &&
      !verifyPresenceCapabilityProof(
        channelKey,
        pubkey,
        channel,
        timestampMs,
        capability,
      )) {
    return false;
  }
  try {
    return await Identity.verifySignature(
      presenceSigningBytes(channel, pubkey, timestampMs),
      signature: hex.decode(signatureHex),
      publicKey: hex.decode(pubkey),
    );
  } catch (_) {
    return false;
  }
}

/// Deterministic bytes signed for a signal of [kind] addressed to [to]. Only the
/// security-critical fields are bound; strings survive the relay's JSON
/// round-trip unchanged, so signatures stay valid end-to-end.
List<int> signalSigningBytes(
  String channel,
  String kind,
  String to,
  Map<String, Object?> data,
) {
  final payload = switch (kind) {
    'offer' || 'answer' => (data['sdp'] as String?) ?? '',
    'ice' => '${data['candidate']}|${data['sdpMid']}|${data['sdpMLineIndex']}',
    _ => '',
  };
  // Bind the channel too, so a malicious relay can't replay a signed signal into
  // a different channel's mailbox (cross-channel connection confusion).
  return utf8.encode('$channel|$kind|$to|$payload');
}

/// Proves that a signalling peer possesses a channel's encryption capability.
///
/// Device signatures authenticate *who* sent a signal, but a relay observes the
/// channel namespace and can create its own valid device identity. Group meshes
/// therefore also require this HMAC before accepting SDP/ICE or remote media.
String createSignalCapabilityProof(
  List<int> channelKey,
  String from,
  String to,
  String channel,
  String kind,
  Map<String, Object?> data,
) {
  if (channelKey.length != 32) {
    throw ArgumentError.value(channelKey.length, 'channelKey');
  }
  final authenticated = <int>[
    ...utf8.encode('hearth/signal-capability/v1\n$from\n'),
    ...signalSigningBytes(channel, kind, to, data),
  ];
  return Hmac(sha256, channelKey).convert(authenticated).toString();
}

bool verifySignalCapabilityProof(
  List<int> channelKey,
  String from,
  String to,
  String channel,
  String kind,
  Map<String, Object?> data,
) {
  final supplied = data[signalCapabilityField];
  if (supplied is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(supplied)) {
    return false;
  }
  try {
    final expected = createSignalCapabilityProof(
      channelKey,
      from,
      to,
      channel,
      kind,
      data,
    );
    return _constantTimeBytes(
      Uint8List.fromList(hex.decode(supplied)),
      Uint8List.fromList(hex.decode(expected)),
    );
  } catch (_) {
    return false;
  }
}

bool _constantTimeBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// Signs [data] (a signal of [kind] addressed to [to]) with [identity]; returns
/// the base64url signature to embed in the signal under `sig`.
Future<String> signSignal(
  Identity identity,
  String channel,
  String kind,
  String to,
  Map<String, Object?> data,
) async => base64Url.encode(
  await identity.sign(signalSigningBytes(channel, kind, to, data)),
);

/// Verifies a received signal's embedded `sig` against sender [fromHex], with us
/// as recipient [selfHex]. Returns false on any malformation or bad signature.
Future<bool> verifySignal(
  String fromHex,
  String selfHex,
  String channel,
  String kind,
  Map<String, Object?> data,
) async {
  final sig = data['sig'];
  if (sig is! String) return false;
  try {
    return await Identity.verifySignature(
      signalSigningBytes(channel, kind, selfHex, data),
      signature: base64Url.decode(sig),
      publicKey: hex.decode(fromHex),
    );
  } catch (_) {
    return false;
  }
}
