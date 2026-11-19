import 'dart:async';

import 'package:flutter/material.dart';

import 'match_console.dart';

/// Basketball console built around who has the ball.
///
/// Header: both teams with the possession arrow between them, score, period,
/// clock and Start/Stop. Giving a team the ball (arrow or team name) puts the
/// ball in play: a stopped clock starts and runs until Stop is pressed.
/// Scoring tab: the players of the team with the ball. Action and player may
/// be tapped in either order. Fouls and rebounds show the defending team
/// first; a defensive rebound hands the ball over.
///
/// Reads its game data and callbacks from [base], the classic console's
/// configuration, so both views always behave the same towards the server.
class BallConsole extends StatefulWidget {
  final MatchConsole base;
  final void Function(String team) onAddPlayer;

  /// The newest entry of the game flow, shown next to the cards.
  final String? lastEntry;
  const BallConsole({
    super.key,
    required this.base,
    required this.onAddPlayer,
    this.lastEntry,
  });

  @override
  State<BallConsole> createState() => BallConsoleState();
}

class BallAction {
  final String id, label;
  final Color accent;
  const BallAction(this.id, this.label, this.accent);
}

class BallConsoleState extends State<BallConsole> {
  /// Action waiting for a player, or player waiting for an action.
  String? armed;
  (String, String?)? picked;

  /// Team whose cards are shown when it is not the team with the ball.
  String? shown;
  int tab = 0;
  bool editing = false, skipArmed = false;
  String? hint;
  Timer? hintTimer, skipTimer;

  /// Entry held back while its period (or clock) has not started.
  (String, String, String?)? deferred;
  int? stayPeriod, stayClock;
  final middleKey = GlobalKey();

  MatchConsole get c => widget.base;
  Map<String, dynamic> get s => c.state;
  String t(String key) => c.t(key);
  String? get ball => s['possession'] as String?;
  String get shownTeam => shown ?? ball ?? 'home';
  String other(String team) => team == 'home' ? 'away' : 'home';

  /// Fouls and rebounds are mostly the defending team's.
  static const defensive = {'foul', 'unsp', 'reb'};
  static const green = Color(0xff22c55e),
      grey = Color(0xff94a3b8),
      red = Color(0xffdc2626);

