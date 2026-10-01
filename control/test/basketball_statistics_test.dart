import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/basketball_statistics.dart';

void main() {
  testWidgets('compact scoring, correction mode, clock and offline controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <List<dynamic>>[];
    Map<String, dynamic> row(String? id) => {
      'id': id,
      'number': id == null ? '' : '7',
      'name': '',
      'in_squad': id != null,
      'pts': 3,
      'reb': 1,
      'pf': 0,
      'ast': 4,
      'stl': 1,
      'blk': 0,
      'to': 1,
    };
    Future<void> render({
      bool enabled = true,
      bool scoring = true,
      bool correcting = false,
      Map<String, dynamic>? statistics,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BasketballStatistics(
              statistics:
                  statistics ??
                  {
                    'players': [row(null), row('alex')],
                    'totals': {'pts': 6, 'reb': 2},
                  },
              t: (key) => key,
              enabled: enabled,
              scoringEnabled: scoring,
              personalFoulsEnabled: true,
              correcting: correcting,
              canRemoveScore: (id, points) => id == 'alex' && points == 3,
              score: (id, points, subtract) async {
                calls.add(['score', id, points, subtract]);
                return true;
              },
              record: (kind, id, subtract) async {
                calls.add([kind, id, subtract]);
                return true;
              },
            ),
          ),
        ),
      );
    }

    await render();
    for (final label in ['PTS', 'REB', 'PF']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['AST', 'STL', 'BLK', 'TO']) {
      expect(find.text(label), findsNothing);
    }
    expect(
      tester.getCenter(find.text('#7')).dy -
          tester.getCenter(find.text('stats.team_row')).dy,
      BasketballStatistics.rowHeight,
    );
    // Two teams fit side by side on a landscape phone (iPhone SE: 667 px).
    expect(2 * BasketballStatistics.width + 24 + 16, lessThanOrEqualTo(667));
    await tester.tap(find.byTooltip('+ rebound · stats.team_row'));
    await tester.tap(find.byTooltip('+3 · #7'));
    await tester.tap(find.byTooltip('+ personal_foul · #7'));
    expect(calls, [
      ['rebound', null, false],
      ['score', 'alex', 3, false],
      ['personal_foul', 'alex', false],
    ]);
    await render(correcting: true);
    await tester.tap(find.byTooltip('− rebound · #7'));
    await tester.tap(find.byTooltip('stats.remove_basket 3 · #7'));
    expect(calls.last, ['score', 'alex', 3, true]);
    await tester.tap(find.byTooltip('stats.remove_basket 2 · #7'));
    await tester.tap(find.byTooltip('− personal_foul · #7'));
    expect(calls.length, 5);
    await render(scoring: false);
    await tester.tap(find.byTooltip('+3 · #7'));
    expect(calls.length, 5);
    await render(
      statistics: {
        'players': [
          {...row('alex'), 'pf': 5},
        ],
      },
    );
    final fouledOut = tester.widget<Text>(find.text('#7'));
    expect(fouledOut.style?.decoration, TextDecoration.lineThrough);
    await render(enabled: false);
    await tester.tap(find.byTooltip('+ rebound · #7'));
    expect(calls.length, 5);
    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsNothing);
  });
}
