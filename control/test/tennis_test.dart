import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/tennis.dart';

Map<String, dynamic> game(String mode, {bool tiebreak = false}) => {
  'phase': 'period_running',
  'home': {'name': 'Alex'},
  'away': {'name': 'Sam'},
  'tennis': {
    'category': 'women',
    'best_of': 3,
    'mode': mode,
    'sets': [0, 0],
    'games': tiebreak ? [6, 6] : [0, 0],
    'point_labels': tiebreak ? ['6', '6'] : ['40', 'AD'],
    'server': 0,
    'tiebreak': tiebreak,
    'winner': null,
    'set_scores': [],
  },
};

void main() {
  for (final mode in ['simple', 'detailed']) {
    testWidgets(
      '$mode tennis works in portrait and sends the right scoring action',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final actions = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TennisScorePanel(
                state: game(mode),
                t: (key) => key,
                enabled: true,
                command: (a, d) async {
                  actions.add('$a:${d['team']}');
                  return true;
                },
              ),
            ),
          ),
        );
        await tester.tap(
          find
              .text(mode == 'simple' ? 'tennis.add_game' : 'tennis.add_point')
              .first,
        );
        expect(actions, [
          mode == 'simple' ? 'tennis_game:home' : 'tennis_point:home',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('simple mode changes to point scoring during a tie-break', (
    tester,
  ) async {
    String? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TennisScorePanel(
            state: game('simple', tiebreak: true),
            t: (key) => key,
            enabled: true,
            command: (a, d) async {
              action = a;
              return true;
            },
          ),
        ),
      ),
    );
    expect(find.text('tennis.add_game'), findsNothing);
    await tester.tap(find.text('tennis.add_point').first);
    expect(action, 'tennis_point');
  });
  testWidgets('simple mode records a completed set result', (tester) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TennisScorePanel(
            state: game('simple'),
            t: (key) => key,
            enabled: true,
            command: (a, d) async {
              expect(a, 'tennis_set');
              result = d;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('tennis.enter_set'));
    await tester.tap(find.text('tennis.enter_set'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(result, {
      'games': [6, 0],
    });
  });
}
