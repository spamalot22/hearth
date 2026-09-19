// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

class HiveNearbyQueueStorage implements NearbyQueueStorage {
  HiveNearbyQueueStorage(this.box);
  final Box<String> box;
  static const maxSnapshotCharacters = 8 * 1024 * 1024;

  static Future<HiveNearbyQueueStorage> open() async => HiveNearbyQueueStorage(
    await Hive.openBox<String>(
      'hearth.nearby',
      compactionStrategy: (entries, deleted) => deleted > 2,
    ),
  );

  @override
  Future<List<NearbyQueueEntry>> read() async {
    final raw = box.get('queue');
    if (raw == null || raw.length > maxSnapshotCharacters) return [];
    try {
      final values = jsonDecode(raw);
      if (values is! List || values.length > 256) return [];
      final entries = <NearbyQueueEntry>[];
      for (final value in values) {
        if (value is! Map ||
            value['wire'] is! String ||
            value['local'] is! bool) {
          continue;
        }
        final wire = value['wire'] as String;
        if (wire.length > ((NearbyPacket.maxWireBytes + 2) ~/ 3) * 4) continue;
        try {
          final packet = await NearbyPacket.decode(
            base64Decode(wire),
            now: DateTime.now(),
          );
          if (packet != null) {
            entries.add(
              NearbyQueueEntry(packet, local: value['local'] as bool),
            );
          }
        } catch (_) {
          /* A damaged record must not discard other entries. */
        }
      }
      return entries;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> replace(List<NearbyQueueEntry> entries) async {
    final raw = jsonEncode([
      for (final entry in entries)
        {'local': entry.local, 'wire': base64Encode(entry.packet.encode())},
    ]);
    if (raw.length > maxSnapshotCharacters) {
      throw StateError('nearby snapshot too large');
    }
    await box.put('queue', raw);
    await box.flush();
  }
}
