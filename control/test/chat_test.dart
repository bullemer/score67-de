import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/chat.dart';

void main() {
  testWidgets('controller reads, sends and moderates shared chat', (
    tester,
  ) async {
    var messages = <Map<String, dynamic>>[
      {'id': 'one', 'name': 'Fan', 'text': 'Hello', 'controller': false},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameChat(
            slug: 'board',
            t: (key) => key,
            api: (path, method, body) async {
              if (method == 'POST') {
                expect(path, '/api/s/board/chat');
                expect(body!['text'], 'Welcome');
                messages = [
                  ...messages,
                  {
                    'id': 'two',
                    'name': body['name'],
                    'text': body['text'],
                    'controller': true,
                  },
                ];
              }
              if (method == 'DELETE') {
                expect(path, '/api/s/board/chat/one');
                messages = messages.where((m) => m['id'] != 'one').toList();
              }
              return {'messages': messages};
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Welcome');
    await tester.tap(find.byTooltip('chat.send'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('control · control'), findsOneWidget);
    await tester.tap(find.byTooltip('chat.delete').first);
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
