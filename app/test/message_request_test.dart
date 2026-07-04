// SPDX-License-Identifier: AGPL-3.0-or-later
// Message requests: someone reaching you via your contact card lands as a
// request you must Accept (which runs the add-a-petname prompt) rather than
// dropping straight into your conversations. Drives the owner-side gate via the
// test seam (no live mesh needed).
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';
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

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  _drain(tester);
  expect(warnings, isEmpty, reason: 'unexpected framework warnings: $warnings');
}

/// Reaches the owner via their card (opens a quarantined request DM), then
/// injects a first message from that peer into it.
Future<ChannelSession> _incomingRequest(
  WidgetTester tester,
  HearthTestApi api,
  Identity peer,
) async {
  await api.simulateIncomingContact(peer.publicKeyHex);
  await _settle(tester);
  final session = api.activeChannel()!;
  final message = await Message.create(
    author: peer,
    channel: session.channelId,
    payload: await session.cipher.encrypt(
      const TextContent('hey, it is me').encode(),
    ),
    prev: session.repository.heads(),
  );
  await session.publish(message);
  await api.refresh();
  await _settle(tester);
  return session;
}

void main() {
  setUp(warnings.clear);

  testWidgets('an incoming card contact is a request, not an open DM', (
    tester,
  ) async {
    final api = HearthTestApi();
    await tester.pumpWidget(
      HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
    );
    await _settle(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    await _incomingRequest(tester, api, peer);

    // Their message is visible, but the composer is gated behind Accept.
    expect(find.text('hey, it is me'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(
      find.byType(TextField),
      findsNothing,
      reason: 'no reply box until the request is accepted',
    );
    await _finish(tester);
  });

  testWidgets('accepting prompts for a petname and opens the DM', (
    tester,
  ) async {
    final api = HearthTestApi();
    await tester.pumpWidget(
      HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
    );
    await _settle(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    await _incomingRequest(tester, api, peer);

    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await _settle(tester);
    // The usual add-a-petname prompt.
    expect(find.textContaining('Add hearth#'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Pat',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Accept'),
      ),
    );
    await _settle(tester);

    // Promoted: the request bar is gone, a composer appears, the DM is theirs.
    expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
    expect(
      find.byType(TextField),
      findsWidgets,
      reason: 'accepted → you can now reply',
    );
    expect(find.text('hey, it is me'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('declining forgets the request', (tester) async {
    final api = HearthTestApi();
    await tester.pumpWidget(
      HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
    );
    await _settle(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    await _incomingRequest(tester, api, peer);

    await tester.tap(find.widgetWithText(TextButton, 'Decline'));
    await _settle(tester);

    // The DM is gone — no request bar, no message.
    expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
    expect(find.text('hey, it is me'), findsNothing);
    await _finish(tester);
  });
}
