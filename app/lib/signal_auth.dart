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

import 'package:convert/convert.dart';
import 'package:core/core.dart';

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
