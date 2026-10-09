// SPDX-License-Identifier: AGPL-3.0-or-later
// Pure Dart policy checks, with no Flutter/native dependencies.
// ignore_for_file: avoid_relative_lib_imports
import '../../lib/audio_device_policy.dart';

int checkAudioDevicePolicy() {
  var checks = 0;
  String? choose(
    List<({String id, String kind})> devices, {
    String? preferred,
    String? system,
    String kind = 'audiooutput',
  }) => resolveAudioDevice(
    devices,
    kind: kind,
    kindOf: (device) => device.kind,
    idOf: (device) => device.id,
    preferredId: preferred,
    systemDefaultId: system,
  )?.id;
  void check(bool value, String name) {
    checks++;
    if (!value) throw StateError(name);
  }

  final devices = [
    (id: 'mic', kind: 'audioinput'),
    (id: '', kind: 'audiooutput'),
    (id: 'speaker-1', kind: 'audiooutput'),
    (id: 'speaker-2', kind: 'audiooutput'),
  ];
  check(
    choose(devices, system: 'speaker-2') == 'speaker-2',
    'OS default beats first device',
  );
  check(
    choose(devices, preferred: 'speaker-1', system: 'speaker-2') == 'speaker-1',
    'explicit preference beats default',
  );
  check(
    choose(devices, preferred: 'unplugged', system: 'speaker-2') == 'speaker-2',
    'unplugged falls back to OS default',
  );
  check(
    choose(devices, preferred: 'mic', system: 'speaker-2') == 'speaker-2',
    'never select wrong kind',
  );
  check(
    choose(devices, system: 'missing') == 'speaker-1',
    'missing OS default has bounded fallback',
  );
  check(
    choose(devices, kind: 'videoinput') == null,
    'absent kind returns null',
  );
  check(choose([]) == null, 'empty enumeration returns null');
  final aliases = [...devices, (id: 'default', kind: 'audiooutput')];
  check(choose(aliases) == 'default', 'default alias beats order');
  check(
    choose(aliases, system: 'speaker-2') == 'speaker-2',
    'actual endpoint beats alias',
  );
  check(
    choose(aliases, preferred: 'default', system: 'speaker-2') == 'default',
    'explicit alias preserved',
  );
  check(
    choose(devices, system: 'speaker-1') == 'speaker-1' &&
        choose(devices, system: 'speaker-2') == 'speaker-2',
    'unset preference follows OS changes',
  );
  check(
    choose(devices, preferred: 'speaker-1', system: 'speaker-2') ==
            'speaker-1' &&
        choose(devices, preferred: 'speaker-1', system: 'speaker-1') ==
            'speaker-1',
    'fixed choice ignores OS changes',
  );
  return checks;
}
