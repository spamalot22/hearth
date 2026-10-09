// SPDX-License-Identifier: AGPL-3.0-or-later

/// Keeps explicit choices; removed/unset devices fall back to the OS endpoint,
/// then a default alias, before using enumeration order as a last resort.
T? resolveAudioDevice<T>(
  Iterable<T> devices, {
  required String kind,
  required String Function(T) kindOf,
  required String Function(T) idOf,
  String? preferredId,
  String? systemDefaultId,
}) {
  T? first;
  T? system;
  T? alias;
  for (final device in devices) {
    final id = idOf(device);
    if (kindOf(device) != kind || id.isEmpty) continue;
    first ??= device;
    if (id == preferredId) return device;
    if (id == systemDefaultId) system = device;
    if (id == 'default') alias = device;
  }
  return system ?? alias ?? first;
}
