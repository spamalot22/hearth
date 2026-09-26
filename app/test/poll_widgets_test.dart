// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/content.dart';
import 'package:hearth/main.dart';
import 'package:hearth/poll_widgets.dart';
import 'package:hearth/polls.dart';

Future<void> _channel(WidgetTester tester, String name) async {
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

Future<HearthTestApi> _boot(WidgetTester tester) async {
  final api = HearthTestApi();
  await tester.pumpWidget(
    HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
  );
  await tester.pumpAndSettle();
  await _channel(tester, 'general');
  return api;
}

Future<void> _postPoll(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('composer-more-tools')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('composer-tool-poll')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('poll-question')), 'Lunch?');
  await tester.enterText(find.byKey(const Key('poll-option-0')), 'Pizza');
  await tester.enterText(find.byKey(const Key('poll-option-1')), 'Soup');
  await tester.tap(find.text('Post poll'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('create, vote, change vote, view voters and withdraw', (
    tester,
  ) async {
    final api = await _boot(tester);
    await _postPoll(tester);
    final session = api.activeChannel()!;
    final poll = session.repository.ordered().singleWhere(
      (m) => session.contentOf(m) is PollContent,
    );
    expect(find.text('Lunch?'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('poll-choice-0')));
    expect(session.pollOf(poll.idHex)!.counts, [1, 0]);
    await _tap(tester, find.byKey(const Key('poll-choice-1')));
    expect(session.pollOf(poll.idHex)!.counts, [0, 1]);
    expect(find.byType(PollBubble), findsOneWidget);
    await _tap(tester, find.byTooltip('View votes'));
    expect(find.text('Votes'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Soup'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Remove vote'));
    expect(session.pollOf(poll.idHex)!.total, 0);
    expect(find.text('Remove vote'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incoming vote updates a poll without a background snackbar', (
    tester,
  ) async {
    final api = await _boot(tester);
    await _postPoll(tester);
    final session = api.activeChannel()!;
    final poll = session.repository.ordered().singleWhere(
      (m) => session.contentOf(m) is PollContent,
    );
    await _channel(tester, 'another');
    final peer = await Identity.generate();
    final vote = await Message.create(
      author: peer,
      channel: session.channelId,
      payload: await session.encodePayload(PollVoteContent(poll.idHex, 1)),
      prev: session.repository.heads(),
    );
    await session.engine.receive(vote);
    await tester.pumpAndSettle();
    expect(session.pollOf(poll.idHex)!.counts, [0, 1]);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('poll validation and failed send retain editable draft', (
    tester,
  ) async {
    var sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCreatePollDialog(
                context,
                onCreate: (_) async {
                  sends++;
                  return false;
                },
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post poll'));
    await tester.pumpAndSettle();
    expect(sends, 0);
    await tester.enterText(find.byKey(const Key('poll-question')), 'Dinner?');
    await tester.enterText(find.byKey(const Key('poll-option-0')), 'Pizza');
    await tester.enterText(find.byKey(const Key('poll-option-1')), 'pizza');
    await tester.tap(find.text('Post poll'));
    await tester.pumpAndSettle();
    expect(find.text('Each option must be different.'), findsOneWidget);
    expect(sends, 0);
    await tester.enterText(find.byKey(const Key('poll-option-1')), 'Soup');
    await tester.tap(find.text('Add option'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove option 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post poll'));
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(
      find.text('Poll not saved. Your draft is still here.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('poll-question')))
          .controller!
          .text,
      'Dinner?',
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 900.0]) {
    testWidgets('poll options fit width $width with enlarged text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final poll =
          PollContent('A long question about where everyone wants to meet', [
            'An option with a much longer name than usual',
            'Another equally valid place',
          ]);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 1000),
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: PollBubble(
                    results: PollResults(poll, {'self': 0}),
                    self: 'self',
                    onVote: (_) async => false,
                    voterName: (_) => 'You',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(PollBubble));
      expect(rect.right, lessThanOrEqualTo(width));
      await _tap(tester, find.byKey(const Key('poll-choice-1')));
      expect(find.text('Vote not saved. Try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
