import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/input_dialog.dart';
import 'package:score67_control/squad.dart';

void main() {
  for (final squad in [false, true]) {
    testWidgets('keyboard leaves ${squad ? "players" : "settings"} reachable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => squad
                      ? SquadDialog(
                          teamName: 'Home',
                          players: const [],
                          t: (key) => key,
                        )
                      : InputDialog(
                          title: const Text('Settings'),
                          scrollable: true,
                          content: Column(
                            children: List.generate(
                              8,
                              (i) => TextField(
                                decoration: InputDecoration(
                                  labelText: 'Field $i',
                                ),
                              ),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {},
                              child: const Text('save'),
                            ),
                          ],
                        ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '7');
      tester.view.viewInsets = const FakeViewPadding(bottom: 500);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getBottomLeft(find.text('save')).dy, lessThan(344));
      await tester.ensureVisible(find.byType(TextField).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Alex');
      expect(find.text('Alex'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
