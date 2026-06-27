// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'dag.dart';
import 'message.dart';
import 'storage.dart';

/// A channel's durable message log: the in-memory [MessageStore] DAG backed by
/// [MessageStorage].
///
/// [load] rehydrates the DAG from storage on startup; [add] is write-through
/// (persist, then index). Every path that introduces a message — sending,
/// receiving over a transport, and later gossip sync — goes through [add], so
/// persistence happens in exactly one place. Reads (ordering, heads) delegate to
/// the in-memory index and stay synchronous.
class MessageRepository {
  MessageRepository(this._storage);

  final MessageStorage _storage;
  final MessageStore _index = MessageStore();

  /// Rehydrates the in-memory DAG from storage. Call once before first read.
  Future<void> load() async {
    for (final message in await _storage.loadAll()) {
      _index.add(message);
    }
  }

  /// Persists and indexes [message]. Returns false (writing nothing) if a
  /// message with the same content id is already present. Persists before
  /// indexing, so the in-memory view never runs ahead of what's on disk.
  Future<bool> add(Message message) async {
    if (_index.contains(message.id)) return false;
    await _storage.append(message);
    _index.add(message);
    return true;
  }

  List<Message> ordered() => _index.ordered();
  List<Uint8List> heads() => _index.heads();
  bool contains(Uint8List id) => _index.contains(id);
  Message? get(Uint8List id) => _index.get(id);
  int get length => _index.length;
}
