// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hearth/peer_connection_health.dart';

void main() {
  test('resume preserves only open, fully connected peer links', () {
    expect(
      isPeerConnectionHealthy(
        dataChannelOpen: true,
        connectionState: RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        iceState: RTCIceConnectionState.RTCIceConnectionStateConnected,
      ),
      isTrue,
    );
    expect(
      isPeerConnectionHealthy(
        dataChannelOpen: true,
        connectionState: RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        iceState: RTCIceConnectionState.RTCIceConnectionStateCompleted,
      ),
      isTrue,
    );
    expect(
      isPeerConnectionHealthy(
        dataChannelOpen: true,
        connectionState:
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        iceState: RTCIceConnectionState.RTCIceConnectionStateDisconnected,
      ),
      isFalse,
    );
    expect(
      isPeerConnectionHealthy(
        dataChannelOpen: false,
        connectionState: RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        iceState: RTCIceConnectionState.RTCIceConnectionStateConnected,
      ),
      isFalse,
    );
  });

  test('persistent disconnect becomes stale after the grace period', () async {
    var staleCalls = 0;
    final monitor = PeerConnectionHealthMonitor(
      onStale: () => staleCalls++,
      disconnectGrace: const Duration(milliseconds: 10),
    );

    monitor.handlePeerState(
      RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(staleCalls, 1);
    monitor.close();
  });

  test('a recovered disconnect does not become stale', () async {
    var staleCalls = 0;
    final monitor = PeerConnectionHealthMonitor(
      onStale: () => staleCalls++,
      disconnectGrace: const Duration(milliseconds: 20),
    );

    monitor.handleIceState(
      RTCIceConnectionState.RTCIceConnectionStateDisconnected,
    );
    monitor.handleIceState(
      RTCIceConnectionState.RTCIceConnectionStateConnected,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(staleCalls, 0);
    monitor.close();
  });

  test('failed connections become stale immediately and only once', () {
    var staleCalls = 0;
    final monitor = PeerConnectionHealthMonitor(onStale: () => staleCalls++);

    monitor.handlePeerState(
      RTCPeerConnectionState.RTCPeerConnectionStateFailed,
    );
    monitor.handleIceState(RTCIceConnectionState.RTCIceConnectionStateClosed);

    expect(staleCalls, 1);
    monitor.close();
  });

  for (final iceFirst in [false, true]) {
    test(
      'one connected callback cannot mask the other disconnect ($iceFirst)',
      () async {
        var staleCalls = 0;
        final monitor = PeerConnectionHealthMonitor(
          onStale: () => staleCalls++,
          disconnectGrace: const Duration(milliseconds: 10),
        );
        addTearDown(monitor.close);
        if (iceFirst) {
          monitor.handleIceState(
            RTCIceConnectionState.RTCIceConnectionStateDisconnected,
          );
          monitor.handlePeerState(
            RTCPeerConnectionState.RTCPeerConnectionStateConnected,
          );
        } else {
          monitor.handlePeerState(
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
          );
          monitor.handleIceState(
            RTCIceConnectionState.RTCIceConnectionStateCompleted,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(staleCalls, 1);
      },
    );
  }

  test('both recovered states cancel the shared disconnect deadline', () async {
    var staleCalls = 0;
    final monitor = PeerConnectionHealthMonitor(
      onStale: () => staleCalls++,
      disconnectGrace: const Duration(milliseconds: 10),
    );
    addTearDown(monitor.close);
    monitor.handleIceState(
      RTCIceConnectionState.RTCIceConnectionStateDisconnected,
    );
    monitor.handlePeerState(
      RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
    );
    monitor.handleIceState(
      RTCIceConnectionState.RTCIceConnectionStateConnected,
    );
    monitor.handlePeerState(
      RTCPeerConnectionState.RTCPeerConnectionStateConnected,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(staleCalls, 0);
  });
}
