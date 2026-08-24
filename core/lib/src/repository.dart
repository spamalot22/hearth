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
  MessageRepository(
    this._storage, {
    this.maxMessages = 20000,
    this.maxStoredBytes = 128 * 1024 * 1024,
  });

  final MessageStorage _storage;
  final int maxMessages;
  final int maxStoredBytes;
  final MessageStore _index = MessageStore();
  int _storedBytes = 0;

  static int _sizeOf(Message message) => message.payload.length + 512;

  /// Rehydrates the in-memory DAG from storage. Call once before first read.
  Future<void> load() async {
    for (final message in await _storage.loadAll()) {
      if (_index.length >= maxMessages ||
          _storedBytes + _sizeOf(message) > maxStoredBytes) {
        break;
      }
      if (_index.add(message)) _storedBytes += _sizeOf(message);
    }
  }

  /// Persists and indexes [message]. Returns false (writing nothing) if a
  /// message with the same content id is already present. Persists before
  /// indexing, so the in-memory view never runs ahead of what's on disk.
  Future<bool> add(Message message) async {
    if (_index.contains(message.id)) return false;
    if (_index.length >= maxMessages ||
        _storedBytes + _sizeOf(message) > maxStoredBytes) {
      throw const RepositoryCapacityException();
    }
    await _storage.append(message);
    _index.add(message);
    _storedBytes += _sizeOf(message);
    return true;
  }

  List<Message> ordered() => _index.ordered();
  List<Uint8List> heads() => _index.heads();
  bool contains(Uint8List id) => _index.contains(id);
  Message? get(Uint8List id) => _index.get(id);
  Message? getByHex(String idHex) => _index.getByHex(idHex);
  int get length => _index.length;
  int get storedBytes => _storedBytes;
}

class RepositoryCapacityException implements Exception {
  const RepositoryCapacityException();

  @override
  String toString() => 'message history has reached its local safety limit';
}
