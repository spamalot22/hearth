// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'identity.dart';

/// Content-addressed id for [bytes] — `multihash(sha256)` as hex, the same
/// scheme message ids use. A blob's id *is* its hash, so a reference can't be
/// forged: a peer either returns bytes that hash to the requested id, or you
/// drop them.
Future<String> blobHash(List<int> bytes) async {
  final digest = await sha256Digest(bytes);
  return hex.encode([0x12, 0x20, ...digest]);
}

/// Maximum allowed blob size (10 MB). Enforced on upload and receive.
const int maxBlobBytes = 10 * 1024 * 1024;

/// A content-addressed store of opaque media blobs — stickers, sound clips,
/// images. Messages reference a blob by its [blobHash]; the bytes are fetched on
/// demand (so large media never gossips to everyone). Implementations: the
/// in-memory one here (for tests) and the app's on-device store.
abstract interface class BlobStore {
  /// Stores [bytes] and returns their content id.
  Future<String> put(Uint8List bytes);

  /// The bytes for [hashHex], or null if not held.
  Future<Uint8List?> get(String hashHex);

  /// Whether [hashHex] is held locally.
  Future<bool> has(String hashHex);
}

/// A volatile [BlobStore] for tests.
class InMemoryBlobStore implements BlobStore {
  final Map<String, Uint8List> _blobs = {};

  @override
  Future<String> put(Uint8List bytes) async {
    final id = await blobHash(bytes);
    _blobs[id] = Uint8List.fromList(bytes);
    return id;
  }

  @override
  Future<Uint8List?> get(String hashHex) async => _blobs[hashHex];

  @override
  Future<bool> has(String hashHex) async => _blobs.containsKey(hashHex);
}
