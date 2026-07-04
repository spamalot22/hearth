// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'codec.dart';
import 'device.dart';
import 'identity.dart';

/// Schema version of the signed content. Bump if the signed fields change.
const int kHearthMessageVersion = 1;

/// Multihash prefix for sha2-256 (code 0x12, length 0x20). Prefixing the digest
/// makes ids self-describing, so the hash algorithm can be migrated later
/// without breaking existing ids (hash agility).
const List<int> _sha256MultihashPrefix = [0x12, 0x20];

/// A signed, content-addressed node in the message DAG.
///
/// [prev] points at the message ids this one "saw", giving causal order without
/// a central clock. [id] is `multihash(sha256(signedBytes))` and [signature] is
/// the author's Ed25519 signature over those same [signedBytes]. Tampering with
/// any signed field invalidates both.
class Message {
  final int version;

  /// 32-byte Ed25519 public key of the author (== their identity).
  final Uint8List author;
  final String channel;

  /// Ids of the messages this one causally follows (its DAG parents/heads).
  final List<Uint8List> prev;

  /// Unix epoch milliseconds. Advisory only — used solely to break ordering
  /// ties between causally-concurrent messages.
  final int timestampMs;

  /// Opaque content. UTF-8 text for now; encrypted bytes later.
  final Uint8List payload;

  /// 64-byte Ed25519 signature over [signedBytes] — by [device] when set, else
  /// by [author] directly.
  final Uint8List signature;

  /// `multihash(sha256(signedBytes))` — 34 bytes.
  final Uint8List id;

  /// The **device subkey** that signed this message, or null when [author]
  /// (the root identity) signed directly. Multi-device: a message is *authored*
  /// by the root but *signed* by one of its devices.
  final Uint8List? device;

  /// The [DeviceCert] proving [device] is authorised by [author]. Non-null iff
  /// [device] is non-null.
  final DeviceCert? cert;

  Message._({
    required this.version,
    required this.author,
    required this.channel,
    required this.prev,
    required this.timestampMs,
    required this.payload,
    required this.signature,
    required this.id,
    this.device,
    this.cert,
  });

  /// The canonical bytes that are signed and hashed — **excludes** [signature]
  /// and [id], which are derived from them.
  ///
  /// Encoded as deterministic (dag-cbor-style) CBOR with map keys in canonical
  /// length-then-bytewise order: `v, prev, author, channel, payload, timestamp`.
  /// This is the cross-language contract: the TypeScript backend must produce
  /// the exact same bytes to verify a signature.
  Uint8List signedBytes() {
    final w = CanonicalCbor()
      ..mapHeader(6)
      ..text('v')
      ..uint(version)
      ..text('prev')
      ..arrayHeader(prev.length);
    for (final p in prev) {
      w.bytes(p);
    }
    w
      ..text('author')
      ..bytes(author)
      ..text('channel')
      ..text(channel)
      ..text('payload')
      ..bytes(payload)
      ..text('timestamp')
      ..uint(timestampMs);
    return w.takeBytes();
  }

  /// Builds, signs, and content-addresses a new message authored by [author]
  /// (the root identity — its pubkey is the author id).
  ///
  /// By default [author] signs directly. For multi-device, pass [signingDevice]
  /// (a device subkey) and its [deviceCert]: the message is still *authored* by
  /// [author] but *signed* by the device, and carries the cert so peers can
  /// verify the root→device→message chain. `device`/`cert` are envelope fields,
  /// not part of [signedBytes], so the content id is identical either way.
  static Future<Message> create({
    required Identity author,
    required String channel,
    required Uint8List payload,
    List<Uint8List> prev = const [],
    int? timestampMs,
    Identity? signingDevice,
    DeviceCert? deviceCert,
  }) async {
    assert(
      signingDevice == null || deviceCert != null,
      'device-signed messages must carry the device cert',
    );
    final ts = timestampMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final signer = signingDevice ?? author;
    final device = signingDevice?.publicKey;
    final fields = Message._(
      version: kHearthMessageVersion,
      author: author.publicKey,
      channel: channel,
      prev: List<Uint8List>.unmodifiable(prev),
      timestampMs: ts,
      payload: payload,
      signature: Uint8List(0), // filled below
      id: Uint8List(0),
    );
    final content = fields.signedBytes();
    final signature = await signer.sign(content);
    final id = await _idFor(content);
    return Message._(
      version: kHearthMessageVersion,
      author: author.publicKey,
      channel: channel,
      prev: List<Uint8List>.unmodifiable(prev),
      timestampMs: ts,
      payload: payload,
      signature: signature,
      id: id,
      device: device,
      cert: deviceCert,
    );
  }

  /// True iff [id] matches the content hash and the signature chain is valid:
  /// either [author] signed directly (classic), or a [device] signed it and a
  /// valid [cert] proves that device is authorised by [author].
  ///
  /// Does **not** check device revocation — that's per-user state the sync/app
  /// layer enforces (drop messages from a device you've revoked).
  Future<bool> verify() async {
    final content = signedBytes();
    final expectedId = await _idFor(content);
    if (!_constTimeEquals(expectedId, id)) return false;
    final dev = device;
    if (dev == null) {
      // Classic: the root identity signed directly.
      return Identity.verifySignature(
        content,
        signature: signature,
        publicKey: author,
      );
    }
    // Device-signed: the cert must bind this device to this author, and the
    // device must have signed the content.
    final c = cert;
    if (c == null) return false;
    if (!_constTimeEquals(c.rootKey, author)) return false;
    if (!_constTimeEquals(c.deviceKey, dev)) return false;
    if (!await c.verify()) return false;
    return Identity.verifySignature(
      content,
      signature: signature,
      publicKey: dev,
    );
  }

  static Future<Uint8List> _idFor(List<int> content) async {
    final digest = await sha256Digest(content);
    return Uint8List.fromList([..._sha256MultihashPrefix, ...digest]);
  }

  /// The id as a hex string, for logging / display.
  String get idHex => hex.encode(id);

  // --- wire envelope (Phase 1: JSON; this is *not* the signed form) ---
  //
  // The receiver reconstructs `signedBytes()` from these fields and re-verifies,
  // so the envelope format itself isn't security-critical. base64url keeps the
  // binary fields JSON-safe.

  Map<String, Object?> toJson() => {
    'v': version,
    'author': base64Url.encode(author),
    'channel': channel,
    'prev': prev.map(base64Url.encode).toList(),
    'timestamp': timestampMs,
    'payload': base64Url.encode(payload),
    'sig': base64Url.encode(signature),
    'id': base64Url.encode(id),
    if (device != null) 'device': base64Url.encode(device!),
    if (cert != null) 'cert': cert!.toJson(),
  };

  static Message fromJson(Map<String, Object?> j) => Message._(
    version: j['v']! as int,
    author: base64Url.decode(j['author']! as String),
    channel: j['channel']! as String,
    prev: (j['prev']! as List<dynamic>)
        .cast<String>()
        .map(base64Url.decode)
        .toList(growable: false),
    timestampMs: j['timestamp']! as int,
    payload: base64Url.decode(j['payload']! as String),
    signature: base64Url.decode(j['sig']! as String),
    id: base64Url.decode(j['id']! as String),
    device: j['device'] == null
        ? null
        : base64Url.decode(j['device']! as String),
    cert: j['cert'] == null
        ? null
        : DeviceCert.fromJson((j['cert']! as Map).cast<String, Object?>()),
  );
}

/// Length-then-content comparison that doesn't short-circuit on content, so id
/// comparison doesn't leak via timing.
bool _constTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
