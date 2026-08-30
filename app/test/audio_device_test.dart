// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hearth/voice.dart';

MediaDeviceInfo _device(String id, String kind) =>
    MediaDeviceInfo(deviceId: id, label: id, kind: kind);

void main() {
  test('preferred audio device keeps an available saved choice', () {
    final devices = [
      _device('mic-1', 'audioinput'),
      _device('speaker-1', 'audiooutput'),
      _device('speaker-2', 'audiooutput'),
    ];

    expect(
      preferredAudioDevice(devices, 'audiooutput', 'speaker-2')?.deviceId,
      'speaker-2',
    );
  });

  test(
    'preferred audio device falls back by kind when saved device is gone',
    () {
      final devices = [
        _device('mic-1', 'audioinput'),
        _device('', 'audiooutput'),
        _device('speaker-1', 'audiooutput'),
        _device('speaker-2', 'audiooutput'),
      ];

      expect(
        preferredAudioDevice(devices, 'audiooutput', 'unplugged')?.deviceId,
        'speaker-1',
      );
      expect(preferredAudioDevice(devices, 'videoinput', null), isNull);
    },
  );

  test('native desktop constraints initialize input and output together', () {
    final constraint = desktopVoiceAudioConstraint(
      input: _device('mic-1', 'audioinput'),
      output: _device('speaker-2', 'audiooutput'),
      web: false,
      enhancedNoiseSuppression: true,
    );

    expect(constraint['deviceId'], 'speaker-2');
    expect(constraint['optional'], [
      {'sourceId': 'mic-1'},
    ]);
    expect(constraint['googNoiseSuppression'], isTrue);
    expect(constraint['googHighpassFilter'], isTrue);
  });

  test('web constraints use the input device id', () {
    final constraint = desktopVoiceAudioConstraint(
      input: _device('mic-1', 'audioinput'),
      output: null,
      web: true,
      enhancedNoiseSuppression: false,
    );

    expect(constraint['deviceId'], {'exact': 'mic-1'});
    expect(constraint, isNot(contains('optional')));
  });
}
