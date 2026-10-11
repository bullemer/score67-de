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

  /// Basketball clock at 0:00: the Play button ends the period instead.
  final bool periodOver;

  /// Before kickoff or in a break: the period an entry would open (label),
  /// and the period that just ended. Null while a period is running.
  final String? nextPeriod, endedPeriod;

  /// Opens [nextPeriod] (and starts its clock); false when refused.
  final Future<bool> Function() onStartNext;

  /// The running period, spelled out ("2. Viertel"), and whether its clock
  /// has never run (prepared, Play not pressed yet).
  final String currentPeriod;
  final bool clockNotStarted;
  final Future<bool> Function() onStartClock;

  /// Ends the running period early (clock stopped before 0:00, or forgotten).
  /// [skipEndsGame]: the button ends the match and confirms the final result
  /// itself, so no second tap is asked for.
  final VoidCallback? onSkipPeriod;
  final bool skipEndsGame;

  /// Tap on a player without an armed action: on court / on the bench.
  final void Function(String team, String playerId) onToggleActive;
  final int lineupMax;
  final Widget sync;
  final void Function(BuildContext) onMenu;
  final VoidCallback onToggleClock, onClockTap;
  final VoidCallback? onUndo;
  final void Function(String team) onSubstitutions;

  /// Records [action] for [team]; [playerId] null means the team itself.
  final void Function(String action, String team, String? playerId) onAction;
  final void Function(String team) onPossession;

  /// Double-tap editing of team and player names (only while no action is
  /// armed, so scoring taps are never delayed by double-tap detection).
  final void Function(String team) onEditTeam;
  final void Function(String team, String playerId) onEditPlayer;

  /// Tap on a header score: admin adjustment of a wrong score.
  final void Function(String team) onScoreTap;

  /// Penalty shootout: records the next kick (the server knows whose turn).
  final void Function(bool scored)? onShootoutKick;
  final List<(String, Widget)> tabs;
  const MatchConsole({
    super.key,
    required this.state,
    required this.t,
    required this.clock,
    required this.period,
    required this.running,
    this.periodOver = false,
    this.nextPeriod,
    this.endedPeriod,
    required this.onStartNext,
    this.currentPeriod = '',
    this.clockNotStarted = false,
    required this.onStartClock,
    this.onSkipPeriod,
    this.skipEndsGame = false,
    required this.onToggleActive,
    required this.lineupMax,
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
    required this.onScoreTap,
    this.onShootoutKick,
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
  String? hint;
  Timer? hintTimer, skipTimer;

  /// ⏭ waits for a second tap before it ends the period.
  bool skipArmed = false;

  /// An entry tapped in a break, waiting for "book to the ended period" or
  /// "start the next one".
  (String, String, String?)? deferred;

  /// The ended period the user chose to keep booking to during this break
  /// (free throws after the buzzer).
  int? stayPeriod;

  /// The period whose clock the user chose not to start for entries.
  int? stayClock;

  @override
  void dispose() {
    hintTimer?.cancel();
    skipTimer?.cancel();
    super.dispose();
  }

  void showHint(String text) {
    hintTimer?.cancel();
    setState(() => hint = text);
    hintTimer = Timer(
      const Duration(milliseconds: 2400),
      () => mounted ? setState(() => hint = null) : null,
    );
  }

  List<String> onCourt(String team) =>
      (s[team]['on_court'] as List? ?? []).cast<String>();

  /// Penalty awarded and waiting for its outcome: (team, player).
  (String, String?)? penalty;

  /// A free throw waiting for hit or miss: (team, player). Closes after each
  /// shot, so every free throw is tapped anew (no extra points by mistake).
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
      if (playerId != null && widget.canTap) {
        // No action armed: a player tap moves them on court / to the bench.
        final court = onCourt(team);
        if (!court.contains(playerId) && court.length >= widget.lineupMax) {
          showHint(
            t('console.court_full').replaceAll('{n}', '${widget.lineupMax}'),
          );
          return;
        }
        widget.onToggleActive(team, playerId);
        return;
      }
      showHint(t('console.pick_action')); // inline, instead of a banner
      return;
    }
    setState(() => pending = null);
    if (action == 'subs') {
      widget.onSubstitutions(team);
    } else {
      perform(action, team, playerId);
    }
  }

  /// Records an entry. Outside a running period (before kickoff, in a
  /// break) or while a prepared period's clock never ran, the entry waits for
  /// an inline answer: start the period/clock, or book it anyway (e.g. free
  /// throws after the buzzer). The answer holds for that period.
  Future<void> perform(
    String action,
    String team,
    String? playerId, {
    bool answered = false,
  }) async {
    final period = s['period'] as int;
    final outside =
        widget.nextPeriod != null &&
        (s['phase'] == 'pre_game' || stayPeriod != period);
    if (!answered &&
        (outside || (widget.clockNotStarted && stayClock != period))) {
      setState(() => deferred = (action, team, playerId));
      return;
    }
    if (action == 'ft') {
      // Hit or miss is chosen in the inline bar.
      setState(() => freeThrows = (team, playerId));
      return;
    }
    widget.onAction(action, team, playerId);
    if (action == 'penalty') setState(() => penalty = (team, playerId));
  }

  Widget deferredBar() {
    final (action, team, player) = deferred!;
    final label =
        actions.where((a) => a.id == action).map((a) => a.label).firstOrNull ??
        '';
    final preGame = s['phase'] == 'pre_game';
    final clockOnly = widget.nextPeriod == null;
    final question = clockOnly
        ? t('console.clock_not_started').replaceAll('{p}', widget.currentPeriod)
        : preGame
        ? t('console.not_started').replaceAll('{p}', widget.nextPeriod!)
        : t('console.break_question')
              .replaceAll('{ended}', widget.endedPeriod ?? '')
              .replaceAll('{p}', widget.nextPeriod!);
    Future<void> start() async {
      setState(() => deferred = null);
      final ok = clockOnly
          ? await widget.onStartClock()
          : await widget.onStartNext();
      // Booked at once: the console has not rebuilt with the new period yet.
      if (ok && mounted) perform(action, team, player, answered: true);
    }

    return Container(
      color: const Color(0xff3a2a16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '⚠ $question  ($label · ${targetLabel(team, player)})',
            style: const TextStyle(
              color: Colors.orange,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(72, 40),
                  backgroundColor: const Color(0xff16a34a),
                ),
                onPressed: widget.canWrite ? start : null,
                icon: const Icon(Icons.play_arrow, size: 20),
                label: Text(
                  clockOnly
                      ? t('console.start_clock')
                      : t(
                          'console.start_period',
                        ).replaceAll('{p}', widget.nextPeriod!),
                ),
              ),
              if (!preGame)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(72, 40),
                  ),
                  onPressed: () {
                    setState(() {
                      if (clockOnly) {
                        stayClock = s['period'] as int;
                      } else {
                        stayPeriod = s['period'] as int;
                      }
                      deferred = null;
                    });
                    perform(action, team, player, answered: true);
                  },
                  child: Text(
                    clockOnly
                        ? t('console.book_anyway')
                        : t(
                            'console.book_to',
                          ).replaceAll('{p}', widget.endedPeriod ?? ''),
                  ),
                ),
              TextButton(
                onPressed: () => setState(() => deferred = null),
                child: Text(t('cancel')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void skip() {
    if (widget.skipEndsGame || skipArmed) {
      skipTimer?.cancel();
      setState(() => skipArmed = false);
      widget.onSkipPeriod?.call();
      return;
    }
    setState(() => skipArmed = true);
    skipTimer = Timer(
      const Duration(seconds: 3),
      () => mounted ? setState(() => skipArmed = false) : null,
    );
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
      onTap: widget.canWrite ? () => widget.onScoreTap(team) : null,
    );
    return Container(
      color: headerBackground,
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          children: [
            Builder(
              builder: (buttonContext) => IconButton(
                tooltip: t('console.menu'),
                icon: const Icon(Icons.menu, size: 30),
                onPressed: () => widget.onMenu(buttonContext),
              ),
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
                if ((widget.nextPeriod != null && s['phase'] == 'break') ||
                    s['phase'] == 'finished')
                  Text(
                    t(
                      s['phase'] == 'finished'
                          ? 'console.final_short'
                          : 'console.break_short',
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: s['phase'] == 'finished'
                          ? const Color(0xff22c55e)
                          : Colors.orange,
                      height: 1,
                    ),
                  ),
                Text(
                  widget.period,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                    color: widget.nextPeriod != null
                        ? Colors.orange
                        : Colors.white,
                  ),
                ),
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
                      : widget.periodOver
                      ? const Color(0xffd97706)
                      : const Color(0xff16a34a),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: widget.canToggleClock ? widget.onToggleClock : null,
                child: Icon(
                  widget.running
                      ? Icons.stop
                      : widget.periodOver
                      ? Icons.skip_next
                      : Icons.play_arrow,
                  size: 34,
                  semanticLabel: t(
                    widget.running ? 'basketball.stop' : 'basketball.play',
                  ),
                ),
              ),
            ),
            if (widget.onSkipPeriod != null) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: t(
                  widget.skipEndsGame ? 'game_end' : 'console.skip_period',
                ),
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(52, 44),
                      backgroundColor: skipArmed || widget.skipEndsGame
                          ? const Color(0xffd97706)
                          : const Color(0xff374151),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: skip,
                    child: skipArmed
                        ? Text(
                            '${t('console.skip_confirm')} ⏭',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          )
                        : Icon(
                            widget.skipEndsGame
                                ? Icons.sports_score
                                : Icons.skip_next,
                            size: 30,
                          ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The whole squad: players on court first (bright), the bench below
  /// (dimmed), each group by shirt number. Without a lineup all are bright.
  (List<Map<String, dynamic>>, List<Map<String, dynamic>>) players(
    String team,
  ) {
    final squad = [
      for (final p in s[team]['squad'] as List? ?? [])
        Map<String, dynamic>.from(p),
    ];
    squad.sort(
      (a, b) => (int.tryParse(a['number'] ?? '') ?? 999).compareTo(
        int.tryParse(b['number'] ?? '') ?? 999,
      ),
    );
    final court = onCourt(team);
    if (court.isEmpty) return (squad, <Map<String, dynamic>>[]);
    return (
      squad.where((p) => court.contains(p['id'])).toList(),
      squad.where((p) => !court.contains(p['id'])).toList(),
    );
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
    bool bench = false,
    String? badge,
  }) {
    final teamColor = hexColor(s[team]['color']);
    // Bench players: the team colour faded into the console background.
    final color = bench
        ? Color.alphaBlend(teamColor.withValues(alpha: .3), consoleBackground)
        : teamColor;
    final foreground = bench
        ? Colors.white.withValues(alpha: .6)
        : readableOn(color);
    final armed = pending != null;
    final points = playerId == null
        ? null
        : this.football
        ? football['goals']
        : stats(team, playerId)['pts'];
    final corner = badge ?? (points == null || points == 0 ? null : '$points');
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
                if (corner != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Text(
                      corner,
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
    final (court, bench) = players(team);
    final perPlayer = football ? footballStats(team) : const {};
    Widget player(Map<String, dynamic> p, {bool bench = false}) => tile(
      team,
      p['id'],
      (p['number'] ?? '').isNotEmpty ? p['number'] : p['name'],
      fouls: (stats(team, p['id'])['pf'] ?? 0) as int,
      football: perPlayer[p['id']] ?? const {},
      bench: bench,
    );
    final lineup = onCourt(team);
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
              SizedBox(
                height: height,
                child: tile(
                  team,
                  null,
                  s[team]['short'],
                  badge: lineup.isEmpty ? null : '${lineup.length}',
                ),
              ),
              for (final p in court) SizedBox(height: height, child: player(p)),
              if (bench.isNotEmpty) const SizedBox(height: 8),
              for (final p in bench)
                SizedBox(
                  height: (height * .75).clamp(40.0, 72.0),
                  child: player(p, bench: true),
                ),
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
    if (football && s['phase'] == 'shootout') return shootoutPanel(undo);
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

  /// The shootout replaces the action buttons: whose kick it is, a mark per
  /// kick (● scored, ○ missed), GOAL / MISSED, undo.
  Widget shootoutPanel(Widget undo) {
    final shootout = Map<String, dynamic>.from(s['shootout'] ?? {});
    final kicks = (shootout['kicks'] as List? ?? []).cast<Map>();
    final next = shootout['next'] as String?;
    Widget marks(String team) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              s[team]['short'],
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: next == team ? Colors.white : Colors.white60,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 2,
              children: [
                for (final k in kicks.where((k) => k['team'] == team))
                  Text(
                    k['scored'] == true ? '●' : '○',
                    style: TextStyle(
                      fontSize: 18,
                      color: k['scored'] == true
                          ? const Color(0xff22c55e)
                          : const Color(0xffef4444),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    Widget kick(bool scored) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scored
                ? const Color(0xff16a34a)
                : const Color(0xffb91c1c),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          onPressed:
              widget.canTap && next != null && widget.onShootoutKick != null
              ? () => widget.onShootoutKick!(scored)
              : null,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              t(scored ? 'shootout.scored' : 'shootout.missed'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ),
    );
    return SizedBox(
      width: 176,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
            child: Text(
              next == null
                  ? t('shootout')
                  : t('shootout.next').replaceAll('{team}', s[next]['short']),
              style: const TextStyle(
                color: Colors.orange,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          marks('home'),
          marks('away'),
          kick(true),
          kick(false),
          Expanded(child: undo),
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
                ? () {
                    // One shot per FT tap: the next free throw is entered anew.
                    setState(() => freeThrows = null);
                    widget.onAction('ft_hit', team, player);
                  }
                : null,
            child: Text(t('console.ft_hit')),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(80, 40)),
            onPressed: widget.canTap
                ? () {
                    setState(() => freeThrows = null);
                    widget.onAction('ft_miss', team, player);
                  }
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
          // Hidden while typing: in landscape the keyboard leaves little room.
          if (!editing)
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
          if (deferred != null) deferredBar(),
          if (pendingLabel == null && hint != null)
            Container(
              color: const Color(0xff3a3216),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Text(
                hint!,
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
