import 'package:flutter/material.dart';

/// One row of the box score: a player, the team's unattributed entries, or
/// the totals. Minutes are game-clock milliseconds on court/pitch.
class BoxRow {
  final String? id;
  final String label;
  int ms = 0, pts = 0, ftm = 0, fta = 0, two = 0, three = 0;
  int pf = 0, reb = 0, goals = 0, yellow = 0, red = 0;
  BoxRow(this.id, this.label);

  void add(BoxRow o) {
    ms += o.ms;
    pts += o.pts;
    ftm += o.ftm;
    fta += o.fta;
    two += o.two;
    three += o.three;
    pf += o.pf;
    reb += o.reb;
    goals += o.goals;
    yellow += o.yellow;
    red += o.red;
  }
}

String playerLabelOf(Map p) {
  final number = '${p['number'] ?? ''}', name = '${p['name'] ?? ''}';
  if (number.isNotEmpty && name.isNotEmpty) return '#$number $name';
  return number.isNotEmpty ? '#$number' : name;
}

/// Box score of [team] for [period] (null = whole game), replayed from the
/// game's events. Minutes follow the lineup: players on court when a period
/// starts, substitutions (lineup entries) at their game-clock time, until
/// the period ends — the running period up to [nowElapsedMs].
({List<BoxRow> players, BoxRow team, BoxRow total, bool minutes}) boxScore(
  Map<String, dynamic> state,
  String team,
  int? period,
  int nowElapsedMs,
) {
  final basketball = state['sport'] == 'basketball';
  final rows = <String, BoxRow>{};
  final order = <String>[];
  BoxRow row(Map player) {
    final id = '${player['id']}';
    return rows.putIfAbsent(id, () {
      order.add(id);
      return BoxRow(id, playerLabelOf(player));
    });
  }

  final squad = [
    for (final p in state[team]['squad'] as List? ?? [])
      Map<String, dynamic>.from(p),
  ];
  squad.sort(
    (a, b) => (int.tryParse('${a['number']}') ?? 999).compareTo(
      int.tryParse('${b['number']}') ?? 999,
    ),
  );
  for (final p in squad) {
    row(p);
  }
  final teamRow = BoxRow(null, 'Team');
  final events = [
    for (final e in state['events'] as List? ?? [])
      if (e['cancelled'] != true) Map<String, dynamic>.from(e),
  ]..sort((a, b) => (a['id'] as num).compareTo(b['id'] as num));

  // Minutes: replay who is on court.
  final onCourt = <String, Map>{};
  final since = <String, int>{};
  var current = 0;
  var running = false;
  var lineupUsed = false;
  void credit(String id, int until) {
    final start = since.remove(id);
    if (start == null || (period != null && current != period)) return;
    final r = rows[id];
    if (r != null) r.ms += (until - start).clamp(0, 1 << 31);
  }

  for (final e in events) {
    final type = e['type'];
    final clock = (e['clock_ms'] as num?)?.toInt();
    if (type == 'period_start' || type == 'overtime_start') {
      current = (e['period'] ?? 0) as int;
      running = true;
      for (final id in onCourt.keys) {
        since[id] = 0;
      }
    } else if ((type == 'period_end' ||
            type == 'game_end' ||
            type == 'period_set') &&
        running) {
      final end = clock ?? (e['period_duration_ms'] as num?)?.toInt() ?? 0;
      for (final id in onCourt.keys.toList()) {
        credit(id, end);
      }
      running = false;
    } else if (type == 'lineup' && e['team'] == team) {
      lineupUsed = true;
      for (final p in e['left'] as List? ?? []) {
        final id = '${p['id']}';
        if (running) credit(id, clock ?? 0);
        onCourt.remove(id);
      }
      for (final p in e['entered'] as List? ?? []) {
        final id = '${p['id']}';
        row(p as Map);
        onCourt[id] = p;
        if (running) since[id] = clock ?? 0;
      }
    }
  }
  if (running) {
    for (final id in onCourt.keys.toList()) {
      credit(id, nowElapsedMs);
    }
  }

  // Counting stats.
  for (final e in events) {
    if (e['team'] != team || e['corrected'] == true) continue;
    if (period != null && e['period'] != period) continue;
    final type = '${e['type']}';
    if (type.endsWith('_correction')) continue;
    final player = e['player'] as Map?;
    final r = player == null ? teamRow : row(player);
    switch (type) {
      case 'score':
        final points = (e['points'] as num).toInt();
        r.pts += points;
        if (!basketball) {
          r.goals += points;
        } else if (points == 1) {
          r.ftm++;
          r.fta++;
        } else if (points == 2) {
          r.two++;
        } else if (points == 3) {
          r.three++;
        }
      case 'score_adjust':
        // Admin score corrections belong to the team, so totals match the score.
        teamRow.pts += (e['points'] as num).toInt();
        if (!basketball) teamRow.goals += (e['points'] as num).toInt();
      case 'free_throw_missed':
        r.fta++;
      case 'personal_foul':
        r.pf++;
      case 'technical_foul' when player != null:
        r.pf++;
      case 'rebound':
        r.reb++;
      case 'yellow_card':
        r.yellow++;
      case 'red_card':
        r.red++;
    }
  }
  final players = [for (final id in order) rows[id]!];
  final total = BoxRow(null, 'Σ');
  for (final r in [...players, teamRow]) {
    total.add(r);
  }
  return (
    players: players,
    team: teamRow,
    total: total,
    minutes: lineupUsed && state['clock']?['enabled'] == true,
  );
}

