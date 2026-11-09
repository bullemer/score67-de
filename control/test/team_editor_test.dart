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

  Future<List<List<dynamic>>> mount(
    WidgetTester tester,
    List<Map<String, dynamic>> squad, {
    bool accept = true,
  }) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = <List<dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamEditor(
            state: board('basketball', squad),
            t: (key) => key,
            enabled: true,
            onSave: (team, players, onCourt) async {
              saved.add([team, players, onCourt]);
              return accept;
            },
          ),
        ),
      ),
    );
    return saved;
  }

  testWidgets('entries save themselves without pressing save', (tester) async {
    final saved = await mount(tester, []);
    await tester.enterText(find.byType(TextField).at(0), '7');
    await tester.pump(const Duration(seconds: 1));
    final players = saved.single[1] as List;
    expect(players.single['number'], '7');
  });

  testWidgets('a repeated number is flagged, never saved, and removed', (
    tester,
  ) async {
    final saved = await mount(tester, [
      {'id': 'a', 'number': '7', 'name': ''},
    ]);
    await tester.enterText(find.byType(TextField).at(2), '07');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('error.duplicate_player'), findsOneWidget);
    expect(saved, isEmpty);
    // Leaving the row takes the duplicate out again.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('07'), findsNothing);
    expect(find.text('7'), findsOneWidget);
    for (final call in saved) {
      expect((call[1] as List).length, 1);
    }
  });

  testWidgets('rows sort by number when the row is left', (tester) async {
    final saved = await mount(tester, [
      {'id': 'a', 'number': '4', 'name': ''},
      {'id': 'b', 'number': '12', 'name': ''},
    ], accept: false);
    await tester.enterText(find.byType(TextField).at(4), '9');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(seconds: 2));
    String numberAt(int i) =>
        tester.widget<TextField>(find.byType(TextField).at(i)).controller!.text;
    expect([numberAt(0), numberAt(2), numberAt(4)], ['4', '9', '12']);
    final players = saved.last[1] as List;
    expect(players.map((p) => p['number']), ['4', '9', '12']);
  });

  testWidgets('leaving the tab still saves what was typed', (tester) async {
    final saved = await mount(tester, []);
    await tester.enterText(find.byType(TextField).at(0), '23');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    final players = saved.single[1] as List;
    expect(players.single['number'], '23');
  });

  testWidgets('next on the keyboard goes to the empty row', (tester) async {
    await mount(tester, [
      {'id': 'a', 'number': '4', 'name': ''},
    ]);
    await tester.showKeyboard(find.byType(TextField).at(2));
    tester.testTextInput.enterText('9');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump(const Duration(seconds: 1));
    final last = tester.widget<TextField>(find.byType(TextField).at(4));
    expect(last.focusNode!.hasFocus, isTrue);
  });
}
