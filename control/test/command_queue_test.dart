import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/command_queue.dart';

Map<String, dynamic> server() => {
  'match_id': 'm1',
  'revision': 7,
  'period': 2,
  'foul_mode': 'both',
  'home': {
    'score': 5,
    'period_scores': [3, 2],
    'counters': {'team_fouls': 1, 'timeouts': 0},
    'personal_fouls': [
      {'id': 'p7', 'fouls': 1},
    ],
    'statistics': {
      'players': [
        {'id': null, 'pts': 3, 'pf': 0, 'reb': 0},
        {'id': 'p7', 'pts': 2, 'pf': 1, 'reb': 0},
      ],
      'totals': {'pts': 5, 'pf': 1, 'reb': 0},
    },
  },
  'away': {
    'score': 0,
    'period_scores': [0, 0],
    'counters': {'team_fouls': 0, 'timeouts': 0},
  },
  'events': [
    {
      'id': 11,
      'type': 'score',
      'team': 'home',
      'points': 2,
      'period': 1,
      'player': {'id': 'p7'},
      'cancelled': false,
    },
  ],
};

Map<String, dynamic> queued(String action, Map<String, dynamic> data) => {
  'command_id': action,
  'match_id': 'm1',
  'action': action,
  'data': data,
};

void main() {
  test('tallies are shown before confirmation; server state is untouched', () {
    final original = server();
    final shown = optimisticState(original, [
      queued('score', {'team': 'home', 'player_id': 'p7', 'points': 3}),
      queued('personal_foul', {'team': 'home', 'player_id': 'p7'}),
      queued('rebound', {'team': 'home', 'player_id': null}),
      queued('timeout', {'team': 'away'}),
    ]);
    final home = shown['home'];
    expect(home['score'], 8);
    expect(home['period_scores'], [3, 5]);
    expect(home['counters']['team_fouls'], 2);
    expect(home['personal_fouls'][0]['fouls'], 2);
    expect(home['statistics']['players'][1]['pts'], 5);
    expect(home['statistics']['players'][1]['pf'], 2);
    expect(home['statistics']['players'][0]['reb'], 1);
    expect(home['statistics']['totals'], {'pts': 8, 'pf': 2, 'reb': 1});
    expect(shown['away']['counters']['timeouts'], 1);
    expect(original['home']['score'], 5);
  });

  test('a queued correction removes its target basket exactly once', () {
    final correction = queued('score_correction', {
      'team': 'home',
      'event_id': 11,
    });
    final shown = optimisticState(server(), [correction, correction]);
    expect(shown['home']['score'], 3);
    expect(shown['home']['period_scores'], [1, 2]);
    expect(shown['home']['statistics']['players'][1]['pts'], 0);
    expect(shown['events'][0]['corrected'], true);
  });

  test('only tallies for the current match are queued or shown', () {
    expect(queueable('score'), isTrue);
    expect(queueable('personal_foul_correction'), isTrue);
    expect(queueable('clock_start'), isFalse);
    expect(queueable('period_end'), isFalse);
    expect(queueable('undo'), isFalse);
    final other = {
      ...queued('score', {'team': 'home', 'points': 2}),
      'match_id': 'old',
    };
    expect(identical(optimisticState(server(), [other])['home'], null), false);
    expect(optimisticState(server(), [other])['home']['score'], 5);
  });

  test('player technicals count as fouls; coach technicals do not', () {
    final shown = optimisticState(server(), [
      queued('technical_foul', {'team': 'home', 'player_id': 'p7'}),
      queued('technical_foul', {'team': 'home'}),
    ]);
    expect(shown['home']['statistics']['players'][1]['pf'], 2);
    expect(shown['home']['statistics']['players'][0]['pf'], 0);
    expect(shown['home']['counters']['team_fouls'], 2);
  });

  test('lineup taps are shown at once and build on each other', () {
    expect(queueable('lineup'), isTrue);
    final shown = optimisticState(server(), [
      {
        'match_id': 'm1',
        'action': 'lineup',
        'data': {
          'team': 'home',
          'player_ids': ['p7'],
        },
      },
      {
        'match_id': 'm1',
        'action': 'lineup',
        'data': {
          'team': 'home',
          'player_ids': ['p7', 'p9'],
        },
      },
    ]);
    expect(shown['home']['on_court'], ['p7', 'p9']);
    expect(shown['away']['on_court'], isNull);
    expect(shown['home']['score'], 5);
  });

  test('a command the server already recorded is not shown twice', () {
    final recorded = server();
    (recorded['events'] as List).add({
      'id': 12,
      'command_id': 'c1',
      'type': 'score',
      'team': 'home',
      'points': 2,
      'cancelled': false,
    });
    final shown = optimisticState(recorded, [
      {
        'command_id': 'c1',
        'match_id': 'm1',
        'action': 'score',
        'data': {'team': 'home', 'points': 2},
      },
      {
        'command_id': 'c2',
        'match_id': 'm1',
        'action': 'score',
        'data': {'team': 'home', 'points': 1},
      },
    ]);
    expect(shown['home']['score'], 6);
  });

  test('clock taps behind queued entries show at once', () {
    expect(queueable('clock_stop'), isFalse); // not replayed after a reload
    expect(tappable('clock_stop'), isTrue);
    expect(tappable('period_end'), isFalse);
    final running = {
      ...server(),
      'clock': {'elapsed_ms': 1000, 'running': true, 'started_at': 50000},
    };
    final stop = {
      'command_id': 's',
      'match_id': 'm1',
      'action': 'clock_stop',
      'data': {'elapsed_ms': 7000},
    };
    final stopped = optimisticState(running, [stop]);
    expect(stopped['clock'], {
      'elapsed_ms': 7000,
      'running': false,
      'started_at': null,
    });
    final restarted = optimisticState(running, [
      stop,
      {
        'command_id': 'g',
        'match_id': 'm1',
        'action': 'clock_start',
        'data': {},
        'at': 90000,
      },
    ]);
    expect(restarted['clock'], {
      'elapsed_ms': 7000,
      'running': true,
      'started_at': 90000,
    });
    expect(running['clock']!['running'], isTrue); // server state untouched
  });

  group('CommandPump', () {
    late List<Map<String, dynamic>> queue;
    late List<String> sent, log;
    late int revision;
    late Future<Map<String, dynamic>> Function(Map<String, dynamic>) send;
    late CommandPump pump;
    Map<String, dynamic> tap(String id) => {
      'command_id': id,
      'action': 'score',
    };

    setUp(() {
      queue = [];
      sent = [];
      log = [];
      revision = 7;
      pump = CommandPump(
        queue: queue,
        revision: () => revision,
        send: (item) {
          sent.add('${item['command_id']}@${item['expected_revision']}');
          return send(item);
        },
        // Fresh state takes a moment; taps and pushes arrive meanwhile.
        fresh: () async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          unawaited(pump.run());
          revision = 9;
          log.add('fresh');
        },
        applied: (item, result) {
          revision++;
          log.add('ok ${item['command_id']}');
          unawaited(pump.run()); // accept() pokes the pump as well
        },
        rejected: (item, code) => log.add('no ${item['command_id']} $code'),
        changed: () {},
        offline: () => log.add('offline'),
        idle: () {},
        alive: () => true,
      );
    });

    test(
      'a refused tap costs only itself, the rest go once and in order',
      () async {
        send = (item) async {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          if (item['command_id'] == 'x') throw CommandRejected('state_changed');
          return {};
        };
        queue.addAll([tap('x'), tap('y'), tap('z'), tap('w')]);
        unawaited(pump.run());
        unawaited(pump.run());
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(sent, ['x@7', 'y@9', 'z@10', 'w@11']);
        expect(log, ['no x state_changed', 'fresh', 'ok y', 'ok z', 'ok w']);
        expect(queue, isEmpty);
        expect(pump.sending, isFalse);
      },
    );

    test('no answer: the same command is retried unchanged', () async {
      var failures = 2;
      send = (item) async {
        if (failures-- > 0) throw Exception('timeout');
        return {};
      };
      pump.retryMs = 1;
      queue.addAll([tap('a'), tap('b')]);
      await pump.run();
      expect(queue.length, 2);
      revision = 8; // someone else scored meanwhile
      pump.retryMs = 1;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      pump.retryTimer?.cancel();
      await pump.run();
      expect(sent.take(3), ['a@7', 'a@7', 'a@7']);
      expect(sent.last, startsWith('b@'));
      expect(log.where((l) => l == 'offline').length, 2);
      expect(queue, isEmpty);
    });
  });
}
