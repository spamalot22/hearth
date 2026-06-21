import 'dart:convert';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// On-device [MessageStorage] backed by Hive — IndexedDB on web, files on
/// native. Each message is stored as its JSON envelope keyed by content id, so
/// re-appending the same id is an idempotent overwrite, not a duplicate.
class HiveMessageStorage implements MessageStorage {
  HiveMessageStorage._(this._box);

  final Box<String> _box;

  /// Opens the channel's message box, initialising Hive on first use.
  static Future<HiveMessageStorage> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.messages');
    return HiveMessageStorage._(box);
  }

  @override
  Future<void> append(Message message) =>
      _box.put(message.idHex, jsonEncode(message.toJson()));

  @override
  Future<List<Message>> loadAll() async => _box.values
      .map(
        (raw) =>
            Message.fromJson((jsonDecode(raw) as Map).cast<String, Object?>()),
      )
      .toList();
}
