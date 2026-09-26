// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/voice_delivery_health.dart';

DateTime _at(int seconds) => DateTime.utc(2026).add(Duration(seconds: seconds));

void main() {
  test(
    'sustained outgoing RTP with stationary fresh receipts needs repair',
    () {
      final health = VoiceDeliveryHealth();
      for (var second = 0; second <= 16; second++) {
        health.receipt(20, _at(second));
        expect(
          health.sample(second * 50, enabled: true, now: _at(second)),
          second == 16,
        );
      }
    },
  );

  test(
    'receiving RTP progress, including counter resets, clears suspicion',
    () {
      for (final reset in [false, true]) {
        final health = VoiceDeliveryHealth();
        for (var second = 0; second < 60; second++) {
          health.receipt(reset && second >= 10 ? 0 : second ~/ 3, _at(second));
          final stalled = health.sample(
            second * 50,
            enabled: true,
            now: _at(second),
          );
          expect(stalled, reset && second >= 25);
        }
      }
    },
  );

  test('silence, mute and missing stats do not trigger RTP recovery', () {
    for (final mode in ['silence', 'mute', 'missing']) {
      final health = VoiceDeliveryHealth();
      for (var second = 0; second < 60; second++) {
        health.receipt(0, _at(second));
        expect(
          health.sample(
            mode == 'missing' ? null : (mode == 'silence' ? 0 : second * 50),
            enabled: mode != 'mute',
            now: _at(second),
          ),
          isFalse,
        );
      }
    }
  });

  test('a missing or stale receiver heartbeat is not evidence of loss', () {
    for (final receipt in [false, true]) {
      final health = VoiceDeliveryHealth();
      if (receipt) health.receipt(0, _at(0));
      for (var second = 0; second < 60; second++) {
        expect(
          health.sample(second * 50, enabled: true, now: _at(second)),
          isFalse,
        );
      }
    }
  });

  test('sender resets and an interruption restart the full grace period', () {
    final health = VoiceDeliveryHealth();
    for (var second = 0; second <= 31; second++) {
      health.receipt(0, _at(second));
      expect(
        health.sample(
          second < 15 ? second : second - 15,
          enabled: true,
          now: _at(second),
        ),
        second == 31,
      );
    }
    expect(health.sample(null, enabled: true, now: _at(32)), isFalse);
    expect(health.sample(100, enabled: true, now: _at(33)), isFalse);
  });

  test(
    'sample duration continues through silence without capture recovery',
    () {
      final health = VoiceCaptureHealth();
      for (var second = 0; second < 60; second++) {
        expect(
          health.sample(second.toDouble(), enabled: true, now: _at(second)),
          isFalse,
        );
      }
    },
  );

  test('capture must first make progress before a stall is actionable', () {
    final health = VoiceCaptureHealth();
    expect(health.sample(0, enabled: true, now: _at(0)), isFalse);
    expect(health.sample(0, enabled: true, now: _at(60)), isFalse);
    expect(health.sample(1, enabled: true, now: _at(61)), isFalse);
    expect(health.sample(1, enabled: true, now: _at(75)), isFalse);
    expect(health.sample(1, enabled: true, now: _at(76)), isTrue);
  });

  test('mute, missing capture stats and resets discard old stall evidence', () {
    for (final mode in ['mute', 'missing', 'reset', 'invalid']) {
      final health = VoiceCaptureHealth();
      health.sample(1, enabled: true, now: _at(0));
      health.sample(2, enabled: true, now: _at(1));
      expect(
        health.sample(
          mode == 'missing' ? null : (mode == 'invalid' ? double.nan : 0),
          enabled: mode != 'mute',
          now: _at(20),
        ),
        isFalse,
      );
      expect(health.sample(0, enabled: true, now: _at(60)), isFalse);
    }
  });
}
