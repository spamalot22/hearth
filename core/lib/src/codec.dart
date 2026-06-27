// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

/// Minimal **canonical** CBOR writer for Hearth's signed message content.
///
/// We hand-roll this instead of leaning on a CBOR library's "canonical" mode so
/// the signed bytes are byte-for-byte identical across languages — the Dart
/// client signs, a TypeScript backend / peer verifies. The rules follow
/// RFC 8949 §4.2 deterministic encoding (a.k.a. dag-cbor):
///   * definite lengths only,
///   * shortest-form (minimal) integer encoding,
///   * map keys emitted in a fixed, length-then-bytewise sorted order.
///
/// Only the handful of major types Hearth needs are implemented: unsigned int,
/// byte string, text string, array, and map. The caller is responsible for
/// emitting map keys in canonical order (see `Message.signedBytes`).
class CanonicalCbor {
  final BytesBuilder _b = BytesBuilder(copy: false);

  /// Writes a major-type header with the shortest argument encoding for [n].
  void _head(int major, int n) {
    final mt = major << 5;
    if (n < 24) {
      _b.addByte(mt | n);
    } else if (n < 0x100) {
      _b.addByte(mt | 24);
      _b.addByte(n);
    } else if (n < 0x10000) {
      _b.addByte(mt | 25);
      _b.addByte((n >> 8) & 0xff);
      _b.addByte(n & 0xff);
    } else if (n < 0x100000000) {
      _b.addByte(mt | 26);
      _b.addByte((n >> 24) & 0xff);
      _b.addByte((n >> 16) & 0xff);
      _b.addByte((n >> 8) & 0xff);
      _b.addByte(n & 0xff);
    } else {
      _b.addByte(mt | 27);
      // BigInt path keeps the 64-bit case correct on the web (JS ints are 53-bit).
      final bi = BigInt.from(n);
      final mask = BigInt.from(0xff);
      for (var i = 7; i >= 0; i--) {
        _b.addByte(((bi >> (8 * i)) & mask).toInt());
      }
    }
  }

  void uint(int v) {
    assert(v >= 0, 'CanonicalCbor.uint is unsigned only');
    _head(0, v);
  }

  void bytes(List<int> v) {
    _head(2, v.length);
    _b.add(v);
  }

  void text(String s) {
    final u = utf8.encode(s);
    _head(3, u.length);
    _b.add(u);
  }

  void arrayHeader(int length) => _head(4, length);
  void mapHeader(int length) => _head(5, length);

  Uint8List takeBytes() => _b.toBytes();
}
