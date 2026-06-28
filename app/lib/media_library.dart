// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// The kinds of re-usable media. The bytes live in the blob store; this library
/// is the typed index over them.
enum MediaKind { sticker, gif, sound }

class MediaItem {
  const MediaItem(this.hash, this.kind, this.name, this.emoji);

  final String hash;
  final MediaKind kind;
  final String? name;
  final String? emoji;
}

/// Your personal media cache: every sticker/GIF/sound you've sent or received,
/// indexed by blob hash so you can re-send it in any channel without re-uploading
/// (and without re-fetching — the bytes are already in the local blob store).
class MediaLibrary {
  MediaLibrary._(this._box);

  final Box<String> _box;

  static Future<MediaLibrary> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.media');
    return MediaLibrary._(box);
  }

  /// Records [hash] under [kind] (idempotent — a known hash is left as-is).
  Future<void> add(
    String hash,
    MediaKind kind, {
    String? name,
    String? emoji,
  }) async {
    if (hash.isEmpty || _box.containsKey(hash)) return;
    await _box.put(
      hash,
      jsonEncode({'kind': kind.name, 'name': name, 'emoji': emoji}),
    );
  }

  /// Every item of [kind] you hold.
  List<MediaItem> byKind(MediaKind kind) {
    final items = <MediaItem>[];
    for (final hash in _box.keys.cast<String>()) {
      final raw = jsonDecode(_box.get(hash)!) as Map;
      if (raw['kind'] == kind.name) {
        items.add(
          MediaItem(
            hash,
            kind,
            raw['name'] as String?,
            raw['emoji'] as String?,
          ),
        );
      }
    }
    return items;
  }

  /// All blob hashes in the library (for prune-protection).
  Set<String> allHashes() => _box.keys.cast<String>().toSet();
}
