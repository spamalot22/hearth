// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// On-device [BlobStore] backed by Hive — stickers and sound clips kept as raw
/// bytes keyed by their content hash. Being content-addressed, storing the same
/// bytes twice is an idempotent overwrite. One store shared across all channels:
/// a blob fetched in one channel is then available everywhere.
///
/// Tracks last-access time per blob and supports auto-pruning of blobs not
/// accessed within [pruneDays] (default 30). Call [prune] periodically.
class HiveBlobStore implements BlobStore {
  HiveBlobStore._(this._box, this._times);

  final Box<Uint8List> _box;
  final Box<int> _times; // hash -> last access epoch ms

  static const int pruneDays = 30;

  /// Maximum blob size (10 MB). Rejects uploads and incoming blobs above this.
  static const int maxBytes = maxBlobBytes;

  static Future<HiveBlobStore> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<Uint8List>('hearth.blobs');
    final times = await Hive.openBox<int>('hearth.blob_times');
    return HiveBlobStore._(box, times);
  }

  @override
  Future<String> put(Uint8List bytes) async {
    if (bytes.length > maxBytes) {
      throw ArgumentError('Blob too large (${bytes.length} > $maxBytes bytes)');
    }
    final id = await blobHash(bytes);
    await _box.put(id, bytes);
    await _times.put(id, DateTime.now().millisecondsSinceEpoch);
    return id;
  }

  @override
  Future<Uint8List?> get(String hashHex) async {
    final bytes = _box.get(hashHex);
    if (bytes != null) {
      // Touch access time (fire-and-forget).
      unawaited(_times.put(hashHex, DateTime.now().millisecondsSinceEpoch));
    }
    return bytes;
  }

  @override
  Future<bool> has(String hashHex) async => _box.containsKey(hashHex);

  /// Deletes blobs not accessed in the last [pruneDays] days.
  /// Returns the number of blobs pruned.
  Future<int> prune({Set<String>? keep}) async {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: pruneDays))
        .millisecondsSinceEpoch;
    var count = 0;
    for (final key in _box.keys.toList().cast<String>()) {
      if (keep != null && keep.contains(key)) continue;
      final lastAccess = _times.get(key) ?? 0;
      if (lastAccess < cutoff) {
        await _box.delete(key);
        await _times.delete(key);
        count++;
      }
    }
    return count;
  }
}