String minutesText(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// The console's Box Score tab: team switch, whole game or one period.
class BoxScorePanel extends StatefulWidget {
  final Map<String, dynamic> state;
  final String Function(String) t;
  final String Function(int period) periodLabel;
  final int Function() elapsed;
  const BoxScorePanel({
    super.key,
    required this.state,
    required this.t,
    required this.periodLabel,
    required this.elapsed,
  });

  @override
  State<BoxScorePanel> createState() => _BoxScorePanelState();
}

class _BoxScorePanelState extends State<BoxScorePanel> {
  String team = 'home';
  int? period;

  @override
  Widget build(BuildContext context) {
    final s = widget.state, t = widget.t;
    final basketball = s['sport'] == 'basketball';
    final played = (s['period'] ?? 0) as int;
    final box = boxScore(
      s,
      team,
      period,
      s['phase'] == 'period_running' ? widget.elapsed() : 0,
    );
    final columns = basketball
        ? ['MIN', 'PTS', 'FT', 'FT%', '2P', '3P', 'PF', 'RB']
        : ['MIN', t('box.goals'), 'YC', 'RC'];
    List<String> cells(BoxRow r, {bool teamRow = false}) {
      final minutes = teamRow || !box.minutes ? '–' : minutesText(r.ms);
      return basketball
          ? [
              minutes,
              '${r.pts}',
              '${r.ftm}/${r.fta}',
              r.fta == 0 ? '–' : '${(100 * r.ftm / r.fta).round()}%',
              '${r.two}',
              '${r.three}',
              '${r.pf}',
              '${r.reb}',
            ]
          : [minutes, '${r.goals}', '${r.yellow}', '${r.red}'];
    }

    TableRow line(
      String label,
      List<String> values, {
      bool bold = false,
      bool header = false,
    }) {
      final style = TextStyle(
        fontWeight: bold || header ? FontWeight.w800 : FontWeight.w500,
        color: header ? const Color(0xffb6f36e) : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      return TableRow(
        decoration: bold
            ? const BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white24)),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          for (final v in values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
              child: Text(v, style: style, textAlign: TextAlign.right),
            ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final side in ['home', 'away'])
              ChoiceChip(
                label: Text(s[side]['short']),
                selected: team == side,
                onSelected: (_) => setState(() => team = side),
              ),
            const SizedBox(width: 10),
            ChoiceChip(
              label: Text(t('box.all')),
              selected: period == null,
              onSelected: (_) => setState(() => period = null),
            ),
            for (var p = 1; p <= played; p++)
              ChoiceChip(
                label: Text(widget.periodLabel(p)),
                selected: period == p,
                onSelected: (_) => setState(() => period = p),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Table(
          columnWidths: {
            0: const FlexColumnWidth(),
            for (var i = 1; i <= columns.length; i++)
              i: IntrinsicColumnWidth(flex: i == 1 ? 1.2 : 1),
          },
          children: [
            line(t('box.player'), columns, header: true),
            for (final r in box.players) line(r.label, cells(r)),
            if (box.team.pts != 0 ||
                box.team.fta != 0 ||
                box.team.reb != 0 ||
                box.team.pf != 0 ||
                box.team.yellow != 0 ||
                box.team.red != 0)
              line(t('box.team_row'), cells(box.team, teamRow: true)),
            line(t('box.total'), cells(box.total, teamRow: true), bold: true),
          ],
        ),
        if (!box.minutes)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t('box.minutes_note'),
              style: const TextStyle(fontSize: 12, color: Color(0xffb5c2d4)),
            ),
          ),
      ],
    );
  }
}
