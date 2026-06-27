import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/gif_search.dart';

void main() {
  // Regression: searching used to call `setState(() => _results = _search(...))`,
  // whose arrow returned the Future to setState and threw "callback returned a
  // Future" on every keystroke — so results never appeared. Typing must run the
  // search without throwing (here the relay is unreachable, so it just resolves
  // to the unavailable state — the point is that no exception escapes).
  testWidgets('typing a query runs the search without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  pickGif(context, Uri.parse('http://localhost:1')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'cat');
    await tester.pump(const Duration(milliseconds: 400)); // fire the debounce
    await tester.pump(); // run the resulting microtask

    expect(tester.takeException(), isNull);
  });
}
