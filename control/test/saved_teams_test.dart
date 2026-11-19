import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/saved_teams.dart';

void main() {
  testWidgets('saved teams are listed, edited by id, created and deleted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <String>[];
    var teams = <Map<String, dynamic>>[
      {
        'id': 't1',
        'sport': 'basketball',
        'name': 'BSV U14',
        'short': 'BSV',
        'color': '#c8102e',
        'players': [
          {'number': '11', 'name': 'Luke'},
        ],
      },
    ];
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SavedTeamsPage(
            t: (key) => key,
            sport: 'basketball',
            onClose: () => closed = true,
            api: (path, method, body) async {
              if (method == 'GET') return {'teams': teams};
              if (method == 'DELETE') {
                calls.add('DELETE $path');
                teams = [];
                return {'ok': true};
              }
              calls.add(
                'POST ${body!['id']} ${body['name']} ${body['short']} ${(body['players'] as List).map((p) => '${p['number']}:${p['name']}').join(',')}',
              );
              final saved = {...body, 'id': body['id'] ?? 't2'};
              teams = [
                for (final team in teams)
                  if (team['id'] != saved['id']) team,
                saved,
              ];
              return saved;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('teams.pick'), findsOneWidget);
    await tester.tap(find.text('BSV U14'));
    await tester.pump();
    // Rename and add a player in the empty last row.
    await tester.enterText(find.byKey(const ValueKey('team-name')), 'BSV U16');
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(4), '7');
    await tester.enterText(fields.at(5), 'Frido');
    await tester.pump();
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(calls, ['POST t1 BSV U16 BSV 11:Luke,7:Frido']);
    expect(find.text('BSV U16'), findsWidgets);
    // A new team without a short name gets the first letters.
    await tester.tap(find.text('teams.new'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('team-name')), 'Towers');
    await tester.pump();
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(calls.last, 'POST null Towers TOW ');
    // Delete needs a second tap instead of a dialog.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(calls.length, 2);
    await tester.tap(find.text('teams.delete_confirm'));
    await tester.pumpAndSettle();
    expect(calls.last, 'DELETE /api/teams/t2');
    expect(find.byType(Dialog), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(closed, isTrue);
  });
}
