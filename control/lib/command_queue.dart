import 'dart:async';
import 'dart:convert';

/// Tally actions may be queued while offline and are shown before the server
/// confirms them. Everything else (clock, periods, settings, undo) needs a
/// confirmed, empty queue because its effect depends on the exact server state.
const tallyActions = {
  'score',
  'personal_foul',
  'technical_foul',
  'team_foul',
  'timeout',
  'red_card',
  'yellow_card',
  'rebound',
  'assist',
  'steal',
  'block',
  'turnover',
  'free_throw_missed',
  'foul',
  'free_kick',
  'penalty',
};

/// Lineup changes (a player tapped on court / to the bench) are queued too:
/// each carries the whole lineup, so taps in quick succession build on the
/// optimistic one before.
///
/// So is the squad: players typed in without reception, or just before the
/// page is left, must not be lost.
bool queueable(String action) =>
    tallyActions.contains(action.replaceFirst(RegExp(r'_correction$'), '')) ||
    action == 'assign_player' ||
    action == 'lineup' ||
    action == 'squad';

/// The basketball clock may be started and stopped behind unconfirmed taps:
/// a whistle cannot wait for the network. Not replayed after a reload.
const clockActions = {'clock_start', 'clock_stop'};

/// Allowed while earlier taps are still on their way to the server.
bool tappable(String action) =>
    queueable(action) || clockActions.contains(action);

const _statColumns = {
  'score': 'pts',
  'rebound': 'reb',
  'assist': 'ast',
  'steal': 'stl',
  'block': 'blk',
  'turnover': 'to',
  'personal_foul': 'pf',
  'technical_foul': 'pf',
  'free_throw_missed': 'ftx',
};

/// Server state plus the visible effect of unconfirmed tally commands.
Map<String, dynamic> optimisticState(
  Map<String, dynamic> server,
  List<Map<String, dynamic>> queue,
) {
  // A command the server already recorded (its answer got lost, the retry is
  // still waiting) must not be counted a second time.
  final recorded = {
    for (final e in server['events'] as List? ?? [])
      if (e['command_id'] != null) e['command_id'],
  };
  final pending = queue
      .where(
        (c) =>
            c['match_id'] == server['match_id'] &&
            tappable(c['action']) &&
            !recorded.contains(c['command_id']),
      )
      .toList();
  if (pending.isEmpty || server['match_id'] == null) return server;
  final s = jsonDecode(jsonEncode(server)) as Map<String, dynamic>;
  final events = (s['events'] as List? ?? []).cast<Map<String, dynamic>>();
  for (final command in pending) {
    final action = command['action'] as String;
    final data = Map<String, dynamic>.from(command['data'] ?? {});
    if (clockActions.contains(action)) {
      final clock = s['clock'];
      if (clock is! Map) continue;
      if (action == 'clock_stop') {
        if (clock['running'] != true) continue;
        clock['elapsed_ms'] = data['elapsed_ms'] ?? clock['elapsed_ms'];
        clock['running'] = false;
        clock['started_at'] = null;
      } else if (clock['running'] != true && command['at'] != null) {
        clock['running'] = true;
        clock['started_at'] = command['at'];
      }
      continue;
    }
    final team = data['team'];
    if (team != 'home' && team != 'away') continue;
    if (action == 'lineup') {
      (s[team] as Map)['on_court'] = data['player_ids'];
      continue;
    }
    if (action == 'squad') {
      (s[team] as Map)['squad'] = data['players'];
      continue;
    }
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
    } else if (kind == 'free_kick' || kind == 'penalty') {
      // Logged only; nothing to count on screen.
    } else if (kind == 'foul') {
      counters['fouls'] = ((counters['fouls'] ?? 0) as num) + sign;
    } else if (kind == 'team_foul' || kind == 'timeout') {
      final key = kind == 'team_foul' ? 'team_fouls' : 'timeouts';
      counters[key] = ((counters[key] ?? 0) as num) + sign;
    } else {
      // A coach/bench technical belongs to no player and no team foul.
      if (kind != 'technical_foul' || playerId != null) {
        _addStat(side, playerId, _statColumns[kind]!, sign);
      }
      if (kind == 'personal_foul' || kind == 'technical_foul') {
        final countsTeam = correcting
            ? target!['counts_team'] == true
            : kind == 'technical_foul'
            ? (playerId != null || data['kind'] != null) &&
                  (s['foul_mode'] == 'team' || s['foul_mode'] == 'both')
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

/// The server refused a command (as opposed to: no answer, outcome unknown).
class CommandRejected implements Exception {
  CommandRejected(this.code);
  final String code;
}

/// Sends the queued commands one at a time, in the order they were tapped.
///
/// * No answer: the command stays at the head and is retried unchanged (same
///   ID and revision), so the server never counts it twice.
/// * Refused: the command is dropped, and nothing else is sent until fresh
///   state has arrived, because the taps behind it are stamped with that
///   state's revision. Only one run is ever active; a second sender would
///   post the same command twice and drop a different one.
class CommandPump {
  CommandPump({
    required this.queue,
    required this.revision,
    required this.send,
    required this.fresh,
    required this.applied,
    required this.rejected,
    required this.changed,
    required this.offline,
    required this.idle,
    required this.alive,
  });

  final List<Map<String, dynamic>> queue;
  final dynamic Function() revision;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> item) send;
  final Future<void> Function() fresh;
  final void Function(Map<String, dynamic> item, Map<String, dynamic> result)
  applied;
  final void Function(Map<String, dynamic> item, String code) rejected;

  /// The queue or an item changed: persist and repaint.
  final void Function() changed;
  final void Function() offline, idle;
  final bool Function() alive;

  bool sending = false;
  int retryMs = 500;
  Timer? retryTimer;

  Future<void> run() async {
    if (sending || !alive()) return;
    sending = true;
    retryTimer?.cancel();
    try {
      while (queue.isNotEmpty && alive()) {
        final item = queue.first;
        // The revision is fixed when a command is first sent and kept for
        // retries: the server recognises a retry by its identical fingerprint.
        if (item['expected_revision'] == null) {
          item['expected_revision'] = revision();
          changed();
        }
        final Map<String, dynamic> result;
        try {
          result = await send(item);
        } on CommandRejected catch (e) {
          queue.remove(item);
          rejected(item, e.code);
          await fresh();
          continue;
        } catch (_) {
          // Unknown outcome: keep the command and retry it unchanged.
          offline();
          retryTimer = Timer(Duration(milliseconds: retryMs), run);
          retryMs = (retryMs * 2).clamp(500, 5000);
          break;
        }
        queue.remove(item);
        retryMs = 500;
        applied(item, result);
      }
    } finally {
      sending = false;
    }
    idle();
  }
}
