// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:core/core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/mesh_control.dart';
import 'package:hearth/peer_signal_router.dart';
import 'package:hearth/signal_auth.dart';
import 'package:hearth/webrtc_mesh.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _channel = 'voice:test-room';
const _first = '11111111111111111111111111111111';
const _second = '22222222222222222222222222222222';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition did not complete');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<SignalControl> _signal(
  Identity sender,
  String recipient,
  String kind,
  String session,
) async {
  final data = <String, Object?>{
    'session': session,
    if (kind == 'ice') ...{
      'candidate': 'candidate:1 1 udp 1 192.0.2.1 10000 typ host',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    } else ...{
      'sdp': 'test-$kind-$session',
      'type': kind,
    },
  };
  return SignalControl(
    to: recipient,
    from: sender.publicKeyHex,
    kind: kind,
    namespace: _channel,
    data: {
      ...data,
      'sig': await signSignal(sender, _channel, kind, recipient, data),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeRtc rtc;
  late Identity local;
  late Identity remote;
  late WebRtcMesh mesh;
  final sent = <SignalControl>[];
  var relayRequests = 0;

  setUp(() async {
    rtc = _NativeRtc()..install();
    local = await Identity.generate();
    remote = await Identity.generate();
    sent.clear();
    relayRequests = 0;
  });
  tearDown(() async {
    await mesh.close();
    rtc.uninstall();
  });

  WebRtcMesh create({
    bool initiator = false,
    bool Function(String)? routeAvailable,
    Set<String> initialPeers = const {},
    Duration timeout = const Duration(seconds: 2),
  }) => WebRtcMesh(
    baseUrl: Uri.parse('https://relay.example'),
    channel: _channel,
    identity: local,
    forceInitiator: initiator,
    initialPeers: initialPeers,
    externalRouteAvailable: routeAvailable ?? (_) => true,
    externalSignalSender: (signal) async {
      sent.add(signal);
      return true;
    },
    relayFallbackDelay: const Duration(hours: 1),
    handshakeTimeout: timeout,
    announceInterval: const Duration(milliseconds: 10),
    retryBackoffBase: const Duration(milliseconds: 5),
    retryBackoffMax: const Duration(milliseconds: 20),
    diagnosticLabel: 'voice',
    client: MockClient((_) async {
      relayRequests++;
      return http.Response('{}', 503);
    }),
  );

  test(
    'native already-open answerer data channel is surfaced immediately',
    () async {
      mesh = create(timeout: const Duration(milliseconds: 250));
      var opened = 0;
      final subscription = mesh.peerConnected.listen((_) => opened++);
      addTearDown(subscription.cancel);
      await mesh.receiveExternalSignal(
        await _signal(remote, local.publicKeyHex, 'offer', _first),
      );
      await rtc.openRemoteDataChannel('pc1');
      await _until(() => opened == 1);
      expect(mesh.connectedPeers, contains(remote.publicKeyHex));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(mesh.connectedPeers, contains(remote.publicKeyHex));
      expect(mesh.connectionFailedFor(remote.publicKeyHex), isFalse);
      expect(relayRequests, 0);
    },
  );

  test(
    'a fresh reconnect offer replaces the retired native connection',
    () async {
      mesh = create();
      await mesh.receiveExternalSignal(
        await _signal(remote, local.publicKeyHex, 'offer', _first),
      );
      await rtc.openRemoteDataChannel('pc1');
      await _until(() => mesh.connectedPeers.isNotEmpty);
      await mesh.receiveExternalSignal(
        await _signal(remote, local.publicKeyHex, 'offer', _second),
      );
      expect(rtc.created, 2);
      expect(rtc.idsFor('peerConnectionDispose'), contains('pc1'));
      expect(rtc.idsFor('setRemoteDescription'), ['pc1', 'pc2']);
      expect(sent.last.data['session'], _second);
      await rtc.openRemoteDataChannel('pc2');
      await _until(() => mesh.connectedPeers.isNotEmpty);
    },
  );

  test('stale answers and ICE cannot affect the current attempt', () async {
    mesh = create(initiator: true);
    mesh.maybeInitiateVia(remote.publicKeyHex);
    await _until(() => sent.isNotEmpty);
    final current = sent.first.data['session']! as String;
    await mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'answer', _first),
    );
    await mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'ice', _first),
    );
    expect(rtc.idsFor('setRemoteDescription'), isEmpty);
    expect(rtc.idsFor('addCandidate'), isEmpty);
    await mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'answer', current),
    );
    rtc.rejectCandidate = true;
    await mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'ice', current),
    );
    expect(rtc.idsFor('setRemoteDescription'), ['pc1']);
    expect(rtc.idsFor('addCandidate'), ['pc1']);
    expect(mesh.peers, contains(remote.publicKeyHex));
    final report = mesh.diagnosticReport();
    expect(report, contains('rejected=1'));
    expect(report, isNot(contains(remote.publicKeyHex)));
    expect(report, isNot(contains('192.0.2.1')));
    expect(report, isNot(contains(current)));
  });

  test('authenticated reconnect offers are serialized per peer', () async {
    mesh = create();
    final gate = Completer<void>();
    rtc.remoteDescriptionGate = gate;
    final one = mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'offer', _first),
    );
    await _until(() => rtc.idsFor('setRemoteDescription').isNotEmpty);
    final two = mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'offer', _second),
    );
    await _until(
      () =>
          mesh.diagnosticReport().contains('Pending signalling operations: 2'),
    );
    expect(rtc.created, 1);
    rtc.remoteDescriptionGate = null;
    gate.complete();
    await one;
    await two;
    expect(rtc.idsFor('setRemoteDescription'), ['pc1', 'pc2']);
  });

  test(
    'a stalled native offer times out without blocking a replacement',
    () async {
      mesh = create(timeout: const Duration(milliseconds: 100));
      final gate = Completer<void>();
      rtc.remoteDescriptionGate = gate;
      await mesh.receiveExternalSignal(
        await _signal(remote, local.publicKeyHex, 'offer', _first),
      );
      expect(mesh.peers, isEmpty);
      expect(mesh.connectionFailedFor(remote.publicKeyHex), isTrue);
      rtc.remoteDescriptionGate = null;
      gate.complete();
      await mesh.receiveExternalSignal(
        await _signal(remote, local.publicKeyHex, 'offer', _second),
      );
      expect(rtc.created, 2);
      expect(sent.where((s) => s.kind == 'answer'), hasLength(1));
      expect(sent.single.data['session'], _second);
    },
  );

  test('leaving discards queued offers without reviving the peer', () async {
    mesh = create();
    final gate = Completer<void>();
    rtc.remoteDescriptionGate = gate;
    final one = mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'offer', _first),
    );
    await _until(() => rtc.idsFor('setRemoteDescription').isNotEmpty);
    final two = mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'offer', _second),
    );
    await _until(
      () =>
          mesh.diagnosticReport().contains('Pending signalling operations: 2'),
    );
    await mesh.disconnectPeer(remote.publicKeyHex);
    rtc.remoteDescriptionGate = null;
    gate.complete();
    await one;
    await two;
    expect(rtc.created, 1);
    expect(mesh.peers, isEmpty);
    expect(sent, isEmpty);
    expect(mesh.connectionFailedFor(remote.publicKeyHex), isFalse);
  });

  test('a late native offer cannot change a timed-out connection', () async {
    mesh = create(initiator: true, timeout: const Duration(milliseconds: 100));
    final gate = Completer<void>();
    rtc.createOfferGate = gate;
    mesh.maybeInitiateVia(remote.publicKeyHex);
    await _until(() => rtc.idsFor('createOffer').isNotEmpty);
    await _until(() => mesh.connectionFailedFor(remote.publicKeyHex));
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rtc.idsFor('setLocalDescription'), isEmpty);
    expect(sent, isEmpty);
  });

  test(
    'voice retries over a recovered parent mesh even after three failures',
    () async {
      var route = false;
      rtc.failCreations = 3;
      mesh = create(
        initiator: true,
        routeAvailable: (_) => route,
        initialPeers: {remote.publicKeyHex},
      );
      final subscription = mesh.peerConnected.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rtc.created, 0);
      route = true;
      await _until(() => sent.isNotEmpty);
      expect(rtc.created, 4);
      expect(sent.single.kind, 'offer');
      expect(relayRequests, 0);
      await mesh.disconnectPeer(remote.publicKeyHex);
      await mesh.recoverConnections();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        rtc.created,
        4,
        reason:
            'An explicit leave must cancel retries, including initial peers',
      );
    },
  );

  test('healthy native links survive resume without renegotiation', () async {
    mesh = create();
    await mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'offer', _first),
    );
    await rtc.openRemoteDataChannel('pc1');
    rtc.peerEvent('pc1', {
      'event': 'peerConnectionState',
      'state': 'connected',
    });
    rtc.peerEvent('pc1', {'event': 'iceConnectionState', 'state': 'connected'});
    await _until(() => mesh.connectedPeers.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await mesh.recoverConnections();
    expect(rtc.created, 1);
    expect(rtc.idsFor('peerConnectionDispose'), isEmpty);
  });

  test('standalone mesh retries over a bridge while relay is down', () async {
    var relayOnline = true;
    var relaySignals = 0;
    var failedAnnounces = 0;
    mesh = WebRtcMesh(
      baseUrl: Uri.parse('https://relay.example'),
      channel: _channel,
      identity: local,
      forceInitiator: true,
      announceInterval: const Duration(milliseconds: 10),
      idleAnnounceInterval: const Duration(milliseconds: 10),
      retryBackoffBase: const Duration(milliseconds: 30),
      client: MockClient((request) async {
        if (!relayOnline) {
          if (request.url.path == '/announce') failedAnnounces++;
          return http.Response('{}', 503);
        }
        if (request.url.path == '/announce') {
          return http.Response('{"peers":[],"token":"token"}', 200);
        }
        if (request.method == 'POST') relaySignals++;
        return http.Response('{"signals":[],"seq":0}', 200);
      }),
    );
    final subscription = mesh.peerConnected.listen((_) {});
    addTearDown(subscription.cancel);
    await _until(() => mesh.authToken != null);
    await mesh.receiveExternalSignal(
      await _signal(remote, local.publicKeyHex, 'offer', _first),
    );
    await rtc.openRemoteDataChannel('pc1');
    await _until(() => mesh.connectedPeers.isNotEmpty);
    relayOnline = false;
    final before = relaySignals;
    final target = (await Identity.generate()).publicKeyHex;
    rtc.failCreations =
        2; // The first target connection fails after the bridge.
    await rtc.receiveControl('pc1', PeersControl([target]));
    await _until(() => rtc.created >= 3 && failedAnnounces > 0);
    await _until(
      () => rtc.sentControls.any(
        (control) =>
            control is SignalControl &&
            control.to == target &&
            control.kind == 'offer',
      ),
    );
    expect(relaySignals, before);
    expect(mesh.connectedPeers, contains(remote.publicKeyHex));
    expect(mesh.diagnosticReport(peers: [target]), contains('child mesh'));
  });

  test(
    'answer-only retries preserve the regular relay polling cadence',
    () async {
      var polls = 0;
      mesh = WebRtcMesh(
        baseUrl: Uri.parse('https://relay.example'),
        channel: _channel,
        identity: local,
        forceInitiator: false,
        initialPeers: {remote.publicKeyHex},
        announceInterval: const Duration(milliseconds: 10),
        signalPollInterval: const Duration(hours: 1),
        idleSignalInterval: const Duration(hours: 1),
        client: MockClient((request) async {
          if (request.url.path == '/announce') {
            return http.Response('{"peers":[],"token":"token"}', 200);
          }
          polls++;
          return http.Response('{"signals":[],"seq":0}', 200);
        }),
      );
      final subscription = mesh.peerConnected.listen((_) {});
      addTearDown(subscription.cancel);
      await _until(() => polls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(polls, 1);
      expect(rtc.created, 0);
    },
  );

  for (final method in ['dataChannelGetBufferedAmount', 'dataChannelSend']) {
    test(
      'stalled native $method retires the link and releases queued sends',
      () async {
        mesh = create();
        await mesh.receiveExternalSignal(
          await _signal(remote, local.publicKeyHex, 'offer', _first),
        );
        await rtc.openRemoteDataChannel('pc1');
        await _until(() => mesh.connectedPeers.isNotEmpty);
        final gate = Completer<void>();
        rtc.stalledMethod = method;
        rtc.sendGate = gate;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        mesh.sendControlTo(remote.publicKeyHex, PeersControl([]));
        mesh.sendControlTo(remote.publicKeyHex, PeersControl([]));
        final flushed = mesh.flushPendingSends();
        await _until(
          () => mesh.connectionFailedFor(remote.publicKeyHex),
          timeout: const Duration(seconds: 8),
        );
        await flushed.timeout(const Duration(seconds: 1));
        expect(mesh.connectedPeers, isEmpty);
        expect(
          mesh.diagnosticReport(),
          contains('Data-channel send failed (TimeoutException)'),
        );
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          rtc.idsFor('dataChannelSend'),
          method == 'dataChannelSend' ? ['pc1'] : isEmpty,
          reason: 'Queued sends must not run after retirement',
        );
      },
    );
  }

  test('attempt ids are signed and cannot be replaced or stripped', () async {
    mesh = create();
    final signal = await _signal(remote, local.publicKeyHex, 'offer', _first);
    final router = PeerSignalRouter(
      selfPeer: local.publicKeyHex,
      channel: _channel,
    );
    expect(await router.authenticate(signal), isTrue);
    for (final data in [
      {...signal.data, 'session': _second},
      {...signal.data}..remove('session'),
    ]) {
      expect(
        await router.authenticate(
          SignalControl(
            to: signal.to,
            from: signal.from,
            kind: signal.kind,
            namespace: _channel,
            data: data,
          ),
        ),
        isFalse,
      );
    }
  });
}

