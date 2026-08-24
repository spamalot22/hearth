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
}