  void showTab(int index) => setState(() => tab = index);

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
      const Duration(milliseconds: 2600),
      () => mounted ? setState(() => hint = null) : null,
    );
  }

  List<List<BallAction>> get rows => [
    [
      BallAction('ft_hit', t('ball.made1'), green),
      BallAction('ft_miss', t('ball.miss1'), grey),
    ],
    [
      BallAction('2pt', t('ball.made2'), const Color(0xff2563eb)),
      BallAction('miss2', t('ball.miss2'), grey),
    ],
    [
      BallAction('3pt', t('ball.made3'), const Color(0xfff97316)),
      BallAction('miss3', t('ball.miss3'), grey),
    ],
    [
      BallAction('foul', t('console.foul'), red),
      BallAction('tech', t('console.tech'), red),
    ],
    [
      BallAction('unsp', t('console.unsp'), red),
      BallAction('timeout', t('console.timeout'), grey),
    ],
    [
      BallAction('ast', t('ball.assist'), const Color(0xffa855f7)),
      BallAction('reb', t('console.reb'), const Color(0xffa855f7)),
    ],
  ];

  String labelOf(String id) =>
      rows.expand((r) => r).firstWhere((a) => a.id == id).label;

  bool enabled(String id) =>
      c.canTap && !(id == 'foul' && s['foul_mode'] == 'off');

  /// The ball goes to [team] and is in play: a stopped clock starts.
  void giveBall(String team) {
    if (!c.canTap) return;
    if (ball != team) c.onPossession(team);
    setState(() => shown = null);
    if (s['phase'] == 'period_running' &&
        s['clock']?['enabled'] == true &&
        !c.running &&
        !c.periodOver) {
      c.onStartClock();
    }
  }

  void tapAction(String id) {
    if (!enabled(id)) return;
    final target = picked;
    if (target != null) {
      book(id, target.$1, target.$2);
      return;
    }
    setState(() {
      armed = armed == id ? null : id;
      final holder = ball;
      shown = armed != null && holder != null && defensive.contains(id)
          ? other(holder)
          : null;
    });
  }

  void tapCard(String team, String? playerId) {
    if (!c.canTap) return;
    final action = armed;
    if (action != null) {
      book(action, team, playerId);
      return;
    }
    setState(() {
      final same = picked?.$1 == team && picked?.$2 == playerId;
      picked = same ? null : (team, playerId);
    });
  }

  /// Long press: on court / to the bench.
  void toggleCourt(String team, String playerId) {
    if (!c.canTap) return;
    final court = (s[team]['on_court'] as List? ?? []).cast<String>();
    if (!court.contains(playerId) && court.length >= c.lineupMax) {
      showHint(t('console.court_full').replaceAll('{n}', '${c.lineupMax}'));
      return;
    }
    c.onToggleActive(team, playerId);
  }

  Map<String, dynamic> stats(String team, String id) {
    for (final row in s[team]['statistics']?['players'] as List? ?? []) {
      if (row['id'] == id) return Map<String, dynamic>.from(row);
    }
    return {};
  }

  String targetLabel(String team, String? playerId) {
    final player = (s[team]['squad'] as List? ?? [])
        .where((p) => p['id'] == playerId)
        .firstOrNull;
    return player == null || '${player['number'] ?? ''}'.isEmpty
        ? '${s[team]['short']}'
        : '${s[team]['short']} #${player['number']}';
  }

  void book(
    String action,
    String team,
    String? playerId, {
    bool answered = false,
  }) {
    final period = s['period'] as int;
    final outside =
        c.nextPeriod != null &&
        (s['phase'] == 'pre_game' || stayPeriod != period);
    if (!answered && (outside || (c.clockNotStarted && stayClock != period))) {
      setState(() {
        deferred = (action, team, playerId);
        armed = null;
        picked = null;
      });
      return;
    }
    if (playerId != null) {
      final fouls = (stats(team, playerId)['pf'] ?? 0) as int;
      String? key;
      if ((action == 'tech' || action == 'unsp') &&
          technicalFouls(s, team, playerId) >= 1) {
        key = 'console.ejected';
      } else if ((action == 'tech' ||
              action == 'unsp' ||
              (action == 'foul' && s['foul_mode'] != 'team')) &&
          fouls == 4) {
        key = 'console.fifth_foul';
      }
      if (key != null) {
        showHint(
          t(key).replaceAll('{p}', targetLabel(team, playerId).split(' ').last),
        );
      }
    }
    c.onAction(action, team, action == 'timeout' ? null : playerId);
    // A rebound by the other team: they have the ball now.
    final holder = ball;
    if (action == 'reb' && holder != null && team != holder) giveBall(team);
    setState(() {
      armed = null;
      picked = null;
      shown = null;
    });
  }

  void skip() {
    if (c.skipEndsGame || skipArmed) {
      skipTimer?.cancel();
      setState(() => skipArmed = false);
      c.onSkipPeriod?.call();
      return;
    }
    setState(() => skipArmed = true);
    skipTimer = Timer(
      const Duration(seconds: 3),
      () => mounted ? setState(() => skipArmed = false) : null,
    );
  }

  Widget teamHead(String team) {
    final has = ball == team;
    final color = hexColor(s[team]['color']);
    final counters = s[team]['counters'] ?? {};
    final (used, allowed) = timeoutWindow(s, team);
    final fouls = (counters['team_fouls'] ?? 0) as int;
    final name = InkWell(
      onTap: () => giveBall(team),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${s[team]['short']}',
              style: TextStyle(
                fontSize: has ? 26 : 20,
                fontWeight: has ? FontWeight.w900 : FontWeight.w500,
                color: has ? Colors.white : Colors.white60,
              ),
            ),
            Text(
              'F$fouls · TO $used${allowed == null ? '' : '/$allowed'}',
              style: TextStyle(
                fontSize: 11,
                color: fouls >= 5 ? fouledOut : Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
    final score = InkWell(
      onTap: c.canWrite ? () => c.onScoreTap(team) : null,
      child: Container(
        width: 62,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${s[team]['score']}'.padLeft(2, '0'),
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w900,
            color: readableOn(color),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
    return Row(children: team == 'home' ? [score, name] : [name, score]);
  }

  Widget header() {
    final holder = ball;
    final stopped =
        s['phase'] == 'period_running' &&
        s['clock']?['enabled'] == true &&
        !c.running &&
        !c.periodOver;
    return Container(
      color: headerBackground,
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          children: [
            Builder(
              builder: (context) => IconButton(
                onPressed: () => c.onMenu(context),
                icon: const Icon(Icons.menu),
              ),
            ),
            teamHead('home'),
            // The arrow points the way the team with the ball attacks.
            SizedBox(
              width: 60,
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: const Color(0xff1f2937),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: c.canTap
                    ? () => giveBall(holder == null ? 'home' : other(holder))
                    : null,
                child: Icon(
                  holder == null
                      ? Icons.swap_horiz
                      : holder == 'home'
                      ? Icons.arrow_forward_ios
                      : Icons.arrow_back_ios_new,
                  size: 28,
                  semanticLabel: t('possession'),
                ),
              ),
            ),
            teamHead('away'),
            const SizedBox(width: 10),
            Text(
              c.period,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xffffb020),
              ),
            ),
            GestureDetector(
              onTap: c.onClockTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  c.clock,
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    // A clock standing still during play must be noticed.
                    color: stopped ? foulTrouble : null,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            c.sync,
            const SizedBox(width: 4),
            SizedBox(
              width: 96,
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: c.running
                      ? red
                      : c.periodOver
                      ? const Color(0xffd97706)
                      : const Color(0xff16a34a),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: c.canToggleClock ? c.onToggleClock : null,
                child: c.periodOver && !c.running
                    ? const Icon(Icons.skip_next, size: 30)
                    : Text(
                        t(c.running ? 'basketball.stop' : 'basketball.play'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
              ),
            ),
            if (c.onSkipPeriod != null) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: t(c.skipEndsGame ? 'game_end' : 'console.skip_period'),
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      backgroundColor: skipArmed
                          ? const Color(0xffd97706)
                          : const Color(0xff374151),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: c.canWrite ? skip : null,
                    child: Icon(
                      c.skipEndsGame ? Icons.flag : Icons.skip_next,
                      size: 26,
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

  Widget actionButton(BallAction a) {
    final selected = armed == a.id;
    final active = enabled(a.id);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Material(
          color: selected ? a.accent : const Color(0xff1f2937),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: active ? () => tapAction(a.id) : null,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border(bottom: BorderSide(color: a.accent, width: 4)),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    a.label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: !active
                          ? Colors.white30
                          : selected
                          ? readableOn(a.accent)
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget actionPanel() => SizedBox(
    width: 206,
    child: Column(
      children: [
        for (final row in rows)
          Expanded(
            child: Row(children: [for (final a in row) actionButton(a)]),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Material(
              color: const Color(0xff1f2937),
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: c.onUndo,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.undo,
                        size: 20,
                        color: c.onUndo == null ? Colors.white30 : null,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        t('ball.undo'),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: c.onUndo == null ? Colors.white30 : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget card(String team, Map<String, dynamic>? player, {bool bench = false}) {
    final id = player?['id'] as String?;
    final teamColor = hexColor(s[team]['color']);
    final selected = picked?.$1 == team && picked?.$2 == id && picked != null;
    final lineup = (s[team]['on_court'] as List? ?? []);
    final fouls = id == null ? 0 : (stats(team, id)['pf'] ?? 0) as int;
    final points = id == null ? 0 : (stats(team, id)['pts'] ?? 0) as int;
    final out = id != null && (fouls >= 5 || technicalFouls(s, team, id) >= 2);
    final number = '${player?['number'] ?? ''}';
    final name = '${player?['name'] ?? ''}';
    final background = bench
        ? Color.alphaBlend(teamColor.withValues(alpha: .28), consoleBackground)
        : teamColor;
    final foreground = bench
        ? Colors.white.withValues(alpha: .65)
        : readableOn(background);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => tapCard(team, id),
          onLongPress: id == null ? null : () => toggleCourt(team, id),
          child: Container(
            width: 92,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? Colors.white : Colors.transparent,
                width: 3,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    id == null
                        ? '${s[team]['short']}'
                        : number.isNotEmpty
                        ? number
                        : name,
                    style: TextStyle(
                      fontSize: 26,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                      color: foreground,
                      decoration: out ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (id != null && lineup.isNotEmpty)
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: bench ? fouledOut : green,
                          shape: BoxShape.circle,
                        ),
                      ),
                    Flexible(
                      child: Text(
                        id == null
                            ? t('ball.team')
                            : [
                                if (number.isNotEmpty && name.isNotEmpty) name,
                                if (points > 0) '$points',
                                if (fouls > 0) 'F$fouls',
                              ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: foreground,
                          fontWeight: fouls >= 4 ? FontWeight.w800 : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget scoringTab() {
    final team = shownTeam;
    final squad = [
      for (final p in s[team]['squad'] as List? ?? [])
        Map<String, dynamic>.from(p),
    ];
    squad.sort(
      (a, b) => (int.tryParse('${a['number']}') ?? 999).compareTo(
        int.tryParse('${b['number']}') ?? 999,
      ),
    );
    final court = (s[team]['on_court'] as List? ?? []).cast<String>();
    final playing = court.isEmpty
        ? squad
        : squad.where((p) => court.contains(p['id'])).toList();
    final bench = court.isEmpty
        ? <Map<String, dynamic>>[]
        : squad.where((p) => !court.contains(p['id'])).toList();
    Widget chip(String side) {
      final active = side == team;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => shown = side == ball ? null : side),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: active ? const Color(0xff2b3a4d) : null,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (side == ball)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.sports_basketball,
                      size: 14,
                      color: Color(0xfff97316),
                    ),
                  ),
                Text(
                  '${s[side]['short']}',
                  style: TextStyle(fontWeight: active ? FontWeight.w800 : null),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final waiting = armed != null
        ? '${labelOf(armed!)} → ${t('ball.pick_player')}'
        : picked != null
        ? '${targetLabel(picked!.$1, picked!.$2)} → ${t('ball.pick_action')}'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 6, 2),
          child: Row(
            children: [
              chip('home'),
              chip('away'),
              Expanded(
                child: Text(
                  waiting ?? (ball == null ? t('ball.who_has_it') : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (waiting != null)
                InkWell(
                  onTap: () => setState(() {
                    armed = null;
                    picked = null;
                    shown = null;
                  }),
                  child: const Icon(Icons.close, color: Colors.orange),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Wrap(
              children: [
                card(team, null),
                for (final p in playing) card(team, p),
                for (final p in bench) card(team, p, bench: true),
                Padding(
                  padding: const EdgeInsets.all(3),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      fixedSize: const Size(92, 60),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: c.canWrite
                        ? () => widget.onAddPlayer(team)
                        : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(t('ball.add_player')),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.lastEntry != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
            child: Text(
              widget.lastEntry!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget deferredBar() {
    final (action, team, player) = deferred!;
    final preGame = s['phase'] == 'pre_game';
    final clockOnly = c.nextPeriod == null;
    final question = clockOnly
        ? t('console.clock_not_started').replaceAll('{p}', c.currentPeriod)
        : preGame
        ? t('console.not_started').replaceAll('{p}', c.nextPeriod!)
        : t('console.break_question')
              .replaceAll('{ended}', c.endedPeriod ?? '')
              .replaceAll('{p}', c.nextPeriod!);
    Future<void> start() async {
      setState(() => deferred = null);
      final ok = clockOnly ? await c.onStartClock() : await c.onStartNext();
      if (ok && mounted) book(action, team, player, answered: true);
    }

    return Container(
      color: const Color(0xff3a2a16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '⚠ $question  (${labelOf(action)} · ${targetLabel(team, player)})',
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
                onPressed: c.canWrite ? start : null,
                icon: const Icon(Icons.play_arrow, size: 20),
                label: Text(
                  clockOnly
                      ? t('console.start_clock')
                      : t(
                          'console.start_period',
                        ).replaceAll('{p}', c.nextPeriod!),
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
                    book(action, team, player, answered: true);
                  },
                  child: Text(
                    clockOnly
                        ? t('console.book_anyway')
                        : t(
                            'console.book_to',
                          ).replaceAll('{p}', c.endedPeriod ?? ''),
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

  Widget middlePanel() {
    final tabs = [(t('ball.scoring'), scoringTab()), ...c.tabs];
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
              height: 40,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(36, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          backgroundColor: tab == i
                              ? const Color(0xff2b3a4d)
                              : null,
                          shape: const RoundedRectangleBorder(),
                        ),
                        onPressed: () => setState(() => tab = i),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            tabs[i].$1,
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
          if (deferred != null) deferredBar(),
          if (hint != null)
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
          const Divider(height: 1),
          // IndexedStack keeps every tab alive, so unsaved Team edits survive
          // switching tabs.
          Expanded(
            child: IndexedStack(
              index: tab.clamp(0, tabs.length - 1),
              children: [for (final entry in tabs) entry.$2],
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
                  side(actionPanel()),
                  Expanded(
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (focused) =>
                          setState(() => editing = focused),
                      child: KeyedSubtree(key: middleKey, child: middlePanel()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
