// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hearth/voice.dart';
import 'package:hearth/webrtc_mesh.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Capture did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const rtc = MethodChannel('FlutterWebRTC.Method');
  const audio = MethodChannel('xyz.luan/audioplayers');
  const global = MethodChannel('xyz.luan/audioplayers.global');
  final events = <EventChannel>[];
  late Identity identity;
  late WebRtcMesh parent;
  late _CaptureDevices devices;
  VoiceSession? session;

  void mockEvents(String name) {
    final channel = EventChannel(name);
    events.add(channel);
    messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    devices = _CaptureDevices();
    identity = await Identity.generate();
    parent = WebRtcMesh(
      baseUrl: Uri.parse('https://relay.example'),
      channel: 'room',
      identity: identity,
      relayFallbackDelay: const Duration(hours: 1),
      client: MockClient((_) async => http.Response('{}', 503)),
    );
    messenger.setMockMethodCallHandler(rtc, (_) async => null);
    messenger.setMockMethodCallHandler(global, (_) async => null);
    mockEvents('xyz.luan/audioplayers.global/events');
    messenger.setMockMethodCallHandler(audio, (call) async {
      if (call.method == 'create') {
        mockEvents(
          'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}',
        );
      }
      if (call.method == 'setSourceBytes' || call.method == 'setSourceUrl') {
        throw PlatformException(code: 'silent-test-cue');
      }
      return null;
    });
  });

  tearDown(() async {
    await session?.leave();
    session = null;
    await parent.close();
    messenger.setMockMethodCallHandler(rtc, null);
    messenger.setMockMethodCallHandler(audio, null);
    messenger.setMockMethodCallHandler(global, null);
    for (final channel in events) {
      messenger.setMockStreamHandler(channel, null);
    }
    events.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  Future<VoiceSession> join() async => session = await VoiceSession.join(
    channelId: 'room',
    identity: identity,
    relayUrl: Uri.parse('https://relay.example'),
    signalingMesh: parent,
    enhancedNoiseSuppression: true,
    getUserMedia: devices.getUserMedia,
    enumerateDevices: devices.enumerateDevices,
    onChange: () {},
  );

  for (final deafen in [false, true]) {
    test(
      'ended capture reopens with mute/deafen preserved ($deafen)',
      () async {
        final call = await join();
        final old = devices.streams.single;
        if (deafen) {
          call.toggleDeafen();
        } else {
          call.toggleMute();
        }
        old.track.onEnded!();
        await _until(() => old.disposed);
        expect(devices.requests, hasLength(2));
        expect(old.track.stopped, isTrue);
        expect(devices.streams.last.track.enabled, isFalse);
        expect(call.diagnosticReport(), contains('Capture repairs: 1'));
        expect(call.isMuted, isTrue);
      },
    );
  }

  test('lost input constraint falls back to the default microphone', () async {
    final call = await join();
    final old = devices.streams.single;
    devices.failConstrained = true;
    old.track.onEnded!();
    await _until(() => old.disposed);
    expect(devices.requests, hasLength(3));
    expect(devices.requests.last['audio'], isTrue);
    expect(devices.streams.last.track.enabled, isTrue);
    expect(call.diagnosticReport(), contains('Capture repairs: 1'));
  });

  test(
    'desktop capture recovery preserves the currently selected speaker',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final call = await join();
      expect((devices.requests.first['audio'] as Map)['deviceId'], 'speaker-1');
      expect(await call.setAudioOutput('speaker-2'), isTrue);
      final old = devices.streams.single;
      old.track.onEnded!();
      await _until(() => old.disposed);
      expect((devices.requests.last['audio'] as Map)['deviceId'], 'speaker-2');
    },
  );

  test(
    'late recovery capture is disposed after leaving without reopening links',
    () async {
      final call = await join();
      final old = devices.streams.single;
      final pending = Completer<MediaStream>();
      devices.pending = pending;
      old.track.onEnded!();
      await _until(() => devices.requests.length == 2);
      await call.leave();
      final late = _CaptureStream('late');
      pending.complete(late);
      await _until(() => late.disposed);
      expect(late.track.stopped, isTrue);
      expect(late.track.enabled, isFalse);
      expect(call.diagnosticReport(), contains('Capture repairs: 0'));
      expect(devices.requests, hasLength(2));
    },
  );

  test(
    'resume reopens unexpectedly OS-muted capture but not user-muted capture',
    () async {
      final call = await join();
      final old = devices.streams.single;
      call.toggleMute();
      await call.recoverConnections();
      expect(devices.requests, hasLength(1));
      call.toggleMute();
      old.track.onMute!();
      await call.recoverConnections();
      await _until(() => old.disposed);
      expect(devices.requests, hasLength(2));
    },
  );

  test('capture with no audio track is rejected and released', () async {
    devices.empty = true;
    await expectLater(join(), throwsStateError);
    expect(devices.streams.single.disposed, isTrue);
  });

  test('peer playback levels stay bounded and ignore invalid inputs', () async {
    final call = await join();
    await call.setVolume('peer', -1);
    expect(call.volumeOf('peer'), 0);
    await call.setVolume('peer', 2);
    expect(call.volumeOf('peer'), 1);
    await call.setVolume('peer', double.nan);
    await call.setVolume('peer', double.infinity);
    expect(call.volumeOf('peer'), 1);
  });

  test('native stop cannot keep leave pending indefinitely', () async {
    final call = await join();
    final stream = devices.streams.single;
    final pendingStop = Completer<void>();
    stream.track.pendingStop = pendingStop;
    addTearDown(() {
      if (!pendingStop.isCompleted) pendingStop.complete();
    });
    await call.leave().timeout(const Duration(seconds: 5));
    expect(stream.track.enabled, isFalse);
    expect(stream.disposed, isTrue);
    expect(pendingStop.isCompleted, isFalse);
  });
}

