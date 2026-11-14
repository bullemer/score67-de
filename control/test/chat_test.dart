import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/chat.dart';

void main() {
  test('relative timestamps cross unit boundaries and clamp future dates', () {
    String t(String key) => '$key {n}';
    expect(chatAge(0, -1000, t), 'chat.age.now {n}');
    expect(chatAge(0, 4000, t), 'chat.age.seconds 4');
    expect(chatAge(0, 59999, t), 'chat.age.seconds 59');
    expect(chatAge(0, 60000, t), 'chat.age.minutes 1');
    expect(chatAge(0, 3600000, t), 'chat.age.hours 1');
    expect(chatAge(0, 86400000, t), 'chat.age.day 1');
    expect(chatAge(0, 172800000, t), 'chat.age.days 2');
  });

  testWidgets('controller reads, sends and moderates shared chat', (
    tester,
  ) async {
    var messages = <Map<String, dynamic>>[
      {'id': 'one', 'text': 'Hello', 'controller': false, 'created_at': 16000},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameChat(
            slug: 'board',
            t: (key) => key == 'chat.age.seconds' ? '{n} sec ago' : key,
            api: (path, method, body) async {
              if (method == 'POST') {
                expect(path, '/api/s/board/chat');
                expect(body, {'text': 'Welcome'});
                messages = [
                  ...messages,
                  {
                    'id': 'two',
                    'text': body!['text'],
                    'created_at': 16000,
                    'controller': true,
                  },
                ];
              }
              if (method == 'DELETE') {
                expect(path, '/api/s/board/chat/one');
                messages = messages.where((m) => m['id'] != 'one').toList();
              }
              return {'messages': messages, 'server_now': 20000};
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('4 sec ago'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Welcome');
    await tester.tap(find.byTooltip('chat.send'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('4 sec ago · control'), findsOneWidget);
    await tester.tap(find.byTooltip('chat.delete').first);
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
