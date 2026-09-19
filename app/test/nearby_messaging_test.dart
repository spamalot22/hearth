// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';
import 'package:hearth/content.dart';
import 'package:hearth/nearby_bluetooth.dart';
import 'package:hearth/nearby_messaging.dart';
import 'package:hearth/nearby_queue_hive.dart';
import 'package:hearth/nearby_settings.dart';
import 'package:hearth/proximity_scanner.dart';
import 'package:hearth/settings.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('hearth/nearby');
  const events = MethodChannel('hearth/nearby_events');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late SettingsStore settings;
  late ChannelManager channels;
  late Identity identity;
  late NearbyMessaging nearby;
  late _Bluetooth bluetooth;
  final calls = <String>[];
  var internet = 'online';
  var permitted = true;
  var stopped = false;
  var wifiReady = true;
  var awarePairing = false;
  var failAwareStart = false;
  Completer<void>? starting;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    dir = await Directory.systemTemp.createTemp('hearth-nearby-test-');
    calls.clear();
    internet = 'online';
    permitted = true;
    stopped = false;
    wifiReady = true;
    awarePairing = false;
    failAwareStart = false;
    starting = null;
    messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final value in call.arguments as List) '$value': 1};
      }
      return 1;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'capabilities':
          return {
            'supported': true,
            'sdk': 36,
            'permitted': permitted,
            'internet': internet,
            'stopped': stopped,
            'wifiReady': wifiReady,
            'awarePairing': awarePairing,
            'bluetoothReady': true,
          };
        case 'start':
          if (failAwareStart) {
            throw PlatformException(code: 'aware_unavailable');
          }
          await starting?.future;
          return null;
        case 'rearm':
          stopped = false;
          return null;
        default:
          return null;
      }
    });
    settings = await SettingsStore.open();
    identity = await Identity.generate();
    channels = ChannelManager(
      identity: identity,
      relayUrl: Uri.parse('https://relay.test'),
      live: false,
      onUpdate: () {},
    );
    await channels.openGroup('group', Uint8List(32));
    bluetooth = _Bluetooth();
    nearby = NearbyMessaging(
      identity: identity,
      settings: settings,
      sessions: () => channels.sessions,
      bluetooth: bluetooth,
    );
    await nearby.initialize();
  });

  tearDown(() async {
    if (starting != null && !starting!.isCompleted) starting!.complete();
    await nearby.close();
    await channels.close();
    await Hive.close();
    for (final channel in [native, events, paths, permissions]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  test(
    'default off never starts radios; manual mode works despite Wi-Fi Internet',
    () async {
      expect(calls, isNot(contains('start')));
      await nearby.configure(enabled: true, automatic: false);
      expect(calls, contains('start'));
      expect(nearby.activation, NearbyActivation.active);
      await nearby.configure(enabled: false, automatic: false);
      expect(calls.last, 'capabilities');
      expect(calls, contains('stop'));
      expect(nearby.activation, NearbyActivation.disabled);
    },
  );

  test(
    'automatic Internet mode waits; permission denial never starts a service',
    () async {
      await nearby.configure(enabled: true, automatic: true);
      expect(nearby.activation, NearbyActivation.standby);
      expect(calls, isNot(contains('start')));
      permitted = false;
      await nearby.configure(enabled: true, automatic: false);
      expect(nearby.activation, NearbyActivation.waitingForPermission);
      expect(calls, isNot(contains('start')));
    },
  );

  test(
    'native Stop latch disables automatic retries until an explicit rearm',
    () async {
      await nearby.configure(enabled: true, automatic: false);
      stopped = true;
      await nearby.refresh();
      expect(settings.nearbyEnabled, isFalse);
      final starts = calls.where((c) => c == 'start').length;
      await nearby.refresh();
      expect(calls.where((c) => c == 'start'), hasLength(starts));
    },
  );

  test(
    'text is double-sealed for carriers; media is not added to nearby queue',
    () async {
      await nearby.configure(enabled: true, automatic: false);
      final session = channels.active!;
      const content = TextContent('private nearby text');
      final message = await Message.create(
        author: identity,
        channel: 'group',
        payload: await session.encodePayload(content),
      );
      await session.publish(
        message,
        onStored: () => nearby.publish(session, message, content),
      );
      final storage = await HiveNearbyQueueStorage.open();
      final entries = await storage.read();
      expect(entries, hasLength(1));
      final packet = entries.single.packet;
      expect(
        utf8.decode(packet.encode()),
        isNot(contains('private nearby text')),
      );
      final restored = Message.fromJson(
        (jsonDecode(utf8.decode(await session.cipher.decrypt(packet.body)))
                as Map)
            .cast<String, Object?>(),
      );
      expect(restored.idHex, message.idHex);
      expect(await restored.verify(), isTrue);
      // A valid message with a non-text content argument must not be couriered.
      await nearby.publish(
        session,
        message,
        const ReactionContent('target', 'heart'),
      );
      expect(await storage.read(), hasLength(1));
    },
  );

  test(
    'disabling during a pending native start stops the late service',
    () async {
      starting = Completer<void>();
      final enable = nearby.configure(enabled: true, automatic: false);
      for (var i = 0; i < 100 && !calls.contains('start'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(calls, contains('start'));
      final disable = nearby.configure(enabled: false, automatic: false);
      starting!.complete();
      starting = null;
      await enable;
      await disable;
      expect(settings.nearbyEnabled, isFalse);
      expect(nearby.activation, NearbyActivation.disabled);
      expect(
        calls.lastIndexOf('stop'),
        greaterThan(calls.lastIndexOf('start')),
      );
    },
  );

  test(
    'scanner works without messaging, forces active mode and clears observations on stop',
    () async {
      await nearby.configure(enabled: true, automatic: true);
      expect(nearby.active, isFalse);
      await nearby.configure(enabled: false, automatic: true);
      await nearby.setScanner(true);
      expect(nearby.active, isTrue);
      expect(nearby.enabled, isFalse);
      expect(nearby.scannerEnabled, isTrue);
      bluetooth.signal!('beacon', -55);
      expect(nearby.observations.single.band, ProximityBand.near);
      expect(nearby.queuedCount, 0);
      await nearby.setScanner(false);
      expect(nearby.active, isFalse);
      expect(bluetooth.active, isFalse);
      expect(nearby.observations, isEmpty);
    },
  );

  test(
    'Bluetooth continues without usable Wi-Fi and restarts after radio loss',
    () async {
      wifiReady = false;
      await nearby.configure(enabled: true, automatic: false);
      expect(nearby.active, isTrue);
      expect(calls, isNot(contains('start')));
      expect(bluetooth.starts, 1);
      bluetooth.active = false;
      await nearby.refresh();
      expect(bluetooth.starts, 2);
      expect(bluetooth.active, isTrue);
    },
  );

  test('notification Stop disables scanner as well as messaging', () async {
    await nearby.configure(enabled: true, automatic: false);
    await nearby.setScanner(true);
    stopped = true;
    await nearby.refresh();
    expect(nearby.scannerEnabled, isFalse);
    expect(nearby.enabled, isFalse);
    expect(nearby.active, isFalse);
    expect(bluetooth.active, isFalse);
  });

  test('Aware startup failure retains BLE and retries independently', () async {
    failAwareStart = true;
    await nearby.configure(enabled: true, automatic: false);
    expect(nearby.active, isTrue);
    expect(bluetooth.active, isTrue);
    expect(bluetooth.starts, 1);
    final attempts = calls.where((c) => c == 'start').length;
    failAwareStart = false;
    await nearby.refresh();
    expect(calls.where((c) => c == 'start').length, attempts + 1);
    expect(bluetooth.starts, 1);
  });

  test('Aware pairing is explicit and unavailable while stopped', () async {
    awarePairing = true;
    await nearby.configure(enabled: true, automatic: false);
    expect(nearby.canPairAware, isTrue);
    expect(calls, isNot(contains('pair')));
    await nearby.pairAware();
    expect(calls.where((c) => c == 'pair'), hasLength(1));
    await nearby.configure(enabled: false, automatic: false);
    expect(nearby.canPairAware, isFalse);
    await expectLater(nearby.pairAware(), throwsStateError);
    expect(calls.where((c) => c == 'pair'), hasLength(1));
  });

  testWidgets('paired Aware control follows native capability on Android', (
    tester,
  ) async {
    await nearby.configure(enabled: true, automatic: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: NearbySettings(messaging: nearby)),
        ),
      ),
    );
    expect(find.text('Pair Wi-Fi Aware device'), findsNothing);
    awarePairing = true;
    await nearby.refresh();
    await tester.pump();
    final button = find.text('Pair Wi-Fi Aware device');
    expect(button, findsOneWidget);
    expect(calls, isNot(contains('pair')));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(calls.where((c) => c == 'pair'), hasLength(1));
    awarePairing = false;
    await nearby.refresh();
    await tester.pump();
    expect(find.text('Pair Wi-Fi Aware device'), findsNothing);
    expect(bluetooth.active, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'accepted WAN text bridges to nearby without renewing its lifetime',
    () async {
      await nearby.configure(enabled: true, automatic: false);
      final session = channels.active!;
      final author = await Identity.generate();
      final created = DateTime.now().subtract(const Duration(hours: 2));
      final message = await Message.create(
        author: author,
        channel: 'group',
        timestampMs: created.millisecondsSinceEpoch,
        payload: await session.encodePayload(
          const TextContent('WAN to nearby'),
        ),
      );
      await session.engine.receive(message);
      for (var i = 0; i < 100 && nearby.queuedCount == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final entries = await (await HiveNearbyQueueStorage.open()).read();
      expect(entries, hasLength(1));
      expect(entries.single.local, isFalse);
      expect(entries.single.packet.createdMs, created.millisecondsSinceEpoch);
      await session.engine.receive(message);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(nearby.queuedCount, 1);
    },
  );

  testWidgets(
    'scanner is a separate closable popup with narrow and large-text layouts',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: NearbySettings(messaging: nearby),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Proximity scanner'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => IconButton(
                tooltip: 'Open scanner',
                icon: const Icon(Icons.radar),
                onPressed: () => showProximityScanner(context, nearby),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Open scanner'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Scanner inactive'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close scanner'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _Bluetooth implements NearbyBluetoothRadio {
  @override
  bool active = false;
  int starts = 0;
  void Function(String, int)? signal;
  @override
  Future<void> start({
    required Future<void> Function(NearbyLink) onLink,
    required void Function(String, int) onSignal,
  }) async {
    starts++;
    active = true;
    signal = onSignal;
  }

  @override
  Future<void> scanSignals() async {}
  @override
  Future<void> stop() async {
    active = false;
  }
}
