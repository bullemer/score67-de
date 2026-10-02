import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/led_frames.dart';

const state = {
  'phase': 'period_running',
  'home': {
    'short': 'TSV',
    'score': 87,
    'counters': {'team_fouls': 4},
  },
  'away': {
    'short': 'BCA',
    'score': 102,
    'counters': {'team_fouls': 2},
  },
};

void main() {
  test('64×32 shows score and time on two lines', () {
    final c = LedConfig(width: 64, height: 32, clockMode: 'second');
    expect((c.columns, c.rows), (10, 4));
    expect(ledLines(c, state, '05:31', 'Q2'), ['TSV 87-102', 'Q2 05:31']);
  });

  test('wide single-line panels fit everything', () {
    final c = LedConfig(width: 192, height: 16, clockMode: 'second');
    expect(ledLines(c, state, '05:31', 'Q2'), ['TSV 87:102 BCA', 'Q2 05:31']);
    final one = LedConfig(width: 96, height: 8, clockMode: 'second');
    expect(ledLines(one, state, '05:31', 'Q2'), ['87:102 05:31']);
  });

  test('tiny panels fall back to the bare score; content filters', () {
    final tiny = LedConfig(width: 32, height: 16);
    final lines = ledLines(tiny, state, '05:31', 'Q2');
    expect(lines.first, '87:102'); // never cut, flagged instead
    expect(ledOverflows(tiny, lines), isTrue);
    expect(ledOverflows(LedConfig(width: 128), ['TSV 87:102 BCA']), isFalse);
    expect(
      ledLines(
        LedConfig(width: 64, content: 'clock', clockMode: 'second'),
        state,
        '05:31',
        'Q2',
      ),
      ['Q2 05:31'],
    );
  });

  test('data driver sends one machine-readable line', () {
    final frame = ledFrame(
      LedConfig(driver: 'data', clockMode: 'second'),
      state,
      '05:31',
      'Q2',
    );
    expect(frame, 'S67;TSV;87;102;BCA;05:31;Q2;period_running;4;2\n');
  });

  testWidgets('preview renders at the configured aspect ratio', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 256,
            child: LedPreview(
              config: LedConfig(width: 128, height: 32),
              lines: const ['TSV 87:102 BCA', 'Q2 05:31'],
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(LedPreview)), const Size(256, 64));
    expect(find.text('Q2 05:31'), findsOneWidget);
  });

  test('minute mode shows whole minutes; none hides the time', () {
    final minute = LedConfig(width: 128, height: 32);
    expect(ledLines(minute, state, '05:31', 'Q2'), ['TSV 87:102 BCA', "Q2 5'"]);
    final none = LedConfig(width: 128, height: 32, clockMode: 'none');
    expect(ledLines(none, state, '05:31', 'Q2').last, 'Q2');
  });
}
