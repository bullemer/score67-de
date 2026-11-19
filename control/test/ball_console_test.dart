import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/ball_console.dart';
import 'package:score67_control/match_console.dart';

Map<String, dynamic> game({String? ball, bool clock = true}) => {
  'sport': 'basketball',
  'phase': 'period_running',
  'period': 2,
  'period_count': 8,
  'period_length_min': 10,
  'foul_mode': 'both',
  'possession': ball,
  'clock': {'enabled': true, 'running': clock},
  'events': <dynamic>[],
  for (final (side, short, numbers) in [
    ('home', 'BSV', ['11', '33']),
    ('away', 'TOW', ['5', '12']),
  ])
    side: {
      'short': short,
      'color': side == 'home' ? '#c8102e' : '#1d4ed8',
      'score': 8,
      'counters': {'team_fouls': 0},
      'on_court': <String>[],
      'squad': [
        for (final n in numbers) {'id': '$side$n', 'number': n, 'name': ''},
      ],
    },
};

void main() {
  late List<String> log;

  Future<void> mount(WidgetTester tester, Map<String, dynamic> state) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final running = state['clock']['running'] == true;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: BallConsole(
            onAddPlayer: (team) => log.add('add $team'),
            onAdjustClock: (seconds) => log.add('adjust $seconds'),
            log: const Text('BSV  Q2 08:45  2 PTS  #11'),
            base: MatchConsole(
              state: state,
              t: (key) => key,
              clock: '08:45',
              period: 'P2/8',
              running: running,
              onStartNext: () async => true,
              onStartClock: () async {
                log.add('clock_start');
                return true;
              },
              onToggleActive: (team, id) => log.add('court $team $id'),
              lineupMax: 5,
              canToggleClock: true,
              canTap: true,
              canWrite: true,
              connected: true,
              sync: const SizedBox(),
              onMenu: (_) {},
              onToggleClock: () => log.add('toggle'),
              onClockTap: () {},
              onUndo: () => log.add('undo'),
              onSubstitutions: (_) {},
              onAction: (action, team, player) =>
                  log.add('$action $team $player'),
              onPossession: (team) => log.add('ball $team'),
              onEditTeam: (_) {},
              onEditPlayer: (_, _) {},
              onScoreTap: (_) {},
              tabs: const [('Feed', SizedBox()), ('Teams', SizedBox())],
            ),
          ),
        ),
      ),
    );
  }

  setUp(() => log = []);

  testWidgets('shows the players of the team with the ball', (tester) async {
    await mount(tester, game(ball: 'away'));
    expect(find.text('5'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('11'), findsNothing);
    // The game flow has its own column and is no longer a tab.
    expect(find.textContaining('2 PTS'), findsOneWidget);
    expect(find.text('console.flow'), findsOneWidget);
    expect(find.text('Feed'), findsNothing);
    expect(find.text('Teams'), findsOneWidget);
  });

  testWidgets('action then player, or player then action', (tester) async {
    await mount(tester, game(ball: 'home'));
    await tester.tap(find.text('ball.made2'));
    await tester.pump();
    await tester.tap(find.text('11'));
    await tester.pump();
    await tester.tap(find.text('33'));
    await tester.pump();
    await tester.tap(find.text('ball.miss3'));
    await tester.pump();
    expect(log, ['2pt home home11', 'miss3 home home33']);
    // Nothing stays armed: a further player tap only selects.
    await tester.tap(find.text('11'));
    await tester.pump();
    expect(log.length, 2);
  });

  testWidgets('giving the ball starts a stopped clock, also to the same team', (
    tester,
  ) async {
    await mount(tester, game(ball: 'home', clock: false));
    await tester.tap(find.bySemanticsLabel('possession'));
    await tester.pump();
    expect(log, ['ball away', 'clock_start']);
    log.clear();
    await tester.tap(find.text('BSV').first); // inbound by the same team
    await tester.pump();
    expect(log, ['clock_start']);
  });

  testWidgets('a running clock is left alone when the ball changes', (
    tester,
  ) async {
    await mount(tester, game(ball: 'home'));
    await tester.tap(find.bySemanticsLabel('possession'));
    await tester.pump();
    expect(log, ['ball away']);
    await tester.tap(find.text('basketball.stop'));
    expect(log.last, 'toggle');
  });

  testWidgets('fouls and rebounds offer the defending team first', (
    tester,
  ) async {
    await mount(tester, game(ball: 'home'));
    await tester.tap(find.text('console.foul'));
    await tester.pump();
    expect(find.text('5'), findsOneWidget); // TOW defends
    await tester.tap(find.text('5'));
    await tester.pump();
    expect(log, ['foul away away5']);
    expect(find.text('11'), findsOneWidget); // back to the team with the ball
    // A defensive rebound hands the ball over; an offensive one does not.
    await tester.tap(find.text('console.reb'));
    await tester.pump();
    await tester.tap(find.text('12'));
    await tester.pump();
    expect(log.sublist(1), ['reb away away12', 'ball away']);
  });

  testWidgets(
    'bar and action buttons wear the colour of the team with the ball',
    (tester) async {
      Color bar() =>
          (tester
                      .widget<AnimatedContainer>(
                        find.byKey(const ValueKey('ball-header')),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      Color button(String id) => tester
          .widget<Material>(find.byKey(ValueKey('ball-action-$id')))
          .color!;
      await mount(tester, game(ball: 'away'));
      expect(bar(), const Color(0xff1d4ed8));
      expect(button('2pt'), const Color(0xff1d4ed8));
      await tester.tap(find.text('ball.made2'));
      await tester.pump();
      expect(button('2pt'), Colors.white); // armed
      expect(button('3pt'), const Color(0xff1d4ed8));
      await tester.tap(find.text('ball.made2')); // disarm
      await tester.pump();
      await mount(tester, game(ball: 'home'));
      await tester.pumpAndSettle();
      expect(bar(), const Color(0xffc8102e));
      // Not started or in a break: neutral.
      await mount(tester, {...game(ball: 'home'), 'phase': 'break'});
      await tester.pumpAndSettle();
      expect(bar(), const Color(0xff111827));
      expect(button('2pt'), const Color(0xff1f2937));
    },
  );

  testWidgets('2 and 3 points are on top and larger than the rest', (
    tester,
  ) async {
    await mount(tester, game(ball: 'home'));
    Rect box(String id) =>
        tester.getRect(find.byKey(ValueKey('ball-action-$id')));
    expect(box('2pt').top, lessThan(box('3pt').top));
    expect(box('3pt').top, lessThan(box('ft_hit').top));
    for (final big in ['2pt', '3pt']) {
      expect(box(big).height, greaterThan(box('ft_hit').height));
    }
    // Every points button is wider than its miss button.
    for (final (made, miss) in [
      ('2pt', 'miss2'),
      ('3pt', 'miss3'),
      ('ft_hit', 'ft_miss'),
    ]) {
      expect(box(made).width, greaterThan(box(miss).width));
    }
    // The bar spans the screen; log header and tab row are equally tall.
    expect(
      tester.getSize(find.byKey(const ValueKey('ball-header'))).width,
      844,
    );
  });

  testWidgets('the clock is corrected on screen, without a dialog', (
    tester,
  ) async {
    await mount(tester, game(ball: 'home'));
    String preview() =>
        tester.widget<Text>(find.byKey(const ValueKey('clock-preview'))).data!;
    await tester.tap(find.text('08:45'));
    await tester.pump();
    expect(preview(), '08:45');
    await tester.tap(find.byKey(const ValueKey('clock-step-10')));
    await tester.tap(find.byKey(const ValueKey('clock-step-10')));
    await tester.tap(find.byKey(const ValueKey('clock-step--1')));
    await tester.pump();
    expect(preview(), '09:04');
    await tester.tap(find.text('save'));
    await tester.pump();
    expect(log, ['adjust 19']);
    expect(find.byKey(const ValueKey('clock-preview')), findsNothing);
    // Never beyond the period (here 10 minutes) and never below zero.
    await tester.tap(find.text('08:45'));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('clock-step-60')));
    }
    await tester.pump();
    expect(preview(), '10:00');
    await tester.tap(find.text('cancel'));
    await tester.pump();
    expect(log.length, 1);
  });

  testWidgets('team card, add player and long press on court', (tester) async {
    await mount(tester, game(ball: 'home'));
    await tester.tap(find.text('console.timeout'));
    await tester.pump();
    await tester.tap(find.text('ball.team'));
    await tester.pump();
    await tester.longPress(find.text('33'));
    await tester.pump();
    await tester.tap(find.text('ball.add_player'));
    await tester.tap(find.text('ball.undo'));
    expect(log, ['timeout home null', 'court home home33', 'add home', 'undo']);
  });
}
