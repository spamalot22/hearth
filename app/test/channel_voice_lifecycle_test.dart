// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hearth/main.dart';
import 'package:hearth/mesh_control.dart';
import 'package:hearth/voice.dart';
import 'package:hearth/voice_call_bar.dart';

Future<void> _createChannel(WidgetTester tester, String name) async {
  final create = find.widgetWithText(FilledButton, 'Create a channel');
  if (create.evaluate().isNotEmpty) {
    await tester.tap(create);
  } else {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Create a channel'));
  }
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    name,
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Create'));
  await tester.pumpAndSettle();
}

Future<void> _leaveChannel(WidgetTester tester, {bool confirm = true}) async {
  await tester.tap(find.widgetWithText(TextButton, 'Leave channel'));
  await tester.pumpAndSettle();
  await tester.tap(
    confirm
        ? find.widgetWithText(FilledButton, 'Destroy & leave')
        : find.widgetWithText(TextButton, 'Cancel'),
  );
  await tester.pumpAndSettle();
}

void androidTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    try {
      await callback(tester);
    } finally {
      // Drain app disposal while this test's native service mocks are installed.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const service = MethodChannel('hearth/voice_service');
  late HearthTestApi api;
  late List<String> serviceCalls;
  late List<_Voice> calls;

  setUp(() {
    serviceCalls = [];
    calls = [];
    api = HearthTestApi()
      ..createVoiceSession = (id) async {
        final voice = _Voice(id);
        calls.add(voice);
        return voice;
      };
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final permission in call.arguments as List) permission: 1};
      }
      return 1;
    });
    messenger.setMockMethodCallHandler(service, (call) async {
      serviceCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(permissions, null);
    messenger.setMockMethodCallHandler(service, null);
  });

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(
      HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
    );
    await tester.pumpAndSettle();
    await _createChannel(tester, 'alpha');
  }

  Future<void> join(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Join voice'));
    await tester.pumpAndSettle();
    expect(api.activeVoice(), isNotNull);
  }

  androidTestWidgets(
    'channel departure waits for voice teardown before removal',
    (tester) async {
      await boot(tester);
      await join(tester);
      final channel = api.activeChannel()!;
      final call = calls.single;
      final closing = Completer<void>();
      call.closing = closing.future;
      await _leaveChannel(tester);
      expect(call.leaves, 1);
      expect(api.activeVoice(), isNull);
      expect(api.activeChannel(), same(channel));

      // A stale Join button cannot start a new call during channel teardown.
      await api.joinVoice(channel.channelId);
      expect(calls, hasLength(1));
      closing.complete();
      await tester.pumpAndSettle();
      expect(api.activeChannel(), isNull);
      expect(serviceCalls, ['start', 'stop']);
      await api.joinVoice(channel.channelId);
      expect(calls, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  androidTestWidgets('cancelling channel departure keeps voice connected', (
    tester,
  ) async {
    await boot(tester);
    await join(tester);
    await _leaveChannel(tester, confirm: false);
    expect(api.activeVoice(), same(calls.single));
    expect(calls.single.leaves, 0);
    expect(serviceCalls, ['start']);
    await tester.tap(find.byKey(const Key('voice-call-disconnect')));
    await tester.pumpAndSettle();
  });

  androidTestWidgets(
    'channel departure waits for an already-running voice leave',
    (tester) async {
      await boot(tester);
      await join(tester);
      final channel = api.activeChannel();
      final closing = Completer<void>();
      calls.single.closing = closing.future;
      await tester.tap(find.byKey(const Key('voice-call-disconnect')));
      await tester.pumpAndSettle();
      expect(api.activeVoice(), isNull);
      await _leaveChannel(tester);
      expect(api.activeChannel(), same(channel));
      expect(calls.single.leaves, 1);
      closing.complete();
      await tester.pumpAndSettle();
      expect(api.activeChannel(), isNull);
      expect(serviceCalls, ['start', 'stop']);
    },
  );

  androidTestWidgets('leaving another channel does not interrupt the call', (
    tester,
  ) async {
    await boot(tester);
    await join(tester);
    final channelId = api.activeChannel()!.channelId;
    await _createChannel(tester, 'bravo');
    await _leaveChannel(tester);
    expect(api.activeChannel()!.channelId, channelId);
    expect(api.activeVoice(), same(calls.single));
    expect(calls.single.leaves, 0);
    expect(serviceCalls, ['start']);
    await tester.tap(find.byKey(const Key('voice-call-disconnect')));
    await tester.pumpAndSettle();
  });

  androidTestWidgets(
    'late voice startup is discarded after leaving its channel',
    (tester) async {
      await boot(tester);
      final channelId = api.activeChannel()!.channelId;
      final pending = Completer<VoiceSession>();
      var started = false;
      api.createVoiceSession = (_) {
        started = true;
        return pending.future;
      };
      await tester.tap(find.widgetWithText(FilledButton, 'Join voice'));
      await tester.pumpAndSettle();
      expect(started, isTrue);
      await _leaveChannel(tester);
      expect(api.activeChannel(), isNull);
      final lateVoice = _Voice(channelId);
      pending.complete(lateVoice);
      await tester.pumpAndSettle();
      expect(lateVoice.leaves, 1);
      expect(api.activeVoice(), isNull);
      expect(serviceCalls, ['start', 'stop']);
      expect(tester.takeException(), isNull);
    },
  );

  androidTestWidgets('permission completion cannot join a departed channel', (
    tester,
  ) async {
    await boot(tester);
    final permission = Completer<Map<int, int>>();
    List<int>? requested;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        requested = List<int>.from(call.arguments as List);
        return permission.future;
      }
      return 1;
    });
    await tester.tap(find.widgetWithText(FilledButton, 'Join voice'));
    await tester.pumpAndSettle();
    expect(requested, isNotNull);
    await _leaveChannel(tester);
    permission.complete({for (final id in requested!) id: 1});
    await tester.pumpAndSettle();
    expect(api.activeVoice(), isNull);
    expect(calls, isEmpty);
    expect(serviceCalls, isEmpty);
  });

  androidTestWidgets('leaving another channel preserves a pending voice join', (
    tester,
  ) async {
    await boot(tester);
    final channelId = api.activeChannel()!.channelId;
    final pending = Completer<VoiceSession>();
    var started = false;
    api.createVoiceSession = (_) {
      started = true;
      return pending.future;
    };
    await tester.tap(find.widgetWithText(FilledButton, 'Join voice'));
    await tester.pumpAndSettle();
    expect(started, isTrue);
    await _createChannel(tester, 'bravo');
    await _leaveChannel(tester);
    final voice = _Voice(channelId);
    pending.complete(voice);
    await tester.pumpAndSettle();
    expect(api.activeVoice(), same(voice));
    expect(voice.leaves, 0);
    expect(serviceCalls, ['start']);
    await tester.tap(find.byKey(const Key('voice-call-disconnect')));
    await tester.pumpAndSettle();
  });

  androidTestWidgets(
    'persistent bar controls voice and returns to its channel',
    (tester) async {
      await boot(tester);
      await join(tester);
      final channelId = api.activeChannel()!.channelId;
      await _createChannel(tester, 'bravo');
      expect(api.activeChannel()!.channelId, isNot(channelId));
      expect(
        tester.widget<VoiceCallBar>(find.byType(VoiceCallBar)).channelName,
        'alpha',
      );
      await tester.tap(find.byKey(const Key('voice-call-mute')));
      await tester.pumpAndSettle();
      expect(calls.single.isMuted, isTrue);
      expect(find.byTooltip('Unmute microphone'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-call-deafen')));
      await tester.pumpAndSettle();
      expect(calls.single.isDeafened, isTrue);
      expect(find.byTooltip('Undeafen audio'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-call-channel')));
      await tester.pumpAndSettle();
      expect(api.activeChannel()!.channelId, channelId);
      await tester.tap(find.byKey(const Key('voice-call-disconnect')));
      await tester.pumpAndSettle();
      expect(api.activeVoice(), isNull);
      expect(find.byType(VoiceCallBar), findsNothing);
      expect(serviceCalls, ['start', 'stop']);
    },
  );

  androidTestWidgets('mobile settings keeps live voice controls', (
    tester,
  ) async {
    await boot(tester);
    await join(tester);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byType(VoiceCallBar), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-call-mute')));
    await tester.pumpAndSettle();
    expect(calls.single.isMuted, isTrue);
    expect(find.byTooltip('Unmute microphone'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-call-disconnect')));
    await tester.pumpAndSettle();
    expect(find.byType(VoiceCallBar), findsNothing);
    expect(api.activeVoice(), isNull);
    expect(find.text('Settings'), findsOneWidget);
  });

  androidTestWidgets('call channel navigation returns from mobile settings', (
    tester,
  ) async {
    await boot(tester);
    await join(tester);
    final channelId = api.activeChannel()!.channelId;
    await _createChannel(tester, 'bravo');
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-call-channel')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(api.activeChannel()!.channelId, channelId);
    await tester.tap(find.byKey(const Key('voice-call-disconnect')));
    await tester.pumpAndSettle();
  });

  androidTestWidgets('bar exposes diagnostics and guarded connection retry', (
    tester,
  ) async {
    await boot(tester);
    await join(tester);
    await tester.tap(find.byKey(const Key('voice-call-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('Voice connection'), findsOneWidget);
    expect(find.text('Copy diagnostics'), findsOneWidget);
    expect(find.textContaining('Test voice diagnostics'), findsOneWidget);
    await tester.tap(find.text('Retry connection'));
    await tester.pumpAndSettle();
    expect(calls.single.retries, 1);
    await tester.tap(find.byKey(const Key('voice-call-disconnect')));
    await tester.pumpAndSettle();
  });

  androidTestWidgets(
    'bar reflects pending, failed and direct voice connections',
    (tester) async {
      await boot(tester);
      await join(tester);
      final channelId = api.activeChannel()!.channelId;
      final voice = calls.single;
      final peer = 'ab' * 32;
      // Keep the channel's deliberately animated connecting tiles off screen.
      await _createChannel(tester, 'bravo');
      VoiceCallState state() =>
          tester.widget<VoiceCallBar>(find.byType(VoiceCallBar)).state;
      expect(state(), VoiceCallState.waiting);
      void announce() => api.injectControl(
        peer,
        channelId,
        VoicePresenceControl(channelId: channelId),
      );
      announce();
      await tester.pumpAndSettle();
      expect(state(), VoiceCallState.connecting);
      voice.failed = true;
      announce();
      await tester.pumpAndSettle();
      expect(state(), VoiceCallState.reconnecting);
      voice.connected.add(peer);
      announce();
      await tester.pumpAndSettle();
      expect(state(), VoiceCallState.connected);
      expect(find.text('Connected - 1 peer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-call-disconnect')));
      await tester.pumpAndSettle();
    },
  );

  androidTestWidgets(
    'bar cancels voice startup and releases a late microphone',
    (tester) async {
      await boot(tester);
      final channelId = api.activeChannel()!.channelId;
      final pending = Completer<VoiceSession>();
      api.createVoiceSession = (_) => pending.future;
      await tester.tap(find.widgetWithText(FilledButton, 'Join voice'));
      await tester.pumpAndSettle();
      expect(find.text('Connecting'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-call-disconnect')));
      await tester.pumpAndSettle();
      expect(find.text('Disconnecting'), findsOneWidget);
      final lateVoice = _Voice(channelId);
      pending.complete(lateVoice);
      await tester.pumpAndSettle();
      expect(lateVoice.leaves, 1);
      expect(api.activeVoice(), isNull);
      expect(find.byType(VoiceCallBar), findsNothing);
    },
  );
}

class _Voice extends Fake implements VoiceSession {
  _Voice(this.channelId);

  @override
  final String channelId;
  int leaves = 0;
  int retries = 0;
  bool muted = false;
  bool deafened = false;
  bool failed = false;
  final connected = <String>[];
  final pending = <String>{};
  Future<void>? closing;
  @override
  bool get isMuted => muted || deafened;
  @override
  bool get isDeafened => deafened;
  @override
  List<String> get peerHexes => connected;
  @override
  Iterable<String> get pendingPeerHexes =>
      pending.difference(connected.toSet());
  @override
  bool connectionFailedFor(Iterable<String> peers) =>
      failed && peers.isNotEmpty;
  @override
  void connectTo(String peer) => pending.add(peer);
  @override
  String diagnosticReport({Iterable<String>? peers}) =>
      'Test voice diagnostics';
  @override
  Future<void> recoverConnections() async {
    retries++;
  }

  @override
  List<RTCVideoRenderer> get remoteRenderers => const [];
  @override
  bool speaking(String peer) => false;
  @override
  double levelOf(String peer) => 0;
  @override
  void toggleMute() {
    muted = !muted;
  }

  @override
  void toggleDeafen() {
    deafened = !deafened;
  }

  @override
  Future<void> leave() async {
    leaves++;
    await closing;
  }

  // The UI installs optional callbacks; this fake has no remote peers.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}
