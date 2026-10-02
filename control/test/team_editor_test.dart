import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/team_editor.dart';

Map<String, dynamic> board(String sport, List<Map<String, dynamic>> squad) => {
  'sport': sport,
  'home': {'short': 'TSV', 'squad': squad, 'on_court': <String>[]},
  'away': {
    'short': 'BCA',
    'squad': <Map<String, dynamic>>[],
    'on_court': <String>[],
  },
};

void main() {
  testWidgets('enter players, mark on court, limit and save', (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = <List<dynamic>>[];
    final squad = [
      for (var n = 4; n <= 9; n++) {'id': 'p$n', 'number': '$n', 'name': ''},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamEditor(
            state: board('basketball', squad),
            t: (key) => key,
            enabled: true,
            onSave: (team, players, onCourt) async {
              saved.add([team, players, onCourt]);
              return true;
            },
          ),
        ),
      ),
    );
    final boxes = find.byType(Checkbox);
    expect(boxes, findsNWidgets(7)); // six players + one empty entry row
    for (var i = 0; i < 6; i++) {
      await tester.tap(boxes.at(i));
      await tester.pump();
    }
    // The sixth tick is refused: five on court in basketball.
    expect(find.text('team.on_court 5/5'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(12), '23');
    await tester.enterText(find.byType(TextField).at(13), 'Kim');
    await tester.pump();
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    final [team, players, onCourt] = saved.single;
    expect(team, 'home');
    expect((players as List).length, 7);
    expect(players.last, containsPair('name', 'Kim'));
    expect(onCourt, ['p4', 'p5', 'p6', 'p7', 'p8']);
  });

  testWidgets('basketball needs a shirt number', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamEditor(
            state: board('basketball', []),
            t: (key) => key,
            enabled: true,
            onSave: (_, _, _) async {
              calls++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).at(1), 'No number');
    await tester.pump();
    await tester.tap(find.text('save'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('error.player_number_required'), findsOneWidget);
  });
}
