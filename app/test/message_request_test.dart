// SPDX-License-Identifier: AGPL-3.0-or-later
// Message requests: someone reaching you via your contact card lands as a
// content-free connection request — NO DM is opened, so nothing can be
// received or stored on your device until you accept. Accept runs the usual
// add-a-petname prompt and only then opens the DM; decline just forgets the
// pubkey. Driven via the owner-side test seam (no live mesh needed).
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

Future<HearthTestApi> _boot(WidgetTester tester) async {
  final api = HearthTestApi();
  await tester.pumpWidget(
    HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
  );
  await _settle(tester);
  // A channel gives us the full chrome (app bar + drawer).
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

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  _drain(tester);
  expect(warnings, isEmpty, reason: 'unexpected framework warnings: $warnings');
}

void main() {
  setUp(warnings.clear);

  testWidgets('an incoming contact is a request — no DM is opened', (
    tester,
  ) async {
    final api = await _boot(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    await api.simulateIncomingContact(peer.publicKeyHex);
    await _settle(tester);

    // Crucially: no DM channel exists for them yet — nothing can be received
    // until accept. The active channel is still the group, not a DM.
    expect(api.activeChannel()?.isDm ?? false, isFalse);

    // It surfaces as a request in the drawer.
    await _openDrawer(tester);
    expect(find.text('Message requests'), findsOneWidget);
    expect(find.text('wants to message you'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('accepting prompts for a petname and then opens the DM', (
    tester,
  ) async {
    final api = await _boot(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    await api.simulateIncomingContact(peer.publicKeyHex);
    await _settle(tester);

    await _openDrawer(tester);
    await tester.tap(find.widgetWithText(ListTile, 'wants to message you'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Accept'));
    await _settle(tester);

    // The usual add-a-petname prompt, then the DM opens.
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

    final dm = api.activeChannel();
    expect(dm?.isDm ?? false, isTrue, reason: 'accept opens the DM');
    expect(dm!.peerPubkey, peer.publicKey);
    await _finish(tester);
  });

  testWidgets('declining forgets the request and opens nothing', (
    tester,
  ) async {
    final api = await _boot(tester);
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    await api.simulateIncomingContact(peer.publicKeyHex);
    await _settle(tester);

    await _openDrawer(tester);
    await tester.tap(find.widgetWithText(ListTile, 'wants to message you'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Decline'));
    await _settle(tester);

    expect(api.activeChannel()?.isDm ?? false, isFalse);
    await _openDrawer(tester);
    expect(
      find.text('wants to message you'),
      findsNothing,
      reason: 'declined request is gone',
    );
    await _finish(tester);
  });
}
