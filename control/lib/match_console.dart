import 'dart:async';

import 'package:flutter/material.dart';

/// One console action. [needsTarget] actions wait for a team or player tap.
class ConsoleAction {
  final String id, label;
  final Color accent;
  const ConsoleAction(this.id, this.label, this.accent);
}

/// InGame-style landscape console: header with scores, fouls, timeouts,
/// possession and clock; team columns left; middle panel; actions right.
/// Pick an action first, then a player or the team tile.
class MatchConsole extends StatefulWidget {
  final Map<String, dynamic> state;
  final String Function(String) t;
  final String clock, period;
  final bool running, canToggleClock, canTap, canWrite, connected;
  final Widget sync;
  final VoidCallback onMenu, onToggleClock, onClockTap;
  final VoidCallback? onUndo;
  final void Function(String team) onSubstitutions;

  /// Records [action] for [team]; [playerId] null means the team itself.
  final void Function(String action, String team, String? playerId) onAction;
  final void Function(String team) onPossession;

  /// Double-tap editing of team and player names (only while no action is
  /// armed, so scoring taps are never delayed by double-tap detection).
  final void Function(String team) onEditTeam;
  final void Function(String team, String playerId) onEditPlayer;
  final List<(String, Widget)> tabs;
  const MatchConsole({
    super.key,
    required this.state,
    required this.t,
    required this.clock,
    required this.period,
    required this.running,
    required this.canToggleClock,
    required this.canTap,
    required this.canWrite,
    required this.connected,
    required this.sync,
    required this.onMenu,
    required this.onToggleClock,
    required this.onClockTap,
    required this.onUndo,
    required this.onSubstitutions,
    required this.onAction,
    required this.onPossession,
    required this.onEditTeam,
    required this.onEditPlayer,
    required this.tabs,
  });

  @override
  State<MatchConsole> createState() => MatchConsoleState();
}

const consoleBackground = Color(0xff0b1018);
const headerBackground = Color(0xff5c0a12);
const foulTrouble = Color(0xffffb020), fouledOut = Color(0xffff6b6b);

Color readableOn(Color background) =>
    background.computeLuminance() > .4 ? Colors.black : Colors.white;

Color hexColor(String value) =>
    Color(int.parse(value.replaceFirst('#', 'ff'), radix: 16));

/// Timeouts used in the current allowance window and the allowance (FIBA:
/// 2 in the first half, 3 in the second, 1 per overtime). Null allowance for
/// formats without a standard quota.
(int, int?) timeoutWindow(Map<String, dynamic> state, String team) {
  final period = (state['period'] ?? 0) as int;
  final count = state['period_count'] as int;
  final events = (state['events'] as List? ?? []).where(
    (e) =>
        e['type'] == 'timeout' &&
        e['team'] == team &&
        e['cancelled'] == false &&
        e['corrected'] != true,
  );
  if (count != 4) return (events.length, null);
  bool inWindow(int p) => period > count
      ? p == period
      : period <= 2
      ? p <= 2
      : p >= 3 && p <= count;
  final used = events.where((e) => inWindow((e['period'] ?? 0) as int)).length;
  return (
    used,
    period > count
        ? 1
        : period <= 2
        ? 2
        : 3,
  );
}

class MatchConsoleState extends State<MatchConsole> {
  String? pending;
  int tab = 0;

  /// While a text field in the middle panel has focus (phone keyboard open),
  /// everything else hides so the edited row stays visible above the keyboard.
  bool editing = false;
  final middleKey = GlobalKey();
  bool hint = false;
  Timer? hintTimer;

  @override
  void dispose() {
    hintTimer?.cancel();
    super.dispose();
  }

  /// Penalty awarded and waiting for its outcome: (team, player).
  (String, String?)? penalty;

  /// Free throws in progress: (team, player). Stays open for the 2nd/3rd shot.
  (String, String?)? freeThrows;

  /// Switch the middle panel, e.g. from the menu ("Edit teams").
  void showTab(int index) => setState(() {
    tab = index;
    pending = null;
  });

