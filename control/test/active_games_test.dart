import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/active_games.dart';

void main() {
  testWidgets('controller stays above nested pages and disappears when ended', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var games = <Map<String, dynamic>>[
      {'slug': 'test', 'home': 'Home', 'away': 'Guest'},
    ];
    String? destination;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => ActiveGames(
          api: (_) async => {'games': games},
          label: 'Back to controller',
          navigate: (path) => destination = path,
          child: child!,
        ),
        home: const Scaffold(body: Text('Dashboard')),
      ),
    );
    await tester.pump();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Settings')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back to controller: Home – Guest'));
    expect(destination, '/s/test/control');
    expect(find.text('Settings'), findsOneWidget);
    games = [];
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('Back to controller: Home – Guest'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
