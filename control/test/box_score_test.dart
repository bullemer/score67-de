import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/box_score.dart';

Map<String, dynamic> p(String id, String number) => {
  'id': id,
  'number': number,
  'name': '',
};

void main() {
  test('basketball box score: points, free throws, minutes per period', () {
    var id = 0;
    Map<String, dynamic> e(String type, Map<String, dynamic> data) => {
      'id': ++id,
      'type': type,
      'cancelled': false,
      ...data,
    };
    final state = <String, dynamic>{
      'sport': 'basketball',
      'clock': {'enabled': true},
      'home': {
        'squad': [p('a', '4'), p('b', '5'), p('c', '6')],
      },
      'away': {'squad': []},
      'events': [
        e('lineup', {
          'team': 'home',
          'period': 0,
          'clock_ms': null,
          'entered': [p('a', '4'), p('b', '5')],
          'left': [],
        }),
        e('period_start', {'period': 1, 'clock_ms': 0}),
        e('score', {
          'team': 'home',
          'period': 1,
          'points': 2,
          'player': p('a', '4'),
        }),
        e('score', {
          'team': 'home',
          'period': 1,
          'points': 1,
          'detail': 'free_throw',
          'player': p('a', '4'),
        }),
        e('free_throw_missed', {
          'team': 'home',
          'period': 1,
          'player': p('a', '4'),
        }),
        e('score', {
          'team': 'home',
          'period': 1,
          'points': 3,
          'player': p('b', '5'),
          'corrected': true,
        }),
        e('lineup', {
          'team': 'home',
          'period': 1,
          'clock_ms': 120000,
          'entered': [p('c', '6')],
          'left': [p('b', '5')],
        }),
        e('period_end', {'period': 1, 'clock_ms': 300000}),
        e('period_start', {'period': 2, 'clock_ms': 0}),
        e('score', {
          'team': 'home',
          'period': 2,
          'points': 3,
          'player': p('c', '6'),
        }),
        e('rebound', {'team': 'home', 'period': 2, 'player': p('c', '6')}),
        e('personal_foul', {
          'team': 'home',
          'period': 2,
          'player': p('a', '4'),
        }),
        e('score', {
          'team': 'home',
          'period': 2,
          'points': 2,
          'cancelled': true,
          'player': p('a', '4'),
        }),
      ],
    };
    final all = boxScore(state, 'home', null, 60000);
    final a = all.players[0], b = all.players[1], c = all.players[2];
    expect([a.pts, a.ftm, a.fta, a.two, a.pf], [3, 1, 2, 1, 1]);
    expect(b.pts, 0, reason: 'a corrected basket does not count');
    expect([c.pts, c.three, c.reb], [3, 1, 1]);
    // a: 5:00 in period 1 + 1:00 of the running period 2; b: 2:00; c: 3:00 + 1:00.
    expect([a.ms, b.ms, c.ms], [360000, 120000, 240000]);
    expect(all.total.pts, 6);
    expect(all.minutes, isTrue);
    final second = boxScore(state, 'home', 2, 60000);
    expect(
      [second.players[0].ms, second.players[0].pts, second.players[2].pts],
      [60000, 0, 3],
    );
  });

  test('football box score: goals and cards, team row for unattributed', () {
    final state = <String, dynamic>{
      'sport': 'football',
      'clock': {'enabled': true},
      'home': {
        'squad': [p('x', '9')],
      },
      'away': {'squad': []},
      'events': [
        {
          'id': 1,
          'type': 'score',
          'team': 'home',
          'period': 1,
          'points': 1,
          'cancelled': false,
          'player': p('x', '9'),
        },
        {
          'id': 2,
          'type': 'score',
          'team': 'home',
          'period': 1,
          'points': 1,
          'cancelled': false,
        },
        {
          'id': 3,
          'type': 'yellow_card',
          'team': 'home',
          'period': 2,
          'cancelled': false,
          'player': p('x', '9'),
        },
      ],
    };
    final box = boxScore(state, 'home', null, 0);
    expect(
      [
        box.players[0].goals,
        box.players[0].yellow,
        box.team.goals,
        box.total.goals,
      ],
      [1, 1, 1, 2],
    );
    expect(box.minutes, isFalse, reason: 'no lineup was used');
  });
}
