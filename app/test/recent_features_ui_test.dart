// SPDX-License-Identifier: AGPL-3.0-or-later
// Drives the real app widget tree (autoPoll off → everything in-memory, no mesh)
// through the recent messaging-UX features: create a channel, send a message,
// then react / pin / reply on it. This is the running app, driven the way a user
// drives it — taps and text, asserting the resulting widget tree.
//
// Non-fatal FlutterErrors (framework layout warnings) are drained and surfaced
// via `warnings` rather than failing the flow, so we assert on real behaviour;
// the warnings themselves are reported as verification findings.
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

Future<void> _boot(WidgetTester tester) async {
  await tester.pumpWidget(
    HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false),
  );
  await _settle(tester);
}

Future<void> _createChannel(WidgetTester tester, String name) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Create a channel'));
  await _settle(tester);
  await tester.enterText(find.byType(TextField), name);
  await tester.tap(find.widgetWithText(FilledButton, 'Create'));
  await _settle(tester);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.tap(find.byIcon(Icons.send));
  await _settle(tester);
}

Future<void> _openActions(WidgetTester tester) async {
  await tester.longPress(find.text('hello world').first);
  await _settle(tester);
}

void main() {
  testWidgets('create → send → react → pin → reply all drive the real UI', (
    tester,
  ) async {
    await _boot(tester);
    expect(find.text('Welcome to Hearth'), findsOneWidget);

    // Create a channel → the channel view (composer) renders.
    await _createChannel(tester, 'test channel');
    expect(
      find.text('Message test channel'),
      findsOneWidget,
      reason: 'composer should render after create',
    );

    // Send a message locally (no mesh) → its bubble renders.
    await _send(tester, 'hello world');
    expect(
      find.text('hello world'),
      findsOneWidget,
      reason: 'a locally-sent message should render its bubble',
    );

    // React: long-press → tap 👍 → a reaction chip appears on the message.
    await _openActions(tester);
    expect(
      find.text('👍'),
      findsOneWidget,
      reason: 'quick-emoji row should show',
    );
    await tester.tap(find.text('👍'));
    await _settle(tester);
    expect(
      find.textContaining('👍'),
      findsWidgets,
      reason: 'reaction chip should render after reacting',
    );

    // Pin: long-press → Pin → a pin indicator appears.
    await _openActions(tester);
    await tester.tap(find.text('Pin'));
    await _settle(tester);
    expect(
      find.byIcon(Icons.push_pin),
      findsWidgets,
      reason: 'pin indicator should render after pinning',
    );

    // Reply: long-press → Reply → the composer shows a reply preview banner,
    // which duplicates the quoted text (so it now appears twice).
    await _openActions(tester);
    await tester.tap(find.text('Reply'));
    await _settle(tester);
    expect(
      find.text('hello world'),
      findsNWidgets(2),
      reason: 'reply banner should quote the message above the composer',
    );

    // Let any pending one-shot animation timers fire before teardown.
    await tester.pump(const Duration(seconds: 6));
    _drain(tester);

    // `warnings` should stay empty now; the drain is defensive so a stray
    // non-fatal framework notice can't mask the behavioural assertions above.
    expect(
      warnings,
      isEmpty,
      reason: 'unexpected framework warnings: $warnings',
    );
  });
}
