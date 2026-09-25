// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/error_details.dart';

void main() {
  testWidgets(
    'error details are scrollable, copyable and retryable on mobile',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      var retries = 0;
      final report = List.filled(
        100,
        'ICE: checking; waiting for a direct path',
      ).join('\n');
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showErrorDetails(
                  context,
                  message: 'P2P voice connection failed',
                  diagnostics: report,
                  onRetry: () async {
                    retries++;
                  },
                ),
                child: const Text('Show error'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show error'));
      await tester.pumpAndSettle();
      expect(find.text('Error details'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Copy diagnostics'));
      await tester.pumpAndSettle();
      expect(copied, report);
      expect(copied, isNot(contains('P2P voice connection failed')));
      await tester.tap(find.text('Retry connection'));
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ordinary errors open details without a voice retry action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showErrorDetails(
                context,
                message: 'Microphone permission denied',
                diagnostics: 'Permission stage',
              ),
              child: const Text('Show error'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show error'));
    await tester.pumpAndSettle();
    expect(find.text('Microphone permission denied'), findsOneWidget);
    expect(find.text('Retry connection'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
