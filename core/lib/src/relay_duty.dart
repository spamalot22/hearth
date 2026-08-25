// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Deterministically spreads relay-watch duty across a connected component.
///
/// A node works when its time-varying SHA-256 priority ranks among the first two
/// in its direct neighbourhood. Workers from the previous slot overlap during
/// handoff. This avoids making one peer an availability authority: key ordering
/// cannot win permanently, one uncooperative member cannot suppress relay
/// access, and partial topology views fail toward extra local workers. Every
/// participant must rank the same authenticated device identifiers; mixing root
/// and device aliases can invalidate the availability guarantee. Standbys still
/// probe independently, so selected peers are an optimisation rather than an
/// availability authority.
class RelayDutySchedule {
  const RelayDutySchedule({
    this.slot = const Duration(minutes: 1),
    this.handoff = const Duration(seconds: 30),
    this.redundancy = 2,
  });

  final Duration slot;
  final Duration handoff;
  final int redundancy;

  bool isWorker({
    required String self,
    required Iterable<String> members,
    required String channel,
    required DateTime now,
  }) {
    final candidates = {...members, self}.toList()..sort();
    if (candidates.length <= redundancy) return true;

    final slotMs = slot.inMilliseconds;
    if (slotMs <= 0 || redundancy <= 0) return true;
    final handoffMs = handoff.inMilliseconds.clamp(0, slotMs);
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    final slotNumber = nowMs ~/ slotMs;

    if (_selected(candidates, channel, slotNumber).contains(self)) return true;

    final elapsed = _mod(nowMs, slotMs);
    if (elapsed >= handoffMs) return false;
    return _selected(candidates, channel, slotNumber - 1).contains(self);
  }

  Set<String> _selected(
    List<String> candidates,
    String channel,
    int slotNumber,
  ) {
    final ranked =
        [
          for (final member in candidates)
            (
              member: member,
              priority: sha256
                  .convert(
                    utf8.encode(
                      'hearth-relay-duty|$channel|$slotNumber|$member',
                    ),
                  )
                  .bytes,
            ),
        ]..sort((a, b) {
          final byPriority = _compareBytes(a.priority, b.priority);
          return byPriority != 0 ? byPriority : a.member.compareTo(b.member);
        });
    return ranked.take(redundancy).map((candidate) => candidate.member).toSet();
  }

  static int _compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final comparison = a[i].compareTo(b[i]);
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }

  static int _mod(int value, int modulus) =>
      ((value % modulus) + modulus) % modulus;
}
