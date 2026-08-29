// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/signal_auth.dart';
import 'package:hearth/webrtc_mesh.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before the deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('forceAnnounce preserves recurring presence announcements', () async {
    final identity = await Identity.generate();
    var announces = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/announce') {
        announces++;
        return http.Response(
          jsonEncode({
            'peers': <String>[],
            'token': 'token-$announces',
            'relayEpoch': 'epoch',
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'signals': <Object>[], 'seq': 0}), 200);
    });
    final mesh = WebRtcMesh(
      baseUrl: Uri.parse('https://relay.example'),
      channel: 'channel',
      identity: identity,
      client: client,
      announceInterval: const Duration(milliseconds: 15),
      idleAnnounceInterval: const Duration(milliseconds: 15),
      signalPollInterval: const Duration(hours: 1),
      idleSignalInterval: const Duration(hours: 1),
    );
    final subscription = mesh.peerConnected.listen((_) {});

    await _waitUntil(() => announces >= 1);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    mesh.forceAnnounce();
    await _waitUntil(() => announces >= 2);
    final afterForcedAnnounce = announces;
    await _waitUntil(() => announces > afterForcedAnnounce);

    await subscription.cancel();
    await mesh.close();
  });

  test(
    'recoverConnections immediately re-announces and polls signals',
    () async {
      final identity = await Identity.generate();
      var announces = 0;
      var signalPolls = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/announce') {
          announces++;
          return http.Response(
            jsonEncode({
              'peers': <String>[],
              'token': 'token-$announces',
              'relayEpoch': 'epoch',
            }),
            200,
          );
        }
        if (request.method == 'GET' && request.url.path == '/signal') {
          signalPolls++;
          return http.Response(
            jsonEncode({
              'signals': <Object>[],
              'seq': 0,
              'relayEpoch': 'epoch',
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final mesh = WebRtcMesh(
        baseUrl: Uri.parse('https://relay.example'),
        channel: 'channel',
        identity: identity,
        client: client,
        announceInterval: const Duration(hours: 1),
        idleAnnounceInterval: const Duration(hours: 1),
        signalPollInterval: const Duration(hours: 1),
        idleSignalInterval: const Duration(hours: 1),
      );
      final subscription = mesh.peerConnected.listen((_) {});

      await _waitUntil(() => announces >= 1);
      await mesh.recoverConnections();

      expect(announces, greaterThanOrEqualTo(2));
      expect(signalPolls, greaterThanOrEqualTo(1));

      await subscription.cancel();
      await mesh.close();
    },
  );

  test(
    'answer-only discovery polls without announce timer starvation',
    () async {
      final identity = await Identity.generate();
      final peer = await Identity.generate();
      var announces = 0;
      var signalPolls = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/announce') {
          announces++;
          return http.Response(
            jsonEncode({
              'peers': <String>[peer.publicKeyHex],
              'token': 'token-$announces',
              'relayEpoch': 'epoch',
            }),
            200,
          );
        }
        if (request.method == 'GET' && request.url.path == '/signal') {
          signalPolls++;
          return http.Response(
            jsonEncode({
              'signals': <Object>[],
              'seq': 0,
              'relayEpoch': 'epoch',
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final mesh = WebRtcMesh(
        baseUrl: Uri.parse('https://relay.example'),
        channel: 'channel',
        identity: identity,
        client: client,
        forceInitiator: false,
        announceInterval: const Duration(milliseconds: 15),
        idleAnnounceInterval: const Duration(milliseconds: 15),
        signalPollInterval: const Duration(hours: 1),
        idleSignalInterval: const Duration(hours: 1),
      );
      final subscription = mesh.peerConnected.listen((_) {});

      await _waitUntil(() => announces >= 2 && signalPolls >= 2);

      await subscription.cancel();
      await mesh.close();
    },
  );

  test('exposes only verified relay presence to the app', () async {
    final identity = await Identity.generate();
    final peer = await Identity.generate();
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
    final signature = hex.encode(
      await peer.sign(presenceSigningBytes('channel', peer.publicKeyHex, ts)),
    );
    var presenceChanges = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/announce') {
        return http.Response(
          jsonEncode({
            'peers': <String>[],
            'presence': [
              {'pubkey': peer.publicKeyHex, 'ts': ts, 'sig': signature},
            ],
            'token': 'token',
            'relayEpoch': 'epoch',
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({'signals': <Object>[], 'seq': 0, 'relayEpoch': 'epoch'}),
        200,
      );
    });
    final mesh = WebRtcMesh(
      baseUrl: Uri.parse('https://relay.example'),
      channel: 'channel',
      identity: identity,
      client: client,
      onRelayPresenceChanged: () => presenceChanges++,
      announceInterval: const Duration(hours: 1),
      idleAnnounceInterval: const Duration(hours: 1),
      signalPollInterval: const Duration(hours: 1),
      idleSignalInterval: const Duration(hours: 1),
    );
    final subscription = mesh.peerConnected.listen((_) {});

    await _waitUntil(() => mesh.relayVisiblePeers.contains(peer.publicKeyHex));

    expect(mesh.presentPeers, contains(peer.publicKeyHex));
    expect(presenceChanges, 1);
    await subscription.cancel();
    await mesh.close();
  });

  test('a standby periodically probes relay services', () async {
    final identity = await Identity.generate();
    var announces = 0;
    var signalPolls = 0;
    var courierProbes = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/announce') {
        announces++;
        return http.Response(
          jsonEncode({
            'peers': <String>[],
            'token': 'token-$announces',
            'relayEpoch': 'epoch',
          }),
          200,
        );
      }
      if (request.method == 'GET' && request.url.path == '/signal') {
        signalPolls++;
        return http.Response(
          jsonEncode({'signals': <Object>[], 'seq': 0, 'relayEpoch': 'epoch'}),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final mesh = WebRtcMesh(
      baseUrl: Uri.parse('https://relay.example'),
      channel: 'channel',
      identity: identity,
      client: client,
      coordinateRelayDuty: true,
      standbyProbeInterval: const Duration(milliseconds: 20),
      announceInterval: const Duration(hours: 1),
      idleAnnounceInterval: const Duration(hours: 1),
      signalPollInterval: const Duration(hours: 1),
      idleSignalInterval: const Duration(hours: 1),
      onRelayStandbyProbe: () async {
        courierProbes++;
      },
    );
    final subscription = mesh.peerConnected.listen((_) {});

    await _waitUntil(() => announces >= 1);
    mesh.debugSetRelayDuty(false);
    await _waitUntil(
      () => announces >= 2 && signalPolls >= 1 && courierProbes >= 1,
    );

    expect(mesh.hasRelayDuty, isFalse);
    await subscription.cancel();
    await mesh.close();
  });
}