class _CaptureDevices {
  final requests = <Map<String, dynamic>>[];
  final streams = <_CaptureStream>[];
  Completer<MediaStream>? pending;
  bool failConstrained = false;
  bool empty = false;

  Future<List<MediaDeviceInfo>> enumerateDevices() async => [
    MediaDeviceInfo(deviceId: 'mic', label: 'Microphone', kind: 'audioinput'),
    MediaDeviceInfo(
      deviceId: 'speaker-1',
      label: 'Speaker 1',
      kind: 'audiooutput',
    ),
    MediaDeviceInfo(
      deviceId: 'speaker-2',
      label: 'Speaker 2',
      kind: 'audiooutput',
    ),
  ];

  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) async {
    requests.add(constraints);
    if (failConstrained && constraints['audio'] != true) {
      throw StateError('Input removed');
    }
    if (pending != null) return pending!.future;
    final stream = _CaptureStream('capture${streams.length}', empty: empty);
    streams.add(stream);
    return stream;
  }
}

class _CaptureStream extends MediaStream {
  _CaptureStream(String id, {this.empty = false}) : super(id, 'local');
  final bool empty;
  final track = _CaptureTrack();
  bool disposed = false;
  @override
  List<MediaStreamTrack> getTracks() => getAudioTracks();
  @override
  List<MediaStreamTrack> getAudioTracks() => empty ? [] : [track];
  @override
  Future<void> dispose() async => disposed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CaptureTrack extends MediaStreamTrack {
  bool _enabled = true;
  bool stopped = false;
  Completer<void>? pendingStop;
  @override
  bool get enabled => _enabled;
  @override
  set enabled(bool value) {
    _enabled = value;
    if (value) {
      onUnMute?.call();
    } else {
      onMute?.call();
    }
  }

  @override
  bool get muted => !_enabled;
  @override
  Future<void> stop() async {
    stopped = true;
    await pendingStop?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
