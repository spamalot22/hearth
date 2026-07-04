// SPDX-License-Identifier: AGPL-3.0-or-later
// A3 end-to-end: a message the app sends is authored by the root identity but
// signed by this device's subkey, carrying a valid cert — and still verifies.
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/main.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (
    Object? e = tester.takeException();
    e != null;
    e = tester.takeException()
  ) {}
}

void main() {
  testWidgets('a sent message is device-signed and verifies', (tester) async {
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

    await tester.enterText(find.byType(TextField).last, 'hello');
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);

    final session = api.activeChannel()!;
    final msg = session.repository.ordered().last;

    // Signed by a device subkey, not the author directly…
    expect(msg.device, isNotNull, reason: 'message is device-signed');
    // …but still authored by the root identity…
    expect(
      msg.author,
      isNot(msg.device),
      reason: 'author is the root, not the device',
    );
    // …with a cert that binds the device to that same root…
    expect(msg.cert, isNotNull);
    expect(msg.cert!.rootKey, msg.author);
    expect(msg.cert!.deviceKey, msg.device);
    // …and the whole chain verifies.
    expect(
      await msg.verify(),
      isTrue,
      reason: 'root→device→message chain valid',
    );

    await tester.pump(const Duration(seconds: 6));
    for (
      Object? e = tester.takeException();
      e != null;
      e = tester.takeException()
    ) {}
  });
}
