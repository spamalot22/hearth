// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'codec.dart';
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

  /// 64-byte Ed25519 signature over [signedBytes].
  final Uint8List signature;

  /// `multihash(sha256(signedBytes))` — 34 bytes.
  final Uint8List id;

  Message._({
    required this.version,
    required this.author,
    required this.channel,
    required this.prev,
    required this.timestampMs,
    required this.payload,
    required this.signature,
    required this.id,
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

  /// Builds, signs, and content-addresses a new message authored by [author].
  static Future<Message> create({
    required Identity author,
    required String channel,
    required Uint8List payload,
    List<Uint8List> prev = const [],
    int? timestampMs,
  }) async {
    final ts = timestampMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
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
    final signature = await author.sign(content);
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
    );
  }

  /// True iff [id] matches the content hash **and** [signature] is a valid
  /// Ed25519 signature by [author] over [signedBytes].
  Future<bool> verify() async {
    final content = signedBytes();
    final expectedId = await _idFor(content);
    if (!_constTimeEquals(expectedId, id)) return false;
    return Identity.verifySignature(
      content,
      signature: signature,
      publicKey: author,
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
