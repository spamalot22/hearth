// SPDX-License-Identifier: AGPL-3.0-or-later
import 'message.dart';

/// Durable, append-only storage for a channel's [Message]s.
///
/// The in-memory [MessageStore] (the DAG) is the query layer — ordering, heads,
/// merge; this is the byte store underneath it. [append] is write-through and
/// [loadAll] rehydrates on startup. Implementations: [InMemoryMessageStorage]
/// (here, for tests) and the app's on-device store (Hive: IndexedDB on web,
/// files on native). Kept in `core` as a pure interface so the DAG can persist
/// without `core` taking a Flutter dependency.
abstract interface class MessageStorage {
  /// Persists [message]. Storing the same content id twice is harmless — the
  /// DAG de-dupes on load — but callers avoid it where they can.
  Future<void> append(Message message);

  /// Every persisted message, in any order (the DAG re-derives causal order).
  Future<List<Message>> loadAll();
}

/// A volatile [MessageStorage] for tests — holds everything in a list.
class InMemoryMessageStorage implements MessageStorage {
  final List<Message> _messages = [];

  @override
  Future<void> append(Message message) async => _messages.add(message);

  @override
  Future<List<Message>> loadAll() async =>
      List<Message>.unmodifiable(_messages);
}
