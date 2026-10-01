import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/basketball_statistics.dart';

void main() {
  testWidgets('unknown and named stats, corrections and offline controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
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
      'ast': 0,
      'stl': 0,
      'blk': 0,
      'to': 0,
      'pf': 0,
    };
    final stats = {
      'players': [row(null), row('alex')],
      'totals': {'pts': 6, 'reb': 2},
    };
    Future<void> render({bool enabled = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BasketballStatistics(
              statistics: stats,
              t: (key) => key,
              enabled: enabled,
              personalFoulsEnabled: true,
              configureFouls: () {},
              record: (kind, id, correcting) async {
                calls.add([kind, id, correcting]);
                return true;
              },
            ),
          ),
        ),
      );
    }

    await render();
    expect(find.text('foul.unknown'), findsOneWidget);
    expect(find.text('#7'), findsOneWidget);
    for (final label in ['PTS', 'REB', 'AST', 'STL', 'BLK', 'TO', 'PF']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.byTooltip('+ rebound · foul.unknown'));
    await tester.tap(find.byTooltip('+ assist · #7'));
    expect(calls, [
      ['rebound', null, false],
      ['assist', 'alex', false],
    ]);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('− rebound · #7'));
    expect(calls.last, ['rebound', 'alex', true]);
    await tester.tap(find.byTooltip('− assist · #7'));
    expect(calls.length, 3);
    await render(enabled: false);
    await tester.tap(find.byTooltip('− rebound · #7'));
    expect(calls.length, 3);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(360, 900);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
