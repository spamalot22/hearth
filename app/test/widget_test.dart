import 'package:chat_app/main.dart';
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bootstraps and displays an identity fingerprint', (
    tester,
  ) async {
    final store = InMemoryKeyStore();
    await tester.pumpWidget(HearthApp(keyStore: store, autoPoll: false));

    // Shows a loader while the identity is generated.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    // Identity is shown, and its seed was persisted to the store.
    expect(find.byKey(const Key('identity-fingerprint')), findsOneWidget);
    expect(await store.readSeed(), isNotNull);
  });

  testWidgets('reuses the persisted identity across launches', (tester) async {
    final store = InMemoryKeyStore();

    await tester.pumpWidget(HearthApp(keyStore: store, autoPoll: false));
    await tester.pumpAndSettle();
    final firstSeed = await store.readSeed();

    // Re-mount with the same store: should load the seed, not regenerate.
    await tester.pumpWidget(HearthApp(keyStore: store, autoPoll: false));
    await tester.pumpAndSettle();
    expect(await store.readSeed(), firstSeed);
  });
}
