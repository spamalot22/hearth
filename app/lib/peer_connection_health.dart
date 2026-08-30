// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Whether activity-resume recovery can retain this native connection.
bool isPeerConnectionHealthy({
  required bool dataChannelOpen,
  required RTCPeerConnectionState? connectionState,
  required RTCIceConnectionState? iceState,
}) =>
    dataChannelOpen &&
    connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
    (iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted);

/// Turns native WebRTC connection-state events into one stale-link callback.
///
/// A disconnected link gets a short recovery window for ordinary network
/// handoffs. Failed and closed links are terminal immediately.
class PeerConnectionHealthMonitor {
  PeerConnectionHealthMonitor({
    required this.onStale,
    this.disconnectGrace = const Duration(seconds: 8),
  });

  final void Function() onStale;
  final Duration disconnectGrace;
  Timer? _disconnectTimer;
  bool _closed = false;

  void handlePeerState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _markHealthy();
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _markDisconnected();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _markStale();
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        break;
    }
  }

  void handleIceState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _markHealthy();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _markDisconnected();
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _markStale();
      case RTCIceConnectionState.RTCIceConnectionStateNew:
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
      case RTCIceConnectionState.RTCIceConnectionStateCount:
        break;
    }
  }

  void _markDisconnected() {
    if (_closed || _disconnectTimer != null) return;
    _disconnectTimer = Timer(disconnectGrace, () {
      _disconnectTimer = null;
      _markStale();
    });
  }

  void _markHealthy() {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
  }

  void _markStale() {
    if (_closed) return;
    _closed = true;
    _markHealthy();
    onStale();
  }

  void close() {
    _closed = true;
    _markHealthy();
  }
}
