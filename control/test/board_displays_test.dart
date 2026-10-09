import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/board_displays.dart';

void main() {
  testWidgets('connects a panel by code and disconnects it from the game', (
    tester,
  ) async {
    bool managed = false;
    String? board;
    final calls = <String>[];

    Future<dynamic> api(
      String path,
      String method,
      Map<String, dynamic>? body,
    ) async {
      calls.add('$method $path');
      if (method == 'POST' && path.endsWith('/disconnect')) {
        expect(body, {'expected_board': 'game1', 'expected_match': 'match1'});
        board = null;
      } else if (method == 'POST') {
        expect(body, {'code': '123456'});
        managed = true;
        board = 'game1';
      } else if (method == 'DELETE') {
        board = null;
      }
      return {
        'displays': managed
            ? [
                {
                  'id': 'panel1',
                  'name': 'Hall board',
                  'managed': true,
                  'board': board,
                  'match_id': 'match1',
                  'match_label': 'Home – Guest',
                  'online': true,
                },
              ]
            : <Map<String, dynamic>>[],
      };
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BoardDisplaysPanel(
              api: api,
              t: (key) => key == 'ledlink.show_on' ? 'Show on {name}' : key,
              slug: 'game1',
              enabled: true,
              onSettings: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('ledlink.connect'));
    await tester.pumpAndSettle();

    expect(calls, contains('POST /api/s/game1/displays'));
    expect(find.text('Show on Hall board'), findsOneWidget);
    expect(find.text('ledlink.disconnect'), findsOneWidget);
    await tester.tap(find.text('ledlink.disconnect'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(calls, isNot(contains('POST /api/displays/panel1/disconnect')));
    await tester.tap(find.text('cancel'));
    await tester.pumpAndSettle();
    expect(board, 'game1');
    expect(calls, isNot(contains('POST /api/displays/panel1/disconnect')));

    await tester.tap(find.text('ledlink.disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('ledlink.disconnect'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      calls.where((v) => v == 'POST /api/displays/panel1/disconnect'),
      hasLength(1),
    );
    expect(board, isNull);
    expect(find.text('ledlink.disconnect'), findsNothing);
  });
}
