// SPDX-License-Identifier: AGPL-3.0-or-later
// @mentions end-to-end in the app: a message carrying a <@hex> token renders,
// in the bubble, resolved to the *viewer's* name for that person.
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

Future<void> _inject(HearthTestApi api, Identity from, Content content) async {
  final session = api.activeChannel()!;
  final message = await Message.create(
    author: from,
    channel: session.channelId,
    payload: await session.cipher.encrypt(content.encode()),
    prev: session.repository.heads(),
  );
  await session.publish(message);
  await api.refresh();
}

void main() {
  setUp(warnings.clear);

  testWidgets('a mention renders resolved to the viewer\'s name', (
    tester,
  ) async {
    final api = await _boot(tester);
    final alice = await Identity.loadOrCreate(InMemoryKeyStore());
    final bob = await Identity.loadOrCreate(InMemoryKeyStore());

    // Bob announces his name, so the viewer resolves his pubkey to "Bob".
    await _inject(api, bob, const ProfileContent('Bob'));
    // Alice mentions Bob by pubkey token.
    await _inject(api, alice, TextContent('yo <@${bob.publicKeyHex}> here'));
    await _settle(tester);

    expect(
      find.textContaining('@Bob', findRichText: true),
      findsOneWidget,
      reason: 'the <@hex> token renders as the viewer\'s @name',
    );
    expect(
      find.textContaining(bob.publicKeyHex, findRichText: true),
      findsNothing,
      reason: 'the raw pubkey token is never shown',
    );
    await tester.pump(const Duration(seconds: 6));
    _drain(tester);
    expect(warnings, isEmpty, reason: 'unexpected warnings: $warnings');
  });
}