  String t(String key) => widget.t(key);
  Map<String, dynamic> get s => widget.state;
  bool get football => s['sport'] != 'basketball';

  List<ConsoleAction> get actions => football
      ? [
          ConsoleAction('goal', t('console.goal'), const Color(0xff22c55e)),
          ConsoleAction('yellow', t('console.yellow'), const Color(0xfffacc15)),
          ConsoleAction('red', t('console.red'), const Color(0xffef4444)),
          ConsoleAction(
            'penalty',
            t('console.penalty'),
            const Color(0xfff97316),
          ),
          ConsoleAction('foul', t('console.foul'), const Color(0xffdc2626)),
          ConsoleAction(
            'free_kick',
            t('console.free_kick'),
            const Color(0xff2563eb),
          ),
          ConsoleAction('subs', t('console.subs'), const Color(0xff94a3b8)),
        ]
      : [
          ConsoleAction('ft', t('console.ft'), const Color(0xff22c55e)),
          ConsoleAction('2pt', t('console.2pt'), const Color(0xff2563eb)),
          ConsoleAction('3pt', t('console.3pt'), const Color(0xfff97316)),
          ConsoleAction('foul', t('console.foul'), const Color(0xffdc2626)),
          ConsoleAction('tech', t('console.tech'), const Color(0xffdc2626)),
          ConsoleAction('reb', t('console.reb'), const Color(0xffa855f7)),
          ConsoleAction(
            'timeout',
            t('console.timeout'),
            const Color(0xff94a3b8),
          ),
          ConsoleAction('subs', t('console.subs'), const Color(0xff94a3b8)),
        ];

  bool enabled(String id) {
    if (id == 'subs') return widget.canWrite;
    if (id == 'foul' && !football) {
      return widget.canTap && s['foul_mode'] != 'off';
    }
    return widget.canTap;
  }

  void target(String team, String? playerId) {
    final action = pending;
    if (action == null) {
      // Inline hint instead of a banner.
      hintTimer?.cancel();
      setState(() => hint = true);
      hintTimer = Timer(
        const Duration(milliseconds: 1800),
        () => mounted ? setState(() => hint = false) : null,
      );
      return;
    }
    setState(() => pending = null);
    if (action == 'subs') {
      widget.onSubstitutions(team);
    } else {
      if (action == 'ft') {
        // Hit or miss is chosen in the inline bar.
        setState(() => freeThrows = (team, playerId));
        return;
      }
      widget.onAction(action, team, playerId);
      if (action == 'penalty') setState(() => penalty = (team, playerId));
    }
  }

  Widget headerBox(
    String text, {
    Color? background,
    Color? foreground,
    double width = 64,
    double size = 30,
    VoidCallback? onTap,
    Color? border,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: width,
      height: 44,
      alignment: Alignment.center,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: border == null ? null : Border.all(color: border, width: 2),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w900,
          color: foreground ?? Colors.white,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );

  Widget teamFouls(String team) {
    final fouls =
        (s[team]['counters']?[football ? 'fouls' : 'team_fouls'] ?? 0) as int;
    final tint = football
        ? Colors.white70
        : fouls >= 5
        ? fouledOut
        : fouls == 4
        ? foulTrouble
        : Colors.white70;
    return Tooltip(
      message: t('team_fouls'),
      child: Text(
        'F $fouls',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: tint,
        ),
      ),
    );
  }

