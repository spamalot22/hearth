// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hearth/screen_share.dart';
import 'package:hearth/screen_share_fullscreen.dart';

class _View extends ChangeNotifier implements ScreenView {
  bool live = true;
  bool ended = false;
  @override
  String get sharerHex => 'ab' * 32;
  @override
  bool get hasVideo => live;
  @override
  bool get isClosed => ended;
  @override
  RTCVideoRenderer get renderer => throw StateError('Test uses a video stub');
  @override
  Future<void> close() async {
    ended = true;
    notifyListeners();
  }

  @override
  Future<void> enforcePeerPolicy() async {}
}

void main() {
  for (final size in [const Size(1280, 720), const Size(390, 844)]) {
    testWidgets(
      'fullscreen fits $size and Escape exits without ending stream',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final view = _View();
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => ScreenShareFullscreen(
                        view: view,
                        title: 'A very long screen share title ' * 12,
                        onExit: () => Navigator.of(context).pop(),
                        videoBuilder: (_) =>
                            const SizedBox.expand(key: Key('screen-video')),
                      ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const Key('screen-video'))).width,
          size.width,
        );
        expect(
          tester.getSize(find.byKey(const Key('screen-video'))).height,
          greaterThan(size.height - 100),
        );
        expect(tester.takeException(), isNull);
        view.live = false;
        view.notifyListeners();
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        view.live = true;
        view.notifyListeners();
        await tester.pump();
        expect(find.byKey(const Key('screen-video')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Open'), findsOneWidget);
        expect(view.isClosed, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        view.dispose();
      },
    );
  }
}
