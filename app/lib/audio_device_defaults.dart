// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AudioDeviceDefaults {
  const AudioDeviceDefaults({this.inputId, this.outputId});

  final String? inputId;
  final String? outputId;
}

/// Windows enumeration order is not a default-device contract. Use MMDevice's
/// actual system endpoints, without taking microphone permission or capture.
Future<AudioDeviceDefaults> readAudioDeviceDefaults() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    return const AudioDeviceDefaults();
  }
  try {
    final result = await const MethodChannel('hearth/audio_output')
        .invokeMapMethod<String, dynamic>('defaults')
        .timeout(const Duration(seconds: 3));
    String? id(String key) {
      final value = result?[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return AudioDeviceDefaults(
      inputId: id('inputId'),
      outputId: id('outputId'),
    );
  } on PlatformException {
    return const AudioDeviceDefaults();
  } on MissingPluginException {
    return const AudioDeviceDefaults();
  } catch (_) {
    return const AudioDeviceDefaults();
  }
}
