import 'package:flutter/material.dart';

/// One team's scoring matrix: fixed 52 px rows, Unknown player first.
/// Tap +1/+2/+3, PF or REB to add; in correction mode the same cells subtract.
class BasketballStatistics extends StatelessWidget {
  final Map<String, dynamic> statistics;
  final String Function(String) t;
  final bool enabled, personalFoulsEnabled, scoringEnabled, correcting;
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
    this.correcting = false,
    required this.record,
    required this.score,
    required this.canRemoveScore,
  });

  static const rowHeight = 52.0, cell = 44.0, labelWidth = 60.0, points = 28.0;
  static const width = labelWidth + points + 3 * cell + 2 * cell;
  static const foulTrouble = Color(0xffffb020), fouledOut = Color(0xffff6b6b);

  String label(dynamic player) => player['id'] == null
      ? t('stats.team_row')
      : (player['number'] ?? '').isNotEmpty
      ? '#${player['number']}'
      : player['name'];

  Widget button(
    String text,
    String tooltip,
    VoidCallback? onPressed, {
    Color? color,
    Color? background,
  }) => SizedBox(
    width: cell,
    height: cell,
    child: Tooltip(
      message: tooltip,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(cell, cell),
          foregroundColor: correcting ? Colors.orange : color,
          backgroundColor: background,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        child: Text(text),
      ),
    ),
  );

  Widget row(dynamic player) {
    final id = player['id'] as String?;
    final active = id == null || player['in_squad'] == true;
    final fouls = (player['pf'] ?? 0) as int;
    final warning = fouls >= 5
        ? fouledOut
        : fouls == 4
        ? foulTrouble
        : null;
    final name = id == null ? '' : (player['name'] ?? '') as String;
    return SizedBox(
      height: rowHeight,
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label(player),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: id == null ? 13 : 16,
                    fontWeight: FontWeight.w700,
                    color: warning ?? (active ? null : Colors.grey),
                    decoration: fouls >= 5 ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (name.isNotEmpty && (player['number'] ?? '').isNotEmpty)
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: points,
            child: Text(
              '${player['pts'] ?? 0}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          for (final points in [1, 2, 3])
            button(
              '${correcting ? '−' : '+'}$points',
              correcting
                  ? '${t('stats.remove_basket')} $points · ${label(player)}'
                  : '+$points · ${label(player)}',
              enabled &&
                      (correcting
                          ? canRemoveScore(id, points)
                          : scoringEnabled && active)
                  ? () => score(id, points, correcting)
                  : null,
            ),
          button(
            '$fouls',
            '${correcting ? '−' : '+'} ${t('personal_foul')} · ${label(player)}',
            enabled &&
                    (correcting
                        ? fouls > 0
                        : personalFoulsEnabled &&
                              (active || player['foul_player'] == true))
                ? () => record('personal_foul', id, correcting)
                : null,
            color: warning,
            background: warning?.withValues(alpha: .16),
          ),
          button(
            '${player['reb'] ?? 0}',
            '${correcting ? '−' : '+'} ${t('rebound')} · ${label(player)}',
            enabled && (correcting ? (player['reb'] ?? 0) > 0 : active)
                ? () => record('rebound', id, correcting)
                : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final players = statistics['players'] as List? ?? [];
    final totals = statistics['totals'] as Map? ?? {};
    const header = TextStyle(fontSize: 12, color: Colors.grey);
    Widget heading(String text, double width, [String? tip]) => SizedBox(
      width: width,
      child: Tooltip(
        message: tip ?? '',
        child: Text(text, textAlign: TextAlign.center, style: header),
      ),
    );
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: labelWidth),
              heading('PTS', points + 3 * cell, t('stats.pts.description')),
              heading('PF', cell, t('stats.pf.description')),
              heading('REB', cell, t('stats.reb.description')),
            ],
          ),
          for (final player in players) row(player),
          const Divider(height: 1),
          SizedBox(
            height: 32,
            child: Row(
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(t('stats.total_short'), style: header),
                ),
                SizedBox(
                  width: points,
                  child: Text(
                    '${totals['pts'] ?? 0}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 3 * cell),
                for (final key in ['pf', 'reb'])
                  SizedBox(
                    width: cell,
                    child: Text(
                      '${totals[key] ?? 0}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
