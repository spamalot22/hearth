// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Persists known peer pubkeys per channel with last-seen timestamps.
///
/// On startup, peers are filtered by age since last *successful* connection:
/// - < 14 days → always try
/// - 14–60 days → try roughly once per 14-day window (approximate, keys off the
///   startup day, so it's best-effort rather than exact)
/// - 60–62 days → one final attempt
/// - > 90 days → pruned
///
/// Last-seen only advances on a successful connection, so an unreachable peer's
/// age keeps growing and walks it down these tiers until it's pruned.
///
/// Retries are staggered: each peer gets a random delay (0–2s) so they don't
/// all hit the relay in the same instant on startup.
class CandidateCache {
  CandidateCache._(this._box);

  final Box<String> _box;
  static final _rand = Random();

  static Future<CandidateCache> open() async {
    final box = await Hive.openBox<String>('hearth.peers');
    return CandidateCache._(box);
  }

  /// Returns all known peer pubkeys for [channel] (regardless of TTL).
  Set<String> knownPeers(String channel) => _load(channel).keys.toSet();

  /// Returns peers eligible for a connection attempt, with staggered delays.
  /// Each entry is (peerHex, delay) — the caller should wait [delay] before
  /// attempting that peer.
  List<({String peer, Duration delay})> peersToTry(String channel) {
    final entries = _load(channel);
    final now = DateTime.now().millisecondsSinceEpoch;
    final results = <({String peer, Duration delay})>[];
    final updated = <String, int>{};

    for (final entry in entries.entries) {
      final age = Duration(milliseconds: now - entry.value);
      if (age.inDays < 7) {
        // Fresh — always try.
        results.add((peer: entry.key, delay: _jitter()));
        updated[entry.key] = entry.value;
      } else if (age.inDays < 14) {
        // 7-14 days: only try if we haven't retried recently (7+ days since lastSeen means
        // it's been at least a week — one attempt is fine, the lastSeen won't update until success).
        results.add((peer: entry.key, delay: _jitter()));
        updated[entry.key] = entry.value;
      } else if (age.inDays < 60) {
        // 14-60 days: try once per 14-day window. Skip if age mod 14 > 1 day
        // (approximation: only attempt on startups within the first day of each window).
        if (age.inDays % 14 < 2) {
          results.add((peer: entry.key, delay: _jitter()));
        }
        updated[entry.key] = entry.value;
      } else if (age.inDays < 90) {
        // 60-90 days: final attempt window.
        if (age.inDays < 62) {
          results.add((peer: entry.key, delay: _jitter()));
        }
        updated[entry.key] = entry.value;
      }
      // >90 days: pruned (not added to updated).
    }

    _save(channel, updated);
    return results;
  }

  /// Marks a peer as freshly seen (call on successful connection).
  Future<void> touch(String channel, String peerHex) async {
    final entries = _load(channel);
    entries[peerHex] = DateTime.now().millisecondsSinceEpoch;
    _save(channel, entries);
  }

  /// Removes a specific peer.
  Future<void> remove(String channel, String peerHex) async {
    final entries = _load(channel)..remove(peerHex);
    if (entries.isEmpty) {
      await _box.delete(channel);
    } else {
      _save(channel, entries);
    }
  }

  Map<String, int> _load(String channel) {
    final raw = _box.get(channel);
    if (raw == null) return {};
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
      return {
        for (final entry in decoded.entries)
          if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(entry.key) &&
              entry.value is int)
            entry.key: entry.value! as int,
      };
    } catch (_) {
      return {};
    }
  }

  void _save(String channel, Map<String, int> entries) {
    if (entries.isEmpty) {
      _box.delete(channel);
    } else {
      _box.put(channel, jsonEncode(entries));
    }
  }

  /// Random 0–2s stagger so startup attempts don't all fire at once.
  static Duration _jitter() => Duration(milliseconds: _rand.nextInt(2000));
}
