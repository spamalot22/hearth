// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:collection';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'message.dart';

/// An append-only, content-addressed store of [Message]s forming a channel DAG.
///
/// This is the CRDT at the heart of a channel: [ordered] is a pure function of
/// the *set* of messages, so two peers holding the same messages compute the
/// same order regardless of the sequence they arrived in. Messages are keyed by
/// their content id, so adding the same message twice is a no-op.
///
/// The store does **not** verify signatures — callers should
/// `await message.verify()` before [add]ing. It is synchronous and in-memory;
/// durable persistence is layered on top later.
class MessageStore {
  final Map<String, Message> _byId = HashMap<String, Message>();
  List<Message>? _cachedOrder;

  /// Adds [m]; returns false if a message with the same id was already present.
  bool add(Message m) {
    final key = m.idHex;
    if (_byId.containsKey(key)) return false;
    _byId[key] = m;
    _cachedOrder = null; // invalidate
    return true;
  }

  bool contains(Uint8List id) => _byId.containsKey(hex.encode(id));

  Message? get(Uint8List id) => _byId[hex.encode(id)];

  /// [get], keyed by the id's hex form — the index's native key, so callers
  /// already holding a hex id skip a decode/encode round-trip.
  Message? getByHex(String idHex) => _byId[idHex];

  int get length => _byId.length;

  Iterable<Message> get messages => _byId.values;

  /// The current DAG frontier: ids of present messages that no present message
  /// references in its `prev`. A new message extends the DAG by setting its
  /// `prev` to these. Returned in deterministic (timestamp-then-id) order.
  List<Uint8List> heads() {
    final referenced = HashSet<String>();
    for (final m in _byId.values) {
      for (final p in m.prev) {
        referenced.add(hex.encode(p));
      }
    }
    final result = <Message>[];
    for (final m in _byId.values) {
      if (!referenced.contains(m.idHex)) result.add(m);
    }
    result.sort(_byTimestampThenId);
    return result.map((m) => m.id).toList(growable: false);
  }

  /// All present messages in deterministic causal order: a topological sort of
  /// the DAG (a message follows every present message in its `prev`), with ties
  /// between causally-concurrent messages broken by (timestamp, id).
  ///
  /// Parents that aren't present yet (out-of-order delivery) simply impose no
  /// constraint until they arrive — the result stays a valid causal order of
  /// whatever subset is held.
  List<Message> ordered() {
    if (_cachedOrder != null) return _cachedOrder!;
    // Kahn's algorithm over the present-only subgraph.
    final indegree = HashMap<String, int>();
    final childrenOf = HashMap<String, List<String>>();
    for (final m in _byId.values) {
      indegree.putIfAbsent(m.idHex, () => 0);
      for (final p in m.prev) {
        final pk = hex.encode(p);
        if (_byId.containsKey(pk)) {
          indegree[m.idHex] = (indegree[m.idHex] ?? 0) + 1;
          childrenOf.putIfAbsent(pk, () => <String>[]).add(m.idHex);
        }
      }
    }

    // Frontier of nodes with no remaining present parents, popped smallest-first
    // for deterministic ordering of causally-concurrent messages.
    final ready = SplayTreeSet<Message>(_byTimestampThenId);
    for (final m in _byId.values) {
      if (indegree[m.idHex] == 0) ready.add(m);
    }

    final out = <Message>[];
    while (ready.isNotEmpty) {
      final m = ready.first;
      ready.remove(m);
      out.add(m);
      for (final childKey in childrenOf[m.idHex] ?? const <String>[]) {
        final remaining = indegree[childKey]! - 1;
        indegree[childKey] = remaining;
        if (remaining == 0) ready.add(_byId[childKey]!);
      }
    }
    // Content-addressing makes cycles impossible (a cycle would require a hash
    // to contain itself), so every present node is emitted.
    assert(out.length == _byId.length, 'cycle in a content-addressed DAG?');
    _cachedOrder = List.unmodifiable(out);
    return _cachedOrder!;
  }

  static int _byTimestampThenId(Message a, Message b) {
    final t = a.timestampMs.compareTo(b.timestampMs);
    return t != 0 ? t : a.idHex.compareTo(b.idHex);
  }
}
