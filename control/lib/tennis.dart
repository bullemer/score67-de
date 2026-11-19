import 'package:flutter/material.dart';

/// Shared match format choices for creation and the tennis control center.
class TennisFormat extends StatelessWidget {
  final Map<String, dynamic> value;
  final String Function(String) t;
  final void Function(String, dynamic) onChanged;
  final bool enabled;
  const TennisFormat({
    super.key,
    required this.value,
    required this.t,
    required this.onChanged,
    this.enabled = true,
  });

  Widget choice(
    String key,
    List<dynamic> options,
    String Function(dynamic) label,
  ) => DropdownButtonFormField<dynamic>(
    key: ValueKey('$key:${value[key]}'),
    initialValue: value[key] ?? options.first,
    isExpanded: true,
    decoration: InputDecoration(labelText: t('tennis.$key')),
    items: [
      for (final option in options)
        DropdownMenuItem(value: option, child: Text(label(option))),
    ],
    onChanged: enabled ? (v) => onChanged(key, v) : null,
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      choice('category', ['women', 'men'], (v) => t('tennis.$v')),
      choice('best_of', [3, 5], (v) => t('tennis.best_of_$v')),
      choice('mode', ['simple', 'detailed'], (v) => t('tennis.$v')),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(t('tennis.${value['mode']}_hint')),
      ),
      choice('final_tiebreak', [7, 10], (v) => '$v ${t('tennis.points')}'),
      choice('deciding', [
        'set',
        'match_tiebreak',
      ], (v) => t('tennis.deciding_$v')),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(t('tennis.format_hint')),
      ),
    ],
  );
}

class TennisScorePanel extends StatelessWidget {
  final Map<String, dynamic> state;
  final String Function(String) t;
  final Future<bool> Function(String, Map<String, dynamic>) command;
  final VoidCallback? onUndo, onEditHome, onEditAway;
  final bool enabled;
  const TennisScorePanel({
    super.key,
    required this.state,
    required this.t,
    required this.command,
    required this.enabled,
    this.onUndo,
    this.onEditHome,
    this.onEditAway,
  });

  /// The deciding set is being played as a match tie-break (to 10).
  bool get matchTiebreak {
    final tennis = state['tennis'] as Map;
    final sets = tennis['sets'] as List;
    return tennis['deciding'] == 'match_tiebreak' &&
        tennis['tiebreak'] == true &&
        (sets[0] as int) + (sets[1] as int) == (tennis['best_of'] as int) - 1;
  }

