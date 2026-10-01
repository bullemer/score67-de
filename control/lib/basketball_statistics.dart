import 'package:flutter/material.dart';

/// Event-derived totals. Tapping a counting cell records or corrects one event.
class BasketballStatistics extends StatefulWidget {
  final Map<String, dynamic> statistics;
  final String Function(String) t;
  final bool enabled, personalFoulsEnabled;
  final Future<bool> Function(String, String?, bool) record;
  final VoidCallback configureFouls;
  const BasketballStatistics({
    super.key,
    required this.statistics,
    required this.t,
    required this.enabled,
    required this.personalFoulsEnabled,
    required this.record,
    required this.configureFouls,
  });

  @override
  State<BasketballStatistics> createState() => _BasketballStatisticsState();
}

class _BasketballStatisticsState extends State<BasketballStatistics> {
  bool correcting = false;
  static const columns = {
    'pts': 'score',
    'reb': 'rebound',
    'ast': 'assist',
    'stl': 'steal',
    'blk': 'block',
    'to': 'turnover',
    'pf': 'personal_foul',
  };

  String label(dynamic player) => player['id'] == null
      ? widget.t('foul.unknown')
      : [
          if ((player['number'] ?? '').isNotEmpty) '#${player['number']}',
          if ((player['name'] ?? '').isNotEmpty) player['name'],
        ].join(' ');

  @override
  Widget build(BuildContext context) {
    final players = widget.statistics['players'] as List? ?? [];
    final totals = widget.statistics['totals'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.t('stats.title'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        Text(widget.t('stats.help')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(widget.t('stats.correct')),
          value: correcting,
          onChanged: (value) => setState(() => correcting = value),
        ),
        if (!widget.personalFoulsEnabled)
          TextButton(
            onPressed: widget.enabled ? widget.configureFouls : null,
            child: Text(widget.t('stats.enable_pf')),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            horizontalMargin: 4,
            columnSpacing: 12,
            dataRowMinHeight: 52,
            dataRowMaxHeight: 72,
            columns: [
              DataColumn(label: Text(widget.t('basketball.scorer'))),
              for (final entry in columns.entries)
                DataColumn(
                  numeric: true,
                  label: Tooltip(
                    message: widget.t('stats.${entry.key}.description'),
                    child: Text(entry.key.toUpperCase()),
                  ),
                ),
            ],
            rows: [
              for (final player in players)
                DataRow(
                  cells: [
                    DataCell(SizedBox(width: 100, child: Text(label(player)))),
                    for (final entry in columns.entries)
                      DataCell(
                        entry.key == 'pts'
                            ? Text('${player[entry.key] ?? 0}')
                            : Tooltip(
                                message:
                                    '${correcting ? '−' : '+'} ${widget.t(entry.value)} · ${label(player)}',
                                child: TextButton(
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    foregroundColor: correcting
                                        ? Colors.orange
                                        : null,
                                  ),
                                  onPressed:
                                      widget.enabled &&
                                          (correcting ||
                                              (entry.key == 'pf' &&
                                                  player['foul_player'] ==
                                                      true) ||
                                              player['id'] == null ||
                                              player['in_squad'] == true) &&
                                          (!correcting ||
                                              (player[entry.key] ?? 0) > 0) &&
                                          (entry.key != 'pf' ||
                                              correcting ||
                                              widget.personalFoulsEnabled)
                                      ? () => widget.record(
                                          entry.value,
                                          player['id'],
                                          correcting,
                                        )
                                      : null,
                                  child: Text(
                                    '${player[entry.key] ?? 0} ${correcting ? '−' : '+'}',
                                  ),
                                ),
                              ),
                      ),
                  ],
                ),
              DataRow(
                cells: [
                  DataCell(
                    Text(
                      widget.t('stats.total'),
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
