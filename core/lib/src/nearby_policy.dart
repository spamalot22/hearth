// SPDX-License-Identifier: AGPL-3.0-or-later

/// Association with an access point is not evidence of Internet reachability.
/// Captive/isolated intranets count as offline; a relay outage alone does not.
enum InternetReachability { unknown, offline, online }

enum NearbyActivation { disabled, standby, waitingForPermission, active }

/// Radio activity is opt-in. Automatic mode uses validated reachability and
/// hysteresis, never an SSID, interface type, or Hearth relay health check.
class NearbyActivationPolicy {
  NearbyActivationPolicy({
    this.offlineDelay = const Duration(seconds: 10),
    this.onlineDelay = const Duration(seconds: 30),
  });

  final Duration offlineDelay;
  final Duration onlineDelay;
  InternetReachability _last = InternetReachability.unknown;
  DateTime? _changedAt;
  bool _active = false;

  NearbyActivation evaluate({
    required bool enabled,
    required bool automatic,
    required InternetReachability internet,
    required bool permitted,
    required DateTime now,
  }) {
    if (!enabled) {
      _last = InternetReachability.unknown;
      _changedAt = null;
      _active = false;
      return NearbyActivation.disabled;
    }
    if (internet != _last) {
      _last = internet;
      _changedAt = now;
    }
    if (!automatic) {
      _active = true;
    } else if (internet == InternetReachability.offline &&
        now.difference(_changedAt ?? now) >= offlineDelay) {
      _active = true;
    } else if (internet == InternetReachability.online &&
        now.difference(_changedAt ?? now) >= onlineDelay) {
      _active = false;
    }
    // An unknown probe result must not tear down a working offline link.
    if (!_active) return NearbyActivation.standby;
    return permitted
        ? NearbyActivation.active
        : NearbyActivation.waitingForPermission;
  }
}

enum NearbyMedium { wifiAware, bluetooth }

/// A preference, not a range measurement. Only established, usable links are
/// eligible. An unavailable or unpaired Wi-Fi Aware path cannot beat BLE.
class NearbyRoute {
  const NearbyRoute({
    required this.id,
    required this.medium,
    required this.usable,
  });

  final String id;
  final NearbyMedium medium;
  final bool usable;

  static NearbyRoute? preferred(Iterable<NearbyRoute> routes) {
    final available = routes.where((r) => r.usable).toList()
      ..sort((a, b) {
        final medium = a.medium.index.compareTo(b.medium.index);
        return medium != 0 ? medium : a.id.compareTo(b.id);
      });
    return available.isEmpty ? null : available.first;
  }
}