  Future<void> enterSet(BuildContext context) async {
    final decider = matchTiebreak;
    int home = 6, away = 0;
    final tbHome = TextEditingController(), tbAway = TextEditingController();
    String error = '';
    bool saving = false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            t(decider ? 'tennis.match_tiebreak_result' : 'tennis.enter_set'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final i in decider ? <int>[] : [0, 1])
                  DropdownButtonFormField<int>(
                    initialValue: i == 0 ? home : away,
                    decoration: InputDecoration(
                      labelText: state[i == 0 ? 'home' : 'away']['name'],
                    ),
                    items: [
                      for (int n = 0; n <= 7; n++)
                        DropdownMenuItem(value: n, child: Text('$n')),
                    ],
                    onChanged: saving
                        ? null
                        : (v) => update(() {
                            if (i == 0) {
                              home = v!;
                            } else {
                              away = v!;
                            }
                          }),
                  ),
                if (decider ||
                    (home == 7 && away == 6) ||
                    (home == 6 && away == 7)) ...[
                  if (!decider) Text(t('tennis.tiebreak_optional')),
                  for (final i in [0, 1])
                    TextField(
                      controller: i == 0 ? tbHome : tbAway,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText:
                            '${t('tennis.tiebreak')} · ${state[i == 0 ? 'home' : 'away']['name']}',
                      ),
                    ),
                ],
                if (error.isNotEmpty)
                  Text(error, style: const TextStyle(color: Colors.orange)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final high = home > away ? home : away,
                          low = home < away ? home : away;
                      final tie = high == 7 && low == 6;
                      final a = int.tryParse(tbHome.text),
                          b = int.tryParse(tbAway.text);
                      if (decider) {
                        // Recorded as a 1-0 set with its points.
                        if (a == null || b == null || a == b) {
                          update(() => error = t('error.invalid_value'));
                          return;
                        }
                        home = a > b ? 1 : 0;
                        away = 1 - home;
                      } else if (!((high == 6 && low <= 4) ||
                              (high == 7 && (low == 5 || low == 6))) ||
                          (tie &&
                              (tbHome.text.isNotEmpty ||
                                  tbAway.text.isNotEmpty) &&
                              (a == null || b == null))) {
                        update(() => error = t('error.invalid_value'));
                        return;
                      }
                      update(() => saving = true);
                      final ok = await command('tennis_set', {
                        'games': [home, away],
                        if ((tie || decider) && a != null && b != null)
                          'tiebreak': [a, b],
                      });
                      if (!context.mounted) return;
                      if (ok) {
                        Navigator.pop(context);
                      } else {
                        update(() {
                          saving = false;
                          error = t('error.invalid_value');
                        });
                      }
                    },
              child: Text(t('save')),
            ),
          ],
        ),
      ),
    );
    // Dialog animation may still hold the fields briefly.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    tbHome.dispose();
    tbAway.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tennis = state['tennis'] as Map;
    final active = state['phase'] == 'period_running';
    final finished = state['phase'] == 'finished';
    final points = tennis['point_labels'] as List? ?? ['0', '0'];
    final pointMode =
        tennis['mode'] == 'detailed' || tennis['tiebreak'] == true;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${t('tennis.${tennis['category']}')} · ${t('tennis.best_of_${tennis['best_of']}')} · ${t('tennis.${tennis['mode']}')}',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        if (finished)
          Text(
            tennis['winner'] == null
                ? t('finished')
                : '${state[tennis['winner'] == 0 ? 'home' : 'away']['name']} · ${t('tennis.winner')}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        Text(
          '${t('tennis.sets')}: ${tennis['sets'][0]} – ${tennis['sets'][1]}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
        ),
        if (!finished)
          Text(
            '${t('tennis.games')}: ${tennis['games'][0]} – ${tennis['games'][1]}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22),
          ),
        if (tennis['tiebreak'] == true)
          Text(
            t(matchTiebreak ? 'tennis.match_tiebreak' : 'tennis.tiebreak'),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 12),
        for (final i in [0, 1])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextButton(
                    onPressed: i == 0 ? onEditHome : onEditAway,
                    child: Text(
                      '${!finished && tennis['server'] == i ? '● ' : ''}${state[i == 0 ? 'home' : 'away']['name']}',
                      style: const TextStyle(fontSize: 22),
                    ),
                  ),
                  if (tennis['server'] == i && !finished)
                    Text(t('tennis.serving'), textAlign: TextAlign.center),
                  if (pointMode && !finished)
                    Text(
                      '${points[i]}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  if (!finished)
                    FilledButton(
                      onPressed: enabled && active
                          ? () => command(
                              pointMode ? 'tennis_point' : 'tennis_game',
                              {'team': i == 0 ? 'home' : 'away'},
                            )
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          t(pointMode ? 'tennis.add_point' : 'tennis.add_game'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (state['phase'] == 'pre_game') ...[
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              for (final i in [0, 1])
                ChoiceChip(
                  label: Text(
                    '${t('tennis.serving')}: ${state[i == 0 ? 'home' : 'away']['name']}',
                  ),
                  selected: tennis['server'] == i,
                  onSelected: enabled
                      ? (_) => command('tennis_server', {
                          'team': i == 0 ? 'home' : 'away',
                        })
                      : null,
                ),
            ],
          ),
          FilledButton(
            onPressed: enabled ? () => command('period_start', {}) : null,
            child: Text(t('tennis.start')),
          ),
        ],
        if (tennis['mode'] == 'simple' &&
            active &&
            (tennis['games'] as List).every((v) => v == 0) &&
            (tennis['points'] as List? ?? [0, 0]).every((v) => v == 0))
          OutlinedButton(
            onPressed: enabled ? () => enterSet(context) : null,
            child: Text(
              t(
                matchTiebreak
                    ? 'tennis.match_tiebreak_result'
                    : 'tennis.enter_set',
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: onUndo,
          icon: const Icon(Icons.undo),
          label: Text(t('undo')),
        ),
        if ((tennis['set_scores'] as List).isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(t('tennis.set_results')),
          for (final (i, set) in (tennis['set_scores'] as List).indexed)
            ListTile(
              title: Text(
                (set['games'][0] as int) + (set['games'][1] as int) == 1
                    ? t('tennis.match_tiebreak')
                    : '${t('tennis.set')} ${i + 1}: ${set['games'][0]} – ${set['games'][1]}',
              ),
              subtitle: set['tiebreak'] == null
                  ? null
                  : Text(
                      '${(set['games'][0] as int) + (set['games'][1] as int) == 1 ? '' : '${t('tennis.tiebreak')}: '}${set['tiebreak'][0]} – ${set['tiebreak'][1]}',
                    ),
            ),
        ],
      ],
    );
  }
}
