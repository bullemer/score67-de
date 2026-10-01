import 'package:flutter/material.dart';

/// Live totals and direct event controls share one matrix.
class BasketballStatistics extends StatelessWidget {
  final Map<String, dynamic> statistics;
  final String Function(String) t;
  final bool enabled, personalFoulsEnabled, scoringEnabled;
  final Future<bool> Function(String, String?, bool) record;
  final Future<bool> Function(String?, int, bool) score;
  final bool Function(String?, int) canRemoveScore;
  const BasketballStatistics({
    super.key,
    required this.statistics,
    required this.t,
    required this.enabled,
    required this.personalFoulsEnabled,
    required this.scoringEnabled,
    required this.record,
    required this.score,
    required this.canRemoveScore,
  });

  static const columns = {
    'pts': 'score',
    'pf': 'personal_foul',
    'reb': 'rebound',
    'ast': 'assist',
    'stl': 'steal',
    'blk': 'block',
    'to': 'turnover',
  };

  String label(dynamic player) => player['id'] == null
      ? t('foul.unknown')
      : [
          if ((player['number'] ?? '').isNotEmpty) '#${player['number']}',
          if ((player['name'] ?? '').isNotEmpty) player['name'],
        ].join(' ');

  Widget pointCell(dynamic player) {
    final known = player['id'] == null || player['in_squad'] == true;
    return SizedBox(
      width: 156,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${player['pts'] ?? 0}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          for (final subtract in [false, true])
            Row(
              children: [
                for (final points in [1, 2, 3])
                  Expanded(
                    child: Tooltip(
                      message: subtract
                          ? '${t('stats.remove_basket')} $points · ${label(player)}'
                          : '+$points · ${label(player)}',
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(48, 44),
                          foregroundColor: subtract ? Colors.orange : null,
                        ),
                        onPressed:
                            enabled &&
                                (subtract
                                    ? canRemoveScore(player['id'], points)
                                    : scoringEnabled && known)
                            ? () => score(player['id'], points, subtract)
                            : null,
                        child: Text('${subtract ? '−' : '+'}$points'),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget statCell(dynamic player, String key, String kind) {
    final count = player[key] ?? 0;
    final canAdd =
        enabled &&
        (player['id'] == null ||
            player['in_squad'] == true ||
            (key == 'pf' && player['foul_player'] == true)) &&
        (key != 'pf' || personalFoulsEnabled);
    return SizedBox(
      width: 96,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: key == 'pf' && count >= 5
                  ? const Color(0xffff8b8b)
                  : key == 'pf' && count == 4
                  ? const Color(0xfffacc15)
                  : null,
            ),
          ),
          Row(
            children: [
              for (final subtract in [true, false])
                Expanded(
                  child: IconButton(
                    tooltip:
                        '${subtract ? '−' : '+'} ${t(kind)} · ${label(player)}',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: subtract
                        ? enabled && count > 0
                              ? () => record(kind, player['id'], true)
                              : null
                        : canAdd
                        ? () => record(kind, player['id'], false)
                        : null,
                    icon: Icon(subtract ? Icons.remove : Icons.add),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final players = statistics['players'] as List? ?? [];
    final totals = statistics['totals'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('stats.title'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        Text(t('stats.help')),
        if (!personalFoulsEnabled) Text(t('stats.enable_pf')),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            horizontalMargin: 4,
            columnSpacing: 8,
            dataRowMinHeight: 128,
            dataRowMaxHeight: 128,
            columns: [
              DataColumn(label: Text(t('basketball.scorer'))),
              for (final key in columns.keys)
                DataColumn(
                  label: Tooltip(
                    message: t('stats.$key.description'),
                    child: Text(key.toUpperCase()),
                  ),
                ),
            ],
            rows: [
              for (final player in players)
                DataRow(
                  cells: [
                    DataCell(SizedBox(width: 90, child: Text(label(player)))),
                    for (final entry in columns.entries)
                      DataCell(
                        entry.key == 'pts'
                            ? pointCell(player)
                            : statCell(player, entry.key, entry.value),
                      ),
                  ],
                ),
              DataRow(
                cells: [
                  DataCell(
                    Text(
                      t('stats.total'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  for (final key in columns.keys)
                    DataCell(
                      Text(
                        '${totals[key] ?? 0}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
