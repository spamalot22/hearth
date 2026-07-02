// SPDX-License-Identifier: AGPL-3.0-or-later
// Voice messages: envelope round-trip, clip-time formatting, and the widget
// tree rendering a received voice message (composer mic button + the
// duration-labelled fetching state; actual capture/playback needs a device).
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

void main() {
  setUp(warnings.clear);

  test('VoiceContent round-trips blob + duration', () {
    final back = parseContent(const VoiceContent('cafebabe', 7300).encode());
    expect(back, isA<VoiceContent>());
    final v = back as VoiceContent;
    expect(v.blob, 'cafebabe');
    expect(v.durationMs, 7300);
  });

  test('formatClipTime renders mm:ss', () {
    expect(formatClipTime(0), '0:00');
    expect(formatClipTime(7300), '0:07');
    expect(formatClipTime(61000), '1:01');
    expect(formatClipTime(600000), '10:00');
  });

  testWidgets('composer offers a mic button', (tester) async {
    await _boot(tester);
    expect(find.byTooltip('Voice message'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('a received voice message shows its duration while fetching', (
    tester,
  ) async {
    final api = await _boot(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    final session = api.activeChannel()!;
    final message = await Message.create(
      author: peer,
      channel: session.channelId,
      payload: await session.cipher.encrypt(
        const VoiceContent('cafebabe', 7300).encode(),
      ),
      prev: session.repository.heads(),
    );
    await session.publish(message);
    await api.refresh();
    await _settle(tester);

    expect(
      find.text('Voice message · 0:07'),
      findsOneWidget,
      reason: 'un-fetched voice blob renders as a labelled duration chip',
    );
    await _finish(tester);
  });
}
