// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// On-device [BlobStore] backed by Hive — stickers and sound clips kept as raw
/// bytes keyed by their content hash. Being content-addressed, storing the same
/// bytes twice is an idempotent overwrite. One store shared across all channels:
/// a blob fetched in one channel is then available everywhere.
class HiveBlobStore implements BlobStore {
  HiveBlobStore._(this._box);

  final Box<Uint8List> _box;

  static Future<HiveBlobStore> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<Uint8List>('hearth.blobs');
    return HiveBlobStore._(box);
  }

  @override
  Future<String> put(Uint8List bytes) async {
    final id = await blobHash(bytes);
    await _box.put(id, bytes);
    return id;
  }

  @override
  Future<Uint8List?> get(String hashHex) async => _box.get(hashHex);

  @override
  Future<bool> has(String hashHex) async => _box.containsKey(hashHex);
}
