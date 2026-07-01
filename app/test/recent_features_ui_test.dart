// SPDX-License-Identifier: AGPL-3.0-or-later
// Drives the real app widget tree (autoPoll off → everything in-memory, no mesh)
// through the recent messaging-UX features, the way a user drives it — taps and
// text, asserting the resulting widget tree. Covers: create/send, react (+ the
// toggle-off), pin, reply, in-channel search, per-channel mute, QR invite, and
// the "switching channels clears the reply draft" fix.
//
// Non-fatal FlutterErrors are drained into `warnings` (reset per test) and each
// test asserts it stayed empty, so a stray framework notice can't silently mask
// the behavioural assertions.
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/content.dart';
import 'package:hearth/main.dart';
import 'package:hearth/mesh_control.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
  // Empty state has a FilledButton; once a channel exists, use the drawer entry.
  final fab = find.widgetWithText(FilledButton, 'Create a channel');
  if (fab.evaluate().isNotEmpty) {
    await tester.tap(fab);
  } else {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Create a channel'));
  }
  await _settle(tester);
  // Scope to the dialog's field — once a channel exists, its composer TextField
  // is also on screen, so a bare find.byType(TextField) would be ambiguous.
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    name,
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Create'));
  await _settle(tester);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.tap(find.byIcon(Icons.send));
  await _settle(tester);
}

Future<void> _openActions(WidgetTester tester, String messageText) async {
  await tester.longPress(find.text(messageText).first);
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6)); // let one-shot timers fire
  _drain(tester);
  expect(warnings, isEmpty, reason: 'unexpected framework warnings: $warnings');
}

