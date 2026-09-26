// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter/services.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed handshake retires even without a frame stream listener',
    () async {
      const native = MethodChannel('FlutterWebRTC.Method');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'createPeerConnection') {
          throw PlatformException(code: 'test-failure');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(native, null));
      final peer = (await Identity.generate()).publicKeyHex;
      final left = <String>[];
      final mesh = WebRtcMesh(
        baseUrl: Uri.parse('https://relay.example'),
        channel: 'voice:channel',
        identity: await Identity.generate(),
        forceInitiator: true,
        externalRouteAvailable: (_) => true,
        externalSignalSender: (_) async => true,
        onPeerLeft: left.add,
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(mesh.close);
      mesh.maybeInitiateVia(peer);
      await _waitUntil(() => left.isNotEmpty);
      expect(left, [peer]);
    },
  );

  test(
    'connection created after mesh shutdown is closed and disposed',
    () async {
      const native = MethodChannel('FlutterWebRTC.Method');
      const events = MethodChannel('FlutterWebRTC/peerConnectionEventlate');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final created = Completer<Map<String, Object>>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(native, (call) async {
        calls.add(call.method);
        if (call.method == 'createPeerConnection') return created.future;
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(native, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      final mesh = WebRtcMesh(
        baseUrl: Uri.parse('https://relay.example'),
        channel: 'voice:channel',
        identity: await Identity.generate(),
        forceInitiator: true,
        externalRouteAvailable: (_) => true,
        externalSignalSender: (_) async => true,
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(mesh.close);
      mesh.maybeInitiateVia((await Identity.generate()).publicKeyHex);
      await _waitUntil(() => calls.contains('createPeerConnection'));
      await mesh.close().timeout(const Duration(seconds: 1));
      created.complete({'peerConnectionId': 'late'});
      await _waitUntil(() => calls.contains('peerConnectionDispose'));
      expect(calls, contains('peerConnectionClose'));
      expect(calls, isNot(contains('createDataChannel')));
    },
  );

  test('announce sends a separate private authentication proof', () async {
    final identity = await Identity.generate();
    Map<String, dynamic>? announced;
    final mesh = WebRtcMesh(
      baseUrl: Uri.parse('https://relay.example'),
      channel: 'channel',
      identity: identity,
      client: MockClient((request) async {
        if (request.url.path == '/announce') {
          announced = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"peers":[],"token":"token"}', 200);
        }
        return http.Response('{"signals":[],"seq":0}', 200);
      }),
    );
    final subscription = mesh.peerConnected.listen((_) {});
    addTearDown(() async {
      await subscription.cancel();
      await mesh.close();
    });
    await _waitUntil(() => announced != null);
    final body = announced!;
    expect(body['authSig'], isNot(body['sig']));
    expect(
      await Identity.verifySignature(
        announceAuthSigningBytes(
          'channel',
          identity.publicKeyHex,
          body['ts'] as int,
        ),
        signature: hex.decode(body['authSig'] as String),
        publicKey: identity.publicKey,
      ),
      isTrue,
    );
  });

  test(
    'child mesh delays relay rendezvous during its P2P grace period',
    () async {
      final identity = await Identity.generate();
      var announces = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/announce') {
          announces++;
          return http.Response(
            jsonEncode({
              'peers': <String>[],
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
        channel: 'voice:channel',
        identity: identity,
        client: client,
        relayFallbackDelay: const Duration(milliseconds: 80),
        announceInterval: const Duration(hours: 1),
        idleAnnounceInterval: const Duration(hours: 1),
        signalPollInterval: const Duration(hours: 1),
        idleSignalInterval: const Duration(hours: 1),
      );
      final subscription = mesh.peerConnected.listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(announces, 0);
      await _waitUntil(() => announces == 1);

      await subscription.cancel();
      await mesh.close();
    },
  );

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
    final voiceSignature = hex.encode(
      await peer.sign(
        voicePresenceSigningBytes('channel', peer.publicKeyHex, ts),
      ),
    );
    var presenceChanges = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/announce') {
        return http.Response(
          jsonEncode({
            'peers': <String>[],
            'presence': [
              {
                'pubkey': peer.publicKeyHex,
                'ts': ts,
                'sig': signature,
                'voice': true,
                'voiceSig': voiceSignature,
              },
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
    expect(mesh.relayVoicePeers, contains(peer.publicKeyHex));
    expect(presenceChanges, 1);
    await subscription.cancel();
    await mesh.close();
  });

  test('voice heartbeat adds a separately signed announce assertion', () async {
    final identity = await Identity.generate();
    final payloads = <Map<String, Object?>>[];
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/announce') {
        payloads.add((jsonDecode(request.body) as Map).cast<String, Object?>());
        return http.Response(
          jsonEncode({
            'peers': <String>[],
            'token': 'token-${payloads.length}',
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
      announceInterval: const Duration(hours: 1),
      idleAnnounceInterval: const Duration(hours: 1),
      signalPollInterval: const Duration(hours: 1),
      idleSignalInterval: const Duration(hours: 1),
    );
    final subscription = mesh.peerConnected.listen((_) {});
    await _waitUntil(() => payloads.isNotEmpty);

    mesh.announceVoicePresence(true);
    await _waitUntil(() => payloads.length >= 2);
    final voicePayload = payloads.last;
    expect(voicePayload['voice'], isTrue);
    expect(
      await verifyRelayVoicePresenceClaim(
        channel: 'channel',
        pubkey: identity.publicKeyHex,
        timestampMs: voicePayload['ts']! as int,
        signatureHex: voicePayload['voiceSig']! as String,
      ),
      isTrue,
    );

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
