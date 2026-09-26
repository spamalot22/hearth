// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/voice_call_bar.dart';

void main() {
  for (final width in [320.0, 390.0, 800.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('voice bar fits width $width at text scale $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final taps = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Column(
                  children: [
                    VoiceCallBar(
                      channelName:
                          'A very long channel name that must never cover call controls',
                      state: VoiceCallState.reconnecting,
                      connectedPeers: 12,
                      muted: false,
                      deafened: false,
                      onOpenChannel: () => taps.add('channel'),
                      onMute: () => taps.add('mute'),
                      onDeafen: () => taps.add('deafen'),
                      onDiagnostics: () => taps.add('diagnostics'),
                      onDisconnect: () => taps.add('disconnect'),
                    ),
                    const Expanded(child: Center(child: Text('Chat'))),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(find.byType(VoiceCallBar));
        final rects = <Rect>[];
        for (final command in ['mute', 'deafen', 'diagnostics', 'disconnect']) {
          final finder = find.byKey(Key('voice-call-$command'));
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(bounds.left));
          expect(rect.right, lessThanOrEqualTo(bounds.right));
          expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          for (final other in rects) {
            expect(rect.overlaps(other), isFalse);
          }
          rects.add(rect);
          await tester.tap(finder);
        }
        final channel = find.byKey(const Key('voice-call-channel'));
        final channelRect = tester.getRect(channel);
        for (final rect in rects) {
          expect(channelRect.overlaps(rect), isFalse);
        }
        await tester.tap(channel);
        expect(taps, [
          'mute',
          'deafen',
          'diagnostics',
          'disconnect',
          'channel',
        ]);
        expect(find.text('Reconnecting - 12 peers'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('deafened microphone cannot be misleadingly unmuted', (
    tester,
  ) async {
    var muted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceCallBar(
            channelName: 'General',
            state: VoiceCallState.connected,
            connectedPeers: 1,
            muted: true,
            deafened: true,
            onOpenChannel: () {},
            onMute: () => muted = true,
            onDeafen: () {},
            onDiagnostics: () {},
            onDisconnect: () {},
          ),
        ),
      ),
    );
    expect(find.byTooltip('Microphone muted while deafened'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('voice-call-mute')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('voice-call-mute')));
    expect(muted, isFalse);
    expect(find.text('Connected - 1 peer'), findsOneWidget);
  });
}
