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
      if (method == 'POST') {
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
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(calls, contains('DELETE /api/s/game1/displays/panel1'));
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });
}