  Widget timeouts(String team) {
    final (used, allowed) = timeoutWindow(s, team);
    return Tooltip(
      message: t('timeouts'),
      child: Text(
        'TO $used${allowed == null ? '' : '/$allowed'}',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: allowed != null && used >= allowed
              ? fouledOut
              : Colors.white70,
        ),
      ),
    );
  }

  Widget possession(String team) {
    final active = s['possession'] == team;
    final home = team == 'home';
    final arrow = Icon(
      home ? Icons.arrow_left : Icons.arrow_right,
      size: 34,
      color: active ? const Color(0xff22c55e) : Colors.white38,
    );
    final short = Text(
      s[team]['short'],
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
    );
    return Tooltip(
      message: t('possession'),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: widget.canWrite ? () => widget.onPossession(team) : null,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? const Color(0xff22c55e) : Colors.white38,
            ),
          ),
          child: Row(children: home ? [short, arrow] : [arrow, short]),
        ),
      ),
    );
  }

  Widget cards(String team) {
    Widget card(Color color, int count) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Row(
        children: [
          Container(
            width: 13,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
    final counters = s[team]['counters'] ?? {};
    return Row(
      children: [
        card(const Color(0xfffacc15), (counters['yellow_cards'] ?? 0) as int),
        card(const Color(0xffef4444), (counters['red_cards'] ?? 0) as int),
      ],
    );
  }

  /// Goals and cards per player from active events (football tiles).
  Map<String, Map<String, int>> footballStats(String team) {
    final result = <String, Map<String, int>>{};
    for (final e in s['events'] as List? ?? []) {
      if (e['team'] != team ||
          e['cancelled'] == true ||
          e['corrected'] == true ||
          e['player'] == null) {
        continue;
      }
      final key = switch (e['type']) {
        'score' => 'goals',
        'yellow_card' => 'yellow',
        'red_card' => 'red',
        _ => null,
      };
      if (key == null) continue;
      final row = result.putIfAbsent(e['player']['id'], () => {});
      row[key] = (row[key] ?? 0) + 1;
    }
    return result;
  }

  Widget header() {
    Color color(String team) => hexColor(s[team]['color']);
    Widget score(String team) => headerBox(
      '${s[team]['score']}'.padLeft(2, '0'),
      background: color(team),
      foreground: readableOn(color(team)),
      width: 66,
    );
    return Container(
      color: headerBackground,
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          children: [
            IconButton(
              tooltip: t('console.menu'),
              icon: const Icon(Icons.menu, size: 30),
              onPressed: widget.onMenu,
            ),
            if (football) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  s['home']['short'],
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              cards('home'),
              const SizedBox(width: 10),
              teamFouls('home'),
            ] else ...[
              possession('home'),
              const SizedBox(width: 6),
              teamFouls('home'),
              const SizedBox(width: 10),
              timeouts('home'),
            ],
            const SizedBox(width: 6),
            score('home'),
            const SizedBox(width: 6),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(widget.period, style: const TextStyle(fontSize: 14)),
                Icon(
                  widget.connected ? Icons.wifi : Icons.wifi_off,
                  size: 16,
                  color: widget.connected
                      ? const Color(0xff22c55e)
                      : Colors.orange,
                ),
              ],
            ),
            GestureDetector(
              onTap: widget.onClockTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  widget.clock,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            score('away'),
            const SizedBox(width: 6),
            if (football) ...[
              teamFouls('away'),
              const SizedBox(width: 10),
              cards('away'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  s['away']['short'],
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ] else ...[
              timeouts('away'),
              const SizedBox(width: 10),
              teamFouls('away'),
              const SizedBox(width: 6),
              possession('away'),
            ],
            widget.sync,
            const SizedBox(width: 4),
            SizedBox(
              width: 64,
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(56, 44),
                  backgroundColor: widget.running
                      ? const Color(0xffdc2626)
                      : const Color(0xff16a34a),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: widget.canToggleClock ? widget.onToggleClock : null,
                child: Icon(
                  widget.running ? Icons.stop : Icons.play_arrow,
                  size: 34,
                  semanticLabel: t(
                    widget.running ? 'basketball.stop' : 'basketball.play',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// On-court players when a lineup is set, otherwise the whole squad.
  List<Map<String, dynamic>> players(String team) {
    final squad = [
      for (final p in s[team]['squad'] as List? ?? [])
        Map<String, dynamic>.from(p),
    ];
    final onCourt = (s[team]['on_court'] as List? ?? []).cast<String>();
    final shown = onCourt.isEmpty
        ? squad
        : [for (final id in onCourt) ...squad.where((p) => p['id'] == id)];
    shown.sort(
      (a, b) => (int.tryParse(a['number'] ?? '') ?? 999).compareTo(
        int.tryParse(b['number'] ?? '') ?? 999,
      ),
    );
    return shown;
  }

  Map<String, dynamic> stats(String team, String id) {
    for (final row in s[team]['statistics']?['players'] as List? ?? []) {
      if (row['id'] == id) return Map<String, dynamic>.from(row);
    }
    return {};
  }

  Widget tile(
    String team,
    String? playerId,
    String label, {
    int fouls = 0,
    Map<String, int> football = const {},
  }) {
    final color = hexColor(s[team]['color']);
    final foreground = readableOn(color);
    final armed = pending != null;
    final points = playerId == null
        ? null
        : this.football
        ? football['goals']
        : stats(team, playerId)['pts'];
    final yellow = football['yellow'] ?? 0, red = football['red'] ?? 0;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => target(team, playerId),
          onDoubleTap: armed
              ? null
              : () => playerId == null
                    ? widget.onEditTeam(team)
                    : widget.onEditPlayer(team, playerId),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: armed ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                if (playerId != null && this.football)
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < yellow; i++)
                          Container(
                            width: 8,
                            height: 11,
                            margin: const EdgeInsets.symmetric(vertical: 1),
                            color: const Color(0xfffacc15),
                          ),
                        if (red > 0)
                          Container(
                            width: 8,
                            height: 11,
                            margin: const EdgeInsets.symmetric(vertical: 1),
                            color: const Color(0xffef4444),
                          ),
                      ],
                    ),
                  ),
                if (playerId != null && !this.football)
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 1; i <= 5; i++)
                          Container(
                            width: 8,
                            height: 4,
                            margin: const EdgeInsets.symmetric(vertical: 1),
                            color: i <= fouls
                                ? (fouls >= 5
                                      ? fouledOut
                                      : fouls == 4
                                      ? foulTrouble
                                      : foreground)
                                : foreground.withValues(alpha: .2),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: foreground,
                          decoration: fouls >= 5 || red > 0
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                if (points != null && points != 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Text(
                      '$points',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: foreground.withValues(alpha: .75),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget teamColumn(String team) {
    final list = players(team);
    final perPlayer = football ? footballStats(team) : const {};
    final tiles = [
      tile(team, null, s[team]['short']),
      for (final p in list)
        tile(
          team,
          p['id'],
          (p['number'] ?? '').isNotEmpty ? p['number'] : p['name'],
          fouls: (stats(team, p['id'])['pf'] ?? 0) as int,
          football: perPlayer[p['id']] ?? const {},
        ),
    ];
    return SizedBox(
      width: 84,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Up to six tiles share the height; longer squads scroll.
          // Football: eleven on the pitch, so tiles keep a fixed height and scroll.
          final height = football
              ? 52.0
              : (constraints.maxHeight / 6).clamp(48.0, 120.0);
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final tile in tiles) SizedBox(height: height, child: tile),
            ],
          );
        },
      ),
    );
  }

  Widget actionButton(ConsoleAction action, {bool wide = false}) {
    final selected = pending == action.id;
    final active = enabled(action.id);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: selected ? action.accent : const Color(0xff1f2937),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: active
              ? () => setState(() {
                  pending = selected ? null : action.id;
                  freeThrows = null;
                })
              : null,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border(
                bottom: BorderSide(color: action.accent, width: 4),
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  action.label,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: active
                        ? (selected ? readableOn(action.accent) : Colors.white)
                        : Colors.white30,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget actionPanel() {
    final a = {for (final action in actions) action.id: action};
    Widget row(List<Widget> children) => Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in children) Expanded(child: c)],
      ),
    );
    final undo = Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: const Color(0xff1f2937),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: widget.onUndo,
          child: Tooltip(
            message: t('undo'),
            child: Icon(
              Icons.undo,
              size: 30,
              color: widget.onUndo == null ? Colors.white30 : null,
            ),
          ),
        ),
      ),
    );
    if (football) {
      return SizedBox(
        width: 176,
        child: Column(
          children: [
            row([actionButton(a['goal']!)]),
            row([actionButton(a['yellow']!), actionButton(a['red']!)]),
            row([actionButton(a['penalty']!)]),
            row([actionButton(a['foul']!), actionButton(a['free_kick']!)]),
            row([undo]),
            row([actionButton(a['subs']!)]),
          ],
        ),
      );
    }
    return SizedBox(
      width: 176,
      child: Column(
        children: [
          row([actionButton(a['ft']!)]),
          row([actionButton(a['2pt']!)]),
          row([actionButton(a['3pt']!)]),
          row([actionButton(a['foul']!), actionButton(a['tech']!)]),
          row([actionButton(a['reb']!), actionButton(a['timeout']!)]),
          row([undo, actionButton(a['subs']!)]),
        ],
      ),
    );
  }

  String targetLabel(String team, String? playerId) {
    if (playerId == null) return s[team]['short'];
    final player = (s[team]['squad'] as List? ?? [])
        .where((p) => p['id'] == playerId)
        .firstOrNull;
    return player == null || (player['number'] ?? '').isEmpty
        ? s[team]['short']
        : '${s[team]['short']} #${player['number']}';
  }

  Widget freeThrowBar() {
    final (team, player) = freeThrows!;
    return Container(
      color: const Color(0xff16301f),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${t('console.ft')} · ${targetLabel(team, player)}',
              style: const TextStyle(
                color: Color(0xff22c55e),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(80, 40),
              backgroundColor: const Color(0xff22c55e),
            ),
            onPressed: widget.canTap
                ? () => widget.onAction('ft_hit', team, player)
                : null,
            child: Text(t('console.ft_hit')),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(80, 40)),
            onPressed: widget.canTap
                ? () => widget.onAction('ft_miss', team, player)
                : null,
            child: Text(t('console.ft_miss')),
          ),
          IconButton(
            tooltip: t('close'),
            onPressed: () => setState(() => freeThrows = null),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget middlePanel() {
    final pendingLabel = actions
        .where((a) => a.id == pending)
        .map((a) => a.label)
        .firstOrNull;
    return Container(
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xff151e2a),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                for (var i = 0; i < widget.tabs.length; i++)
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        backgroundColor: tab == i
                            ? const Color(0xff2b3a4d)
                            : null,
                        shape: const RoundedRectangleBorder(),
                      ),
                      onPressed: () => setState(() => tab = i),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.tabs[i].$1,
                          style: TextStyle(
                            fontWeight: tab == i ? FontWeight.w800 : null,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (penalty != null)
            Container(
              color: const Color(0xff3a2a16),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${t('console.penalty_outcome')} · ${s[penalty!.$1]['short']}',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 40),
                      backgroundColor: const Color(0xff22c55e),
                    ),
                    onPressed: widget.canTap
                        ? () {
                            final (team, player) = penalty!;
                            setState(() => penalty = null);
                            widget.onAction('penalty_goal', team, player);
                          }
                        : null,
                    child: Text(t('console.goal')),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(72, 40),
                    ),
                    onPressed: () => setState(() => penalty = null),
                    child: Text(t('console.penalty_missed')),
                  ),
                ],
              ),
            ),
          if (freeThrows != null) freeThrowBar(),
          if (pendingLabel == null && hint)
            Container(
              color: const Color(0xff3a3216),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Text(
                t('console.pick_action'),
                style: const TextStyle(
                  color: Colors.orange,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (pendingLabel != null)
            Container(
              color: const Color(0xff3a3216),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$pendingLabel · ${t('console.pick_player')}',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => pending = null),
                    child: const Icon(Icons.close, color: Colors.orange),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          // IndexedStack keeps every tab alive, so unsaved Team edits survive
          // switching tabs.
          Expanded(
            child: IndexedStack(
              index: tab.clamp(0, widget.tabs.length - 1),
              children: [for (final entry in widget.tabs) entry.$2],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget side(Widget child) =>
        Visibility(visible: !editing, maintainState: true, child: child);
    return ColoredBox(
      color: consoleBackground,
      child: Column(
        children: [
          side(header()),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  side(teamColumn('home')),
                  side(teamColumn('away')),
                  Expanded(
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (focused) =>
                          setState(() => editing = focused),
                      child: KeyedSubtree(key: middleKey, child: middlePanel()),
                    ),
                  ),
                  side(actionPanel()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
