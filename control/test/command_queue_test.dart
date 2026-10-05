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
}
