// SPDX-License-Identifier: AGPL-3.0-or-later

/// RSSI is signal strength, not ranging. Bands avoid fabricated metres/bearing.
enum ProximityBand { near, nearby, weak, unknown }

class ProximityObservation {
  ProximityObservation(this.id, this.seenAt);
  final String id;
  DateTime seenAt;
  double? _signal;
  int get rssi => _signal?.round() ?? 127;
  ProximityBand get band => switch (_signal) {
    null => ProximityBand.unknown,
    final value when value >= -60 => ProximityBand.near,
    final value when value >= -78 => ProximityBand.nearby,
    _ => ProximityBand.weak,
  };
  bool update(int rssi, DateTime now) {
    // 0/127 are common platform "unavailable" values.
    if (rssi >= 0 || rssi < -110) return false;
    _signal = _signal == null ? rssi.toDouble() : _signal! * .7 + rssi * .3;
    seenAt = now;
    return true;
  }

  bool stale(DateTime now) =>
      now.difference(seenAt) > const Duration(seconds: 45);
}
