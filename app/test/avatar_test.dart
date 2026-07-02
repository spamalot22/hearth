// SPDX-License-Identifier: AGPL-3.0-or-later
// Custom avatars: profile envelope carries the blob hash, the downscaler
// bounds the long side, and the widget tree keeps the pubkey-gradient fallback
// when no avatar image is held.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/content.dart';
import 'package:hearth/main.dart';

final warnings = <String>{};

void _drain(WidgetTester tester) {
  for (
    Object? e = tester.takeException();
    e != null;
    e = tester.takeException()
  ) {
    warnings.add(e.toString().split('\n').first);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  _drain(tester);
}

Future<HearthTestApi> _boot(WidgetTester tester) async {
  final api = HearthTestApi();
  await tester.pumpWidget(
    HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
  );
  await _settle(tester);
  await tester.tap(find.widgetWithText(FilledButton, 'Create a channel'));
  await _settle(tester);
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    'general',
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Create'));
  await _settle(tester);
  return api;
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6)); // let one-shot timers fire
  _drain(tester);
  expect(warnings, isEmpty, reason: 'unexpected framework warnings: $warnings');
}

/// Renders a solid [width]×[height] image and returns it PNG-encoded.
Future<Uint8List> _pngBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

void main() {
  setUp(warnings.clear);

  test('ProfileContent round-trips name + avatar hash', () {
    final back = parseContent(
      const ProfileContent('sam', avatar: 'cafebabe').encode(),
    );
    expect(back, isA<ProfileContent>());
    final p = back as ProfileContent;
    expect(p.name, 'sam');
    expect(p.avatar, 'cafebabe');
  });

  test('ProfileContent without avatar stays avatar-less', () {
    final back = parseContent(const ProfileContent('sam').encode());
    expect((back as ProfileContent).avatar, isNull);
  });

  testWidgets('downscaleAvatar bounds the long side, keeps aspect', (
    tester,
  ) async {
    // runAsync: the image codec resolves outside the fake-async test zone.
    await tester.runAsync(() async {
      // Wide: 400×200 → 128×64.
      final wide = await _decode(
        await downscaleAvatar(await _pngBytes(400, 200)),
      );
      expect(wide.width, 128);
      expect(wide.height, 64);
      wide.dispose();

      // Tall: 100×500 → 25×128 (the *long* side is bounded, not just width).
      final tall = await _decode(
        await downscaleAvatar(await _pngBytes(100, 500)),
      );
      expect(tall.height, 128);
      expect(tall.width, lessThanOrEqualTo(26));
      tall.dispose();

      // Already small stays as-is.
      final small = await _decode(
        await downscaleAvatar(await _pngBytes(64, 64)),
      );
      expect(small.width, 64);
      small.dispose();
    });
  });

  testWidgets('downscaleAvatar rejects garbage', (tester) async {
    await tester.runAsync(() async {
      await expectLater(
        downscaleAvatar(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(anything),
      );
    });
  });

  testWidgets('peers without a shared avatar keep the gradient initial', (
    tester,
  ) async {
    final api = await _boot(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    final session = api.activeChannel()!;
    for (final content in <Content>[
      const ProfileContent('pixel', avatar: 'unfetchable-blob-hash'),
      const TextContent('hi there'),
    ]) {
      final message = await Message.create(
        author: peer,
        channel: session.channelId,
        payload: await session.cipher.encrypt(content.encode()),
        prev: session.repository.heads(),
      );
      await session.publish(message);
    }
    await api.refresh();
    await _settle(tester);

    expect(find.text('hi there'), findsOneWidget);
    expect(
      find.text('P'),
      findsWidgets,
      reason:
          'avatar blob not fetched yet → gradient initial (from the '
          'suggested name) still renders, no broken image',
    );
    await _finish(tester);
  });
}
