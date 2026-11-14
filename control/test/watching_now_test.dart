import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/watching_now.dart';

void main() {
  testWidgets('audience refreshes and does not show a false zero on failure', (
    tester,
  ) async {
    var count = 2;
    var failed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: WatchingNow(
          slug: 'test',
          label: 'Watching now: {n}',
          api: (path) async {
            expect(path, '/api/s/test/audience');
            if (failed) throw Exception('offline');
            return {'watching_now': count};
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Watching now: 2'), findsOneWidget);
    count = 1;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.text('Watching now: 1'), findsOneWidget);
    failed = true;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.text('Watching now: –'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
