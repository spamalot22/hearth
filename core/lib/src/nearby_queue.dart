// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:collection';

import 'package:convert/convert.dart';

import 'nearby_packet.dart';

/// A write-through queue snapshot. Implementations must atomically replace the
/// snapshot, and bound reads before decoding untrusted or damaged disk data.
abstract interface class NearbyQueueStorage {
  Future<List<NearbyQueueEntry>> read();
  Future<void> replace(List<NearbyQueueEntry> entries);
}

class NearbyQueueEntry {
  const NearbyQueueEntry(this.packet, {required this.local});
  final NearbyPacket packet;
  // Set by local publication only; never accepted from a radio frame.
  final bool local;
}

enum NearbyAdmission { stored, duplicate, expired, full, busy }

/// No receipt from this queue means "delivered to recipient". Unknown carriers
/// never suppress normal Hearth delivery, revoke devices, or alter membership.
class NearbyQueue {
  NearbyQueue(
    this.storage, {
    this.maxEntries = 256,
    this.maxBytes = 4 * 1024 * 1024,
    this.maxPerSender = 32,
    this.maxPending = 16,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    if (maxEntries < 4 ||
        maxBytes < NearbyPacket.maxWireBytes ||
        maxPerSender < 1 ||
        maxPending < 1) {
      throw ArgumentError('invalid nearby queue limits');
    }
  }

  final NearbyQueueStorage storage;
  final int maxEntries;
  final int maxBytes;
  final int maxPerSender;
  final int maxPending;
  final DateTime Function() now;
  final _entries = <String, NearbyQueueEntry>{};
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  List<NearbyPacket> get packets => List.unmodifiable(
    _entries.values.where((e) => !e.packet.expired(now())).map((e) => e.packet),
  );
  int get byteCount =>
      _entries.values.fold(0, (n, e) => n + e.packet.encode().length);

  /// Call once before accepting traffic. Reloaded packets must already have
  /// passed NearbyPacket.decode in the storage adapter.
  Future<void> load() => _serial(() async {
    final entries = await storage.read();
    final next = <String, NearbyQueueEntry>{};
    for (final entry in entries.take(maxEntries)) {
      if (_canAdd(next, entry)) next[entry.packet.id] = entry;
    }
    await _commit(next);
  });

  Future<NearbyAdmission> add(NearbyPacket packet, {bool local = false}) {
    if (_pending >= maxPending) return Future.value(NearbyAdmission.busy);
    _pending++;
    return _serial(() async {
      final next = LinkedHashMap<String, NearbyQueueEntry>.from(_entries)
        ..removeWhere((_, e) => e.packet.expired(now()));
      if (packet.expired(now())) return NearbyAdmission.expired;
      if (next.containsKey(packet.id)) return NearbyAdmission.duplicate;
      final entry = NearbyQueueEntry(packet, local: local);
      // Local sends can reclaim space from foreign traffic, not vice versa.
      while (local && !_canAdd(next, entry)) {
        final foreign = next.values.where((e) => !e.local).firstOrNull;
        if (foreign == null) break;
        next.remove(foreign.packet.id);
      }
      if (!_canAdd(next, entry)) return NearbyAdmission.full;
      next[packet.id] = entry;
      await _commit(next);
      return NearbyAdmission.stored;
    }).whenComplete(() => _pending--);
  }

  Future<void> prune() => _serial(() async {
    final next = LinkedHashMap<String, NearbyQueueEntry>.from(_entries)
      ..removeWhere((_, e) => e.packet.expired(now()));
    if (next.length != _entries.length) await _commit(next);
  });

  Future<void> clear() => _serial(() => _commit({}));

  bool _canAdd(Map<String, NearbyQueueEntry> entries, NearbyQueueEntry entry) {
    if (entry.packet.expired(now()) || entries.containsKey(entry.packet.id)) {
      return false;
    }
    final sender = hex.encode(entry.packet.sender);
    final used = entries.values.fold(0, (n, e) => n + e.packet.encode().length);
    if (entries.length >= maxEntries ||
        used + entry.packet.encode().length > maxBytes) {
      return false;
    }
    if (!entry.local) {
      final foreign = entries.values.where((e) => !e.local).toList();
      // Reserve a quarter of both budgets for the owner's outgoing messages.
      if (foreign.length >= maxEntries * 3 ~/ 4 ||
          foreign.fold(0, (n, e) => n + e.packet.encode().length) +
                  entry.packet.encode().length >
              maxBytes * 3 ~/ 4 ||
          foreign.where((e) => hex.encode(e.packet.sender) == sender).length >=
              maxPerSender) {
        return false;
      }
    }
    return true;
  }

  Future<void> _commit(Map<String, NearbyQueueEntry> next) async {
    await storage.replace(List.unmodifiable(next.values));
    _entries
      ..clear()
      ..addAll(next);
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
