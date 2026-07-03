// SPDX-License-Identifier: AGPL-3.0-or-later
// Message edit & delete: envelope round-trips plus the real widget tree driven
// the way a user drives it (long-press → Edit/Delete), including the security
// property that an edit or tombstone from anyone but the target's author is
// ignored.
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
  // Empty state has a FilledButton; these tests always start from scratch.
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

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.tap(find.byIcon(Icons.send));
  await _settle(tester);
}

Future<void> _openActions(WidgetTester tester, String messageText) async {
  await tester.longPress(find.text(messageText).first);
  await _settle(tester);
}

/// Crafts a message from [author] encrypted to the active channel and injects
/// it as if it arrived over the mesh.
Future<void> _inject(
  HearthTestApi api,
  Identity author,
  Content content,
) async {
  final session = api.activeChannel()!;
  final message = await Message.create(
    author: author,
    channel: session.channelId,
    payload: await session.cipher.encrypt(content.encode()),
    prev: session.repository.heads(),
  );
  await session.publish(message);
  await api.refresh();
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6)); // let one-shot timers fire
  _drain(tester);
  expect(warnings, isEmpty, reason: 'unexpected framework warnings: $warnings');
}

void main() {
  setUp(warnings.clear);

  group('content envelope', () {
    test('EditContent round-trips target + text', () {
      final back = parseContent(
        const EditContent('deadbeef', 'fixed').encode(),
      );
      expect(back, isA<EditContent>());
      final e = back as EditContent;
      expect(e.targetId, 'deadbeef');
      expect(e.text, 'fixed');
    });

    test('DeleteContent round-trips its target', () {
      final back = parseContent(const DeleteContent('deadbeef').encode());
      expect(back, isA<DeleteContent>());
      expect((back as DeleteContent).targetId, 'deadbeef');
    });
  });

  testWidgets('editing my message rewrites the bubble and tags it', (
    tester,
  ) async {
    await _boot(tester);
    await _send(tester, 'teh typo');

    await _openActions(tester, 'teh typo');
    await tester.tap(find.text('Edit'));
    await _settle(tester);
    expect(
      find.text('Editing message'),
      findsOneWidget,
      reason: 'composer shows the editing banner',
    );

    await _send(tester, 'the fix');
    expect(find.text('the fix'), findsOneWidget, reason: 'new text renders');
    expect(find.text('teh typo'), findsNothing, reason: 'old text is gone');
    expect(find.text('edited'), findsOneWidget, reason: 'edited tag shows');

    // The winning edit is the *last* one — edit again.
    await _openActions(tester, 'the fix');
    await tester.tap(find.text('Edit'));
    await _settle(tester);
    await _send(tester, 'the final fix');
    expect(find.text('the final fix'), findsOneWidget);
    expect(find.text('the fix'), findsNothing);

    await _finish(tester);
  });

  testWidgets('deleting my message leaves a tombstone placeholder', (
    tester,
  ) async {
    await _boot(tester);
    await _send(tester, 'regret this');

    await _openActions(tester, 'regret this');
    await tester.tap(find.text('Delete'));
    await _settle(tester);
    expect(
      find.text('Delete message?'),
      findsOneWidget,
      reason: 'destructive action confirms first',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await _settle(tester);

    expect(find.text('regret this'), findsNothing);
    expect(
      find.text('Message deleted'),
      findsOneWidget,
      reason: 'tombstone placeholder renders',
    );

    await _finish(tester);
  });

  testWidgets('a foreign edit/delete of my message is ignored', (tester) async {
    final api = await _boot(tester);
    await _send(tester, 'my words');
    final myMsgId = api.activeChannel()!.repository.ordered().last.idHex;

    final mallory = await Identity.loadOrCreate(InMemoryKeyStore());
    await _inject(api, mallory, EditContent(myMsgId, 'attacker words'));
    await _inject(api, mallory, DeleteContent(myMsgId));
    await _settle(tester);

    expect(
      find.text('my words'),
      findsOneWidget,
      reason: 'original text still renders — foreign edit ignored',
    );
    expect(find.text('attacker words'), findsNothing);
    expect(find.text('edited'), findsNothing);
    expect(
      find.text('Message deleted'),
      findsNothing,
      reason: 'foreign tombstone ignored',
    );

    await _finish(tester);
  });

  testWidgets('search matches and displays the edited text, not the original', (
    tester,
  ) async {
    await _boot(tester);
    await _send(tester, 'teh typo');
    await _openActions(tester, 'teh typo');
    await tester.tap(find.text('Edit'));
    await _settle(tester);
    await _send(tester, 'the fix');

    await tester.tap(find.byIcon(Icons.search).first);
    await _settle(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Search messages…'),
      'fix',
    );
    await _settle(tester);

    // Bubble + result tile — and the tile shows the post-edit text.
    expect(find.text('the fix'), findsNWidgets(2));
    expect(
      find.text('teh typo'),
      findsNothing,
      reason: 'a result must never render the stale pre-edit text',
    );

    await _finish(tester);
  });

  testWidgets('a peer editing their own message renders the new text', (
    tester,
  ) async {
    final api = await _boot(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    await _inject(api, peer, const TextContent('peer typo'));
    await _settle(tester);
    expect(find.text('peer typo'), findsOneWidget);

    final peerMsgId = api.activeChannel()!.repository.ordered().last.idHex;
    await _inject(api, peer, EditContent(peerMsgId, 'peer fixed'));
    await _settle(tester);

    expect(find.text('peer fixed'), findsOneWidget);
    expect(find.text('peer typo'), findsNothing);
    expect(find.text('edited'), findsOneWidget);

    await _finish(tester);
  });
}
