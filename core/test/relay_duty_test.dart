// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  const schedule = RelayDutySchedule();
  const members = ['a', 'b', 'c', 'd', 'e'];

  Set<String> workersAt(Duration offset, [List<String> peers = members]) => {
    for (final member in peers)
      if (schedule.isWorker(
        self: member,
        members: peers,
        channel: 'channel',
        now: DateTime.fromMillisecondsSinceEpoch(
          offset.inMilliseconds,
          isUtc: true,
        ),
      ))
        member,
  };

  test('keeps two workers after the handoff window', () {
    expect(workersAt(const Duration(seconds: 45)), hasLength(2));
  });

  test('overlaps the previous workers during handoff', () {
    final previous = workersAt(const Duration(seconds: 45));
    final current = workersAt(const Duration(seconds: 105));
    expect(workersAt(const Duration(seconds: 65)), previous.union(current));
  });

  test('rotates duty instead of permanently preferring the lowest key', () {
    final slots = {
      for (var slot = 0; slot < 5; slot++)
        workersAt(Duration(seconds: slot * 60 + 45)),
    };
    expect(slots.length, greaterThan(1));
  });

  test('membership order and duplicates do not affect selection', () {
    final now = DateTime.fromMillisecondsSinceEpoch(105000, isUtc: true);
    final ordered = schedule.isWorker(
      self: 'b',
      members: members,
      channel: 'channel',
      now: now,
    );
    final shuffled = schedule.isWorker(
      self: 'b',
      members: const ['e', 'c', 'b', 'a', 'd', 'b'],
      channel: 'channel',
      now: now,
    );
    expect(shuffled, ordered);
  });

  test('small components keep every peer active', () {
    final now = DateTime.fromMillisecondsSinceEpoch(45000, isUtc: true);
    for (final member in const ['a', 'b']) {
      expect(
        schedule.isWorker(
          self: member,
          members: const ['a', 'b'],
          channel: 'channel',
          now: now,
        ),
        isTrue,
      );
    }
  });

  test('partial neighbourhood views cannot select zero workers', () {
    const neighbours = {
      'a': ['b'],
      'b': ['a', 'c'],
      'c': ['b', 'd'],
      'd': ['c', 'e'],
      'e': ['d'],
    };
    final now = DateTime.fromMillisecondsSinceEpoch(45000, isUtc: true);
    final selected = {
      for (final entry in neighbours.entries)
        if (schedule.isWorker(
          self: entry.key,
          members: entry.value,
          channel: 'channel',
          now: now,
        ))
          entry.key,
    };

    expect(selected.length, greaterThanOrEqualTo(2));
  });

  test('consistent device ids retain workers across many slots', () {
    const neighbourhoods = {
      'device-a': ['device-b', 'device-c'],
      'device-b': ['device-a', 'device-c'],
      'device-c': ['device-a', 'device-b'],
    };
    for (var slot = 0; slot < 500; slot++) {
      final now = DateTime.fromMillisecondsSinceEpoch(
        slot * const Duration(minutes: 1).inMilliseconds + 45000,
        isUtc: true,
      );
      final selected = {
        for (final entry in neighbourhoods.entries)
          if (schedule.isWorker(
            self: entry.key,
            members: entry.value,
            channel: 'channel',
            now: now,
          ))
            entry.key,
      };
      expect(selected, hasLength(2), reason: 'slot $slot');
    }
  });
}
