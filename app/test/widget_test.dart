// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/main.dart';

void main() {
  testWidgets('bootstraps and displays an identity fingerprint', (
    tester,
  ) async {
    final store = InMemoryKeyStore();
    await tester.pumpWidget(HearthApp(keyStore: store, autoPoll: false));

    // Shows a loader while the identity is generated.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    // Identity fingerprint is shown (the root pubkey derived from the device cert).
    expect(find.byKey(const Key('identity-fingerprint')), findsOneWidget);
    // Root seed is NOT persisted (offline-root model — only device key persisted).
    expect(await store.readSeed(), isNull);
  });

  testWidgets('reuses the persisted identity across launches', (tester) async {
    final store = InMemoryKeyStore();

    await tester.pumpWidget(HearthApp(keyStore: store, autoPoll: false));
    await tester.pumpAndSettle();
    final fp1 = tester.widget<Text>(find.byKey(const Key('identity-fingerprint')));

    // Re-mount with the same store: identity should be stable (same device key).
    await tester.pumpWidget(HearthApp(keyStore: store, autoPoll: false));
    await tester.pumpAndSettle();
    final fp2 = tester.widget<Text>(find.byKey(const Key('identity-fingerprint')));
    expect(fp2.data, fp1.data);
  });
}
