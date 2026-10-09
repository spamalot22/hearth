// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: avoid_relative_lib_imports
import '../../lib/voice_playout_health.dart';

int checkVoicePlayoutHealth() {
  var checks = 0;
  DateTime at(int seconds) =>
      DateTime.utc(2026).add(Duration(seconds: seconds));
  void check(bool value, String name) {
    checks++;
    if (!value) throw StateError(name);
  }

  final stalled = VoicePlayoutHealth();
  for (var second = 0; second <= 16; second++) {
    check(
      stalled.sample(
            packets: second * 50,
            emitted: 0,
            enabled: true,
            now: at(second),
          ) ==
          (second == 16),
      'Packets arriving but never consumed: $second',
    );
  }
  check(
    !stalled.sample(packets: 850, emitted: 480, enabled: true, now: at(17)),
    'Output progress clears the stall',
  );
  for (final mode in ['playing', 'missing', 'muted', 'noPackets', 'invalid']) {
    final health = VoicePlayoutHealth();
    for (var second = 0; second < 30; second++) {
      check(
        !health.sample(
          packets: mode == 'noPackets' ? 0 : second * 50,
          emitted: mode == 'missing'
              ? null
              : (mode == 'invalid'
                    ? -1
                    : (mode == 'playing' ? second * 480 : 0)),
          enabled: mode != 'muted',
          now: at(second),
        ),
        'No false repair during $mode: $second',
      );
    }
  }
  for (final mode in ['reset', 'pause', 'missingPackets', 'mute']) {
    final health = VoicePlayoutHealth();
    for (var second = 0; second < 15; second++) {
      health.sample(
        packets: second * 50,
        emitted: 100,
        enabled: true,
        now: at(second),
      );
    }
    final base = mode == 'pause' ? 60 : 15;
    check(
      !health.sample(
        packets: mode == 'reset' ? 0 : (mode == 'missingPackets' ? null : 750),
        emitted: mode == 'reset' ? 0 : 100,
        enabled: mode != 'mute',
        now: at(base),
      ),
      '$mode clears old evidence',
    );
    check(
      !health.sample(
        packets: 800,
        emitted: 100,
        enabled: true,
        now: at(base + 1),
      ),
      '$mode must start a fresh grace period',
    );
  }
  return checks;
}
