import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Tracks the last-read message id per channel, enabling unread counts.
class UnreadStore {
  UnreadStore._(this._box);

  final Box<String> _box;

  static Future<UnreadStore> open() async {
    final box = await Hive.openBox<String>('hearth.unread');
    return UnreadStore._(box);
  }

  /// Marks a channel as read up to [messageIdHex].
  Future<void> markRead(String channelId, String messageIdHex) =>
      _box.put(channelId, messageIdHex);

  /// The last-read message id for [channelId], or null if never read.
  String? lastReadId(String channelId) => _box.get(channelId);

  /// Count of messages after the last-read point.
  int unreadCount(String channelId, List<String> orderedIdHexes) {
    final lastRead = lastReadId(channelId);
    if (lastRead == null) return orderedIdHexes.length;
    final idx = orderedIdHexes.indexOf(lastRead);
    if (idx < 0) return orderedIdHexes.length;
    return orderedIdHexes.length - idx - 1;
  }
}