void main() {
  setUp(warnings.clear);

  testWidgets('create → send → react → pin → reply', (tester) async {
    await _boot(tester);
    expect(find.text('Welcome to Hearth'), findsOneWidget);

    await _createChannel(tester, 'test channel');
    expect(
      find.text('Message test channel'),
      findsOneWidget,
      reason: 'composer should render after create',
    );

    await _send(tester, 'hello world');
    expect(
      find.text('hello world'),
      findsOneWidget,
      reason: 'a locally-sent message should render its bubble',
    );

    await _openActions(tester, 'hello world');
    expect(find.text('👍'), findsOneWidget, reason: 'quick-emoji row shows');
    await tester.tap(find.text('👍'));
    await _settle(tester);
    expect(
      find.textContaining('👍'),
      findsWidgets,
      reason: 'reaction chip renders after reacting',
    );

    await _openActions(tester, 'hello world');
    await tester.tap(find.text('Pin'));
    await _settle(tester);
    expect(
      find.byIcon(Icons.push_pin),
      findsWidgets,
      reason: 'pin indicator renders after pinning',
    );

    await _openActions(tester, 'hello world');
    await tester.tap(find.text('Reply'));
    await _settle(tester);
    expect(
      find.text('hello world'),
      findsNWidgets(2),
      reason: 'reply banner quotes the message above the composer',
    );

    await _finish(tester);
  });

  testWidgets('reacting with the same emoji twice toggles it off', (
    tester,
  ) async {
    await _boot(tester);
    await _createChannel(tester, 'general');
    await _send(tester, 'toggle me');

    await _openActions(tester, 'toggle me');
    await tester.tap(find.text('❤️'));
    await _settle(tester);
    expect(find.textContaining('❤️'), findsWidgets, reason: 'chip appears');

    await _openActions(tester, 'toggle me');
    await tester.tap(find.text('❤️'));
    await _settle(tester);
    expect(
      find.textContaining('❤️'),
      findsNothing,
      reason: 'same emoji from the same author toggles the reaction off',
    );

    await _finish(tester);
  });

  testWidgets('in-channel search filters to matching messages', (tester) async {
    await _boot(tester);
    await _createChannel(tester, 'general');
    await _send(tester, 'apples and oranges');
    await _send(tester, 'bananas');

    await tester.tap(find.byTooltip('Search messages'));
    await _settle(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Search messages…'),
      'banana',
    );
    await _settle(tester);
    // The sheet is modal over the chat, so each message's own bubble is still in
    // the tree behind it. A match appears twice (bubble + result row); a non-match
    // appears once (only its background bubble, not in the results).
    expect(
      find.text('bananas'),
      findsNWidgets(2),
      reason: 'match shows in results',
    );
    expect(
      find.text('apples and oranges'),
      findsOneWidget,
      reason: 'non-matching message is filtered out of the results',
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Search messages…'),
      'zzzzz',
    );
    await _settle(tester);
    expect(find.text('No results'), findsOneWidget);

    await _finish(tester);
  });

  testWidgets('per-channel mute toggle flips on', (tester) async {
    await _boot(tester);
    await _createChannel(tester, 'general');

    final muteTile = find.widgetWithText(SwitchListTile, 'Mute notifications');
    expect(tester.widget<SwitchListTile>(muteTile).value, isFalse);
    await tester.tap(muteTile);
    await _settle(tester);
    expect(
      tester.widget<SwitchListTile>(muteTile).value,
      isTrue,
      reason: 'muting a channel flips its switch on',
    );

    await _finish(tester);
  });

  testWidgets('invite dialog renders a QR code', (tester) async {
    await _boot(tester);
    await _createChannel(tester, 'general');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Invite'));
    await _settle(tester);
    expect(
      find.byType(QrImageView),
      findsOneWidget,
      reason: 'the invite dialog shows a scannable QR code',
    );

    await _finish(tester);
  });

  testWidgets('a peer read-watermark turns my message tick blue', (
    tester,
  ) async {
    final api = HearthTestApi();
    await tester.pumpWidget(
      HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
    );
    await _settle(tester);
    await _createChannel(tester, 'general');
    await _send(tester, 'ping');

    // Before any peer reads it: a grey single-check (sent, not delivered/read).
    final before = tester.widget<Icon>(find.byIcon(Icons.done));
    expect(before.color, Colors.grey);

    // Simulate a peer reporting they've read up to my message.
    final session = api.activeChannel()!;
    final msgId = session.repository.ordered().last.idHex;
    api.injectControl(
      'peer-pubkey-hex',
      session.channelId,
      ReadWatermarkControl(channelId: session.channelId, messageId: msgId),
    );
    await _settle(tester);

    // Now it's a blue double-check (read).
    final after = tester.widget<Icon>(find.byIcon(Icons.done_all));
    expect(after.icon, Icons.done_all);
    expect(
      after.color,
      anyOf(Colors.blue, Colors.blue.shade200),
      reason: 'a received read-watermark should render a blue read tick',
    );

    await _finish(tester);
  });

  testWidgets('blocking a peer redacts their messages', (tester) async {
    final api = HearthTestApi();
    await tester.pumpWidget(
      HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
    );
    await _settle(tester);
    await _createChannel(tester, 'general');

    // Craft a message from a second identity, encrypted to this channel's key,
    // and inject it as if it arrived over the mesh.
    final session = api.activeChannel()!;
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    final payload = await session.cipher.encrypt(
      const TextContent('secret msg').encode(),
    );
    final foreign = await Message.create(
      author: peer,
      channel: session.channelId,
      payload: payload,
    );
    await session.publish(foreign);
    await api.refresh();
    await _settle(tester);
    expect(
      find.text('secret msg'),
      findsOneWidget,
      reason: 'a peer-authored message renders',
    );

    // Tap the peer's avatar → Block.
    final row = find
        .ancestor(of: find.text('secret msg'), matching: find.byType(Row))
        .first;
    await tester.tap(
      find.descendant(of: row, matching: find.byType(GestureDetector)).first,
    );
    await _settle(tester);
    await tester.tap(find.text('Block'));
    await _settle(tester);

    expect(
      find.text('secret msg'),
      findsNothing,
      reason: 'a blocked author\'s message is hidden',
    );
    expect(
      find.text('Blocked message'),
      findsOneWidget,
      reason: 'and replaced with a redacted placeholder',
    );

    await _finish(tester);
  });

  testWidgets('switching channels clears the reply draft', (tester) async {
    await _boot(tester);
    await _createChannel(tester, 'alpha');
    await _createChannel(tester, 'bravo'); // now active
    await _send(tester, 'bravo message');

    // Start a reply on bravo → the banner quotes it (text appears twice).
    await _openActions(tester, 'bravo message');
    await tester.tap(find.text('Reply'));
    await _settle(tester);
    expect(find.text('bravo message'), findsNWidgets(2));

    // Switch to alpha via the drawer.
    await tester.tap(find.byTooltip('Open navigation menu'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'alpha'));
    await _settle(tester);

    expect(find.text('Message alpha'), findsOneWidget, reason: 'now on alpha');
    expect(
      find.text('bravo message'),
      findsNothing,
      reason: 'the reply draft (and its quoted preview) is cleared on switch',
    );

    await _finish(tester);
  });
}
