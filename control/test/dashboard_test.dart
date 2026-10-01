import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/dashboard.dart';

void main() {
  for (final phase in ['pre_game', 'period_running', 'break']) {
    testWidgets(
      'delete $phase with confirmation; hide planning while running',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final writes = <Map<String, dynamic>>[];
        final games = <Map<String, dynamic>>[
          {
            'match_id': 'match',
            'revision': 5,
            'sport': 'basketball',
            'phase': phase,
            'active': true,
            'archived': false,
            'created_at': 0,
            'scheduled_at': null,
            'home': {'name': 'Home', 'score': 6},
            'away': {'name': 'Guest', 'score': 0},
          },
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Dashboard(
                  api: (path, method, body) async {
                    if (method == 'POST') {
                      writes.add(body!);
                      games.clear();
                      return {};
                    }
                    return {
                      'boards': [
                        {
                          'slug': 'board',
                          'created_at': 0,
                          'active_match': 'match',
                          'matches': games,
                        },
                      ],
                    };
                  },
                  t: (key) => key,
                  navigate: (_) {},
                  periods: 4,
                  minutes: 10,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (phase != 'pre_game') {
          await tester.tap(find.text('games.running (1)'));
          await tester.pumpAndSettle();
          expect(find.text('game.new'), findsNothing);
        } else {
          expect(find.text('game.new'), findsOneWidget);
        }
        await tester.tap(find.text('game.delete'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        expect(find.textContaining('Home – Guest'), findsOneWidget);
        await tester.tap(find.text('cancel'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        await tester.tap(find.text('game.delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('confirm'));
        await tester.pumpAndSettle();
        expect(writes.single['action'], 'delete');
        expect(writes.single['expected_revision'], 5);
        expect(find.text('game.delete'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
