// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// On-device [MessageStorage] for one channel, backed by Hive — IndexedDB on
/// web, files on native. Each message is stored as its JSON envelope keyed by
/// content id, so re-appending the same id is an idempotent overwrite, not a
/// duplicate. One box per channel keeps each channel's DAG self-contained.
class HiveMessageStorage implements MessageStorage {
  HiveMessageStorage._(this._box);

  final Box<String> _box;

  /// Opens [channelId]'s message box, initialising Hive on first use.
  static Future<HiveMessageStorage> open(String channelId) async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.messages.$channelId');
    return HiveMessageStorage._(box);
  }

  @override
  Future<void> append(Message message) =>
      _box.put(message.idHex, jsonEncode(message.toJson()));

  @override
  Future<List<Message>> loadAll() async {
    final messages = <Message>[];
    for (final raw in _box.values) {
      try {
        final message = Message.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
        if (await message.verify()) messages.add(message);
      } catch (_) {
        // Skip one corrupt/tampered record without hiding the whole channel.
      }
    }
    return messages;
  }
}