/// Only mocks native WebRTC calls; the real mesh, signing, routing and timers run.
class _NativeRtc {
  static const native = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final _events = <String, MockStreamHandlerEventSink>{};
  final _channels = <EventChannel>[];
  int created = 0;
  int failCreations = 0;
  bool rejectCandidate = false;
  Completer<void>? remoteDescriptionGate;
  Completer<void>? createOfferGate;
  Completer<void>? sendGate;
  String? stalledMethod;

  void _eventChannel(String name) {
    final channel = EventChannel(name);
    _channels.add(channel);
    messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(onListen: (_, events) => _events[name] = events),
    );
  }

  void install() {
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      if (call.method == stalledMethod) await sendGate?.future;
      switch (call.method) {
        case 'dataChannelGetBufferedAmount':
          return {'bufferedAmount': 0};
        case 'createPeerConnection':
          final id = 'pc${++created}';
          if (created <= failCreations) {
            throw PlatformException(code: 'test-create-failure');
          }
          _eventChannel('FlutterWebRTC/peerConnectionEvent$id');
          return {'peerConnectionId': id};
        case 'createDataChannel':
          final pc = (call.arguments as Map)['peerConnectionId'] as String;
          _eventChannel('FlutterWebRTC/dataChannelEvent${pc}data');
          return {'id': 1, 'flutterId': 'data'};
        case 'createOffer':
          await createOfferGate?.future;
          return {'sdp': 'test-local-offer-$created', 'type': 'offer'};
        case 'createAnswer':
          return {'sdp': 'test-local-answer-$created', 'type': 'answer'};
        case 'setRemoteDescription':
          await remoteDescriptionGate?.future;
        case 'addCandidate':
          if (rejectCandidate) {
            throw PlatformException(code: 'test-stale-candidate');
          }
      }
      return null;
    });
  }

  List<String> idsFor(String method) => calls
      .where((c) => c.method == method)
      .map((c) => (c.arguments as Map)['peerConnectionId'] as String)
      .toList();

  Iterable<MeshControl> get sentControls => calls
      .where((call) => call.method == 'dataChannelSend')
      .map((call) => splitFrame((call.arguments as Map)['data'] as String))
      .where((frame) => frame.isControl)
      .map((frame) => MeshControl.decodeBody(frame.body))
      .whereType<MeshControl>();

  Future<void> receiveControl(String id, MeshControl control) async {
    final name = 'FlutterWebRTC/dataChannelEvent${id}remote';
    await _until(() => _events.containsKey(name));
    _events[name]!.success({
      'event': 'dataChannelReceiveMessage',
      'id': 2,
      'type': 'text',
      'data': control.encode(),
    });
  }

  void peerEvent(String id, Map<String, Object> event) =>
      _events['FlutterWebRTC/peerConnectionEvent$id']!.success(event);

  Future<void> openRemoteDataChannel(String id) async {
    await _until(
      () => _events.containsKey('FlutterWebRTC/peerConnectionEvent$id'),
    );
    _eventChannel('FlutterWebRTC/dataChannelEvent${id}remote');
    peerEvent(id, {
      'event': 'didOpenDataChannel',
      'id': 2,
      'label': 'hearth',
      'flutterId': 'remote',
    });
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(native, null);
    for (final channel in _channels) {
      messenger.setMockStreamHandler(channel, null);
    }
  }
}
