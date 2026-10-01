import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/squad.dart';

void main() {
  testWidgets('enter creates next player and save ignores blank trailing row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showDialog<List<Map<String, dynamic>>>(
                  context: context,
                  builder: (_) => SquadDialog(
                    teamName: 'Home',
                    requireNumber: true,
                    players: const [],
                    t: (key) => key,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    Finder numbers() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'player.number',
    );
    expect(numbers(), findsOneWidget);
    expect(
      tester.widget<TextField>(numbers().first).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(numbers().first, '7');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(numbers(), findsNWidgets(2));
    expect(
      tester.widget<TextField>(numbers().last).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(numbers().last, '12');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(saved!.map((p) => p['number']).toList(), ['7', '12']);
    expect(saved!.every((p) => p['name'] == ''), isTrue);
  });

  testWidgets(
    'paste imports numbers and names with atomic duplicate validation',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<List<Map<String, dynamic>>>(
                    context: context,
                    builder: (_) => SquadDialog(
                      teamName: 'Home',
                      requireNumber: true,
                      players: const [],
                      t: (key) => key,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('squad.paste'));
      await tester.pumpAndSettle();
      final input = find.byWidgetPredicate(
        (w) => w is TextField && w.maxLines == 3,
      );
      await tester.enterText(input, '7 Alex\n07 Duplicate');
      await tester.ensureVisible(find.text('squad.import'));
      await tester.tap(find.text('squad.import'));
      await tester.pumpAndSettle();
      expect(find.text('error.duplicate_player'), findsOneWidget);
      await tester.enterText(input, '7 Alex\n12 Sam Smith\n23');
      await tester.ensureVisible(find.text('squad.import'));
      await tester.tap(find.text('squad.import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();
      expect(saved!.map((p) => p['number']).toList(), ['7', '12', '23']);
      expect(saved!.map((p) => p['name']).toList(), ['Alex', 'Sam Smith', '']);
    },
  );
}
