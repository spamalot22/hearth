// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/audio_device_defaults.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hearth/audio_output');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });
  test('reads system endpoints without starting capture', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'defaults');
      return {'inputId': 'mic-2', 'outputId': 'speaker-2'};
    });
    final defaults = await readAudioDeviceDefaults();
    expect(defaults.inputId, 'mic-2');
    expect(defaults.outputId, 'speaker-2');
  });
  test('missing endpoint and malformed ids remain unset', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'inputId': '', 'outputId': 123},
    );
    final defaults = await readAudioDeviceDefaults();
    expect(defaults.inputId, isNull);
    expect(defaults.outputId, isNull);
  });
  test('unavailable native query falls back safely', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    final defaults = await readAudioDeviceDefaults();
    expect(defaults.inputId, isNull);
    expect(defaults.outputId, isNull);
  });
}
