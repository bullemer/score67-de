import 'dart:convert';

/// Tally actions may be queued while offline and are shown before the server
/// confirms them. Everything else (clock, periods, settings, undo) needs a
/// confirmed, empty queue because its effect depends on the exact server state.
const tallyActions = {
  'score',
  'personal_foul',
  'team_foul',
  'timeout',
  'red_card',
  'yellow_card',
  'rebound',
  'assist',
  'steal',
  'block',
  'turnover',
};

bool queueable(String action) =>
    tallyActions.contains(action.replaceFirst(RegExp(r'_correction$'), '')) ||
    action == 'assign_player';

const _statColumns = {
  'score': 'pts',
  'rebound': 'reb',
  'assist': 'ast',
  'steal': 'stl',
  'block': 'blk',
  'turnover': 'to',
  'personal_foul': 'pf',
};

/// Server state plus the visible effect of unconfirmed tally commands.
Map<String, dynamic> optimisticState(
  Map<String, dynamic> server,
  List<Map<String, dynamic>> queue,
) {
  final pending = queue
      .where(
        (c) => c['match_id'] == server['match_id'] && queueable(c['action']),
      )
      .toList();
  if (pending.isEmpty || server['match_id'] == null) return server;
  final s = jsonDecode(jsonEncode(server)) as Map<String, dynamic>;
  final events = (s['events'] as List? ?? []).cast<Map<String, dynamic>>();
  for (final command in pending) {
    final action = command['action'] as String;
    final data = Map<String, dynamic>.from(command['data'] ?? {});
    final team = data['team'];
    if (team != 'home' && team != 'away') continue;
    final correcting = action.endsWith('_correction');
    final kind = action.replaceFirst(RegExp(r'_correction$'), '');
    if (!tallyActions.contains(kind)) continue;
    Map<String, dynamic>? target;
    if (correcting) {
      final candidates = events.where(
        (e) =>
            e['type'] == kind &&
            e['team'] == team &&
            e['cancelled'] == false &&
            e['corrected'] != true,
      );
      target = data['event_id'] == null
          ? candidates.lastOrNull
          : candidates.where((e) => e['id'] == data['event_id']).firstOrNull;
      if (target == null) continue;
      target['corrected'] = true;
    }
    final sign = correcting ? -1 : 1;
    final player = correcting ? target!['player'] as Map? : null;
    final playerId = correcting
        ? (player == null ? null : player['id'])
        : data['player_id'];
    final side = s[team] as Map<String, dynamic>;
    final counters = (side['counters'] ??= <String, dynamic>{}) as Map;
    if (kind == 'score') {
      final points = correcting
          ? (target!['points'] as num).toInt()
          : (data['points'] as num).toInt();
      side['score'] = (side['score'] as num) + sign * points;
      final periods = side['period_scores'] as List?;
      final period = correcting ? target!['period'] : s['period'];
      if (periods != null && periods.isNotEmpty) {
        final index = ((period as num).toInt().clamp(1, periods.length)) - 1;
        periods[index] = (periods[index] as num) + sign * points;
      }
      _addStat(side, playerId, 'pts', sign * points);
    } else if (kind == 'red_card' || kind == 'yellow_card') {
      counters['${kind}s'] = ((counters['${kind}s'] ?? 0) as num) + sign;
    } else if (kind == 'team_foul' || kind == 'timeout') {
      final key = kind == 'team_foul' ? 'team_fouls' : 'timeouts';
      counters[key] = ((counters[key] ?? 0) as num) + sign;
    } else {
      _addStat(side, playerId, _statColumns[kind]!, sign);
      if (kind == 'personal_foul') {
        final countsTeam = correcting
            ? target!['counts_team'] == true
            : s['foul_mode'] == 'both';
        if (countsTeam) {
          counters['team_fouls'] =
              ((counters['team_fouls'] ?? 0) as num) + sign;
        }
        for (final player in side['personal_fouls'] as List? ?? []) {
          if (player['id'] == playerId && playerId != null) {
            player['fouls'] = (player['fouls'] as num) + sign;
          }
        }
      }
    }
  }
  return s;
}

void _addStat(
  Map<String, dynamic> side,
  dynamic playerId,
  String column,
  int delta,
) {
  final statistics = side['statistics'] as Map?;
  if (statistics == null) return;
  final row = (statistics['players'] as List? ?? [])
      .where((p) => p['id'] == playerId)
      .firstOrNull;
  if (row == null) return;
  row[column] = ((row[column] ?? 0) as num) + delta;
  final totals = statistics['totals'] as Map?;
  if (totals != null) totals[column] = ((totals[column] ?? 0) as num) + delta;
}
