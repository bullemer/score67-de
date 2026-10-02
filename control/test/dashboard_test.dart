import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/dashboard.dart';

void main() {
  for (final phase in ['pre_game', 'period_running', 'break']) {
    testWidgets(
      'trash $phase (confirm only while running); hide planning while running',
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
        // Moving to the trash is reversible: only a running game asks first.
        if (phase != 'pre_game') {
          await tester.tap(find.text('game.delete'));
          await tester.pumpAndSettle();
          expect(writes, isEmpty);
          expect(find.textContaining('Home – Guest'), findsOneWidget);
          await tester.tap(find.text('cancel'));
          await tester.pumpAndSettle();
          expect(writes, isEmpty);
        }
        await tester.tap(find.text('game.delete'));
        await tester.pumpAndSettle();
        if (phase != 'pre_game') {
          await tester.tap(find.text('confirm'));
          await tester.pumpAndSettle();
        }
        expect(writes.single['action'], 'trash');
        expect(writes.single['expected_revision'], 5);
        expect(find.text('game.delete'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'planned games sort across boards and empty boards stay separate',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic> game(String id, int? date) => {
        'match_id': id,
        'revision': 0,
        'sport': 'basketball',
        'phase': 'pre_game',
        'active': false,
        'archived': false,
        'created_at': 1234,
        'scheduled_at': date,
        'home': {'name': id, 'score': 0},
        'away': {'name': 'Guest', 'score': 0},
      };
      final boards = [
        {
          'slug': 'a',
          'created_at': 0,
          'active_match': null,
          'matches': [game('late', 3000), game('early', 1000)],
        },
        {
          'slug': 'b',
          'created_at': 99999,
          'active_match': null,
          'matches': [game('undated', null), game('middle', 2000)],
        },
        {
          'slug': 'empty-board',
          'created_at': 88888,
          'active_match': null,
          'matches': [],
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Dashboard(
                api: (_, method, body) async => {'boards': boards},
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
      expect(find.text('games.planned (4)'), findsOneWidget);
      expect(find.text('dashboard.empty_boards (1)'), findsOneWidget);
      expect(find.text('empty-board'), findsNothing);
      final order = ['early', 'middle', 'late', 'undated']
          .map((id) => tester.getTopLeft(find.byKey(ValueKey('match:$id'))).dy)
          .toList();
      expect(
        order[0] < order[1] && order[1] < order[2] && order[2] < order[3],
        isTrue,
      );
      expect(find.text('scheduled: game.unscheduled'), findsOneWidget);
      expect(find.textContaining('created: '), findsNWidgets(4));
      await tester.tap(find.text('dashboard.empty_boards (1)'));
      await tester.pumpAndSettle();
      expect(find.text('empty-board'), findsOneWidget);
      expect(find.text('games.planned (4)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
