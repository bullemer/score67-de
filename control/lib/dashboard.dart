import 'tennis.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'account.dart';
import 'dates.dart';
import 'device_link.dart';
import 'fixture_import.dart';
import 'game_editor.dart';

typedef DashboardApi =
    Future<dynamic> Function(String, String, Map<String, dynamic>?);

Future<String?> _noLogo() async => null;

class Dashboard extends StatefulWidget {
  final DashboardApi api;
  final String Function(String) t;
  final void Function(String) navigate;
  final int periods, minutes;

  /// The saved basketball default format (e.g. 8 × 5).
  final int basketballPeriods, basketballMinutes;
  final String language;

  /// Image picker for team logos (browser only; null hides logo upload).
  final Future<String?> Function() pickLogo;

  /// Opens an external link in a new tab (browser only; null hides the link).
  final void Function(String)? openLink;

  /// Page origin for connect links; empty hides the connect card.
  final String origin;

  /// Code from a connect link that opened this page (#connect=…).
  final String? connectCode;

  /// System share sheet for the connect link (false = not available).
  final Future<bool> Function(String url)? share;
  const Dashboard({
    super.key,
    this.origin = '',
    this.connectCode,
    this.share,
    this.pickLogo = _noLogo,
    this.openLink,
    required this.api,
    required this.t,
    required this.navigate,
    required this.periods,
    required this.minutes,
    this.basketballPeriods = 4,
    this.basketballMinutes = 10,
    this.language = 'de',
  });
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  List<dynamic> boards = [];
  int browsers = 0;
  String filter = 'current', error = '';
  bool showOlder = false;
  bool loading = true, busy = false, online = false, refreshing = false;
  Map<String, dynamic>? pending;
  Timer? timer;
  String t(String key) => widget.t(key);
  bool get enabled => online && !busy && pending == null;

  @override
  void initState() {
    super.initState();
    final code = widget.connectCode;
    if (code != null) {
      joinFromLink(code);
    } else {
      refresh();
    }
    timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!busy) refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  /// A connect link opened this page: join that list, then show it.
  Future<void> joinFromLink(String code) async {
    for (var attempt = 0; mounted; attempt++) {
      try {
        final result = await widget.api('/api/device/join', 'POST', {
          'code': code,
        });
        joined(result['boards'] as int);
        return;
      } catch (e) {
        if (!mounted) return;
        if (e.toString().startsWith('ApiError:')) {
          setState(() => error = 'link_invalid');
          unawaited(refresh());
          return;
        }
        // No connection (hall Wi-Fi): the link is still good, keep trying.
        // It is no longer in the address bar, so a reload could not.
        setState(() {
          error = 'network';
          loading = false;
        });
        await Future<void>.delayed(Duration(seconds: attempt < 5 ? 2 : 5));
      }
    }
  }

  void joined(int count) {
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t('device.joined').replaceAll('{n}', '$count'))),
      );
    }
    refresh();
  }

  Future<void> refresh() async {
    if (refreshing) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (mounted) await refresh();
      return;
    }
    refreshing = true;
    try {
      final result = await widget.api('/api/dashboard', 'GET', null);
      if (mounted) {
        setState(() {
          boards = result['boards'];
          browsers = (result['device']?['browsers'] as int?) ?? 0;
          online = true;
          loading = false;
          if (error == 'network') error = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          online = false;
          loading = false;
          error = 'network';
        });
      }
    } finally {
      refreshing = false;
    }
  }

  Future<void> write(
    String path,
    Map<String, dynamic> body, {
    String? navigate,
  }) async {
    if (!enabled) return;
    pending = {'path': path, 'body': body, 'navigate': navigate};
    await retry();
  }

  Future<void> retry() async {
    if (pending == null || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.api(
        pending!['path'],
        'POST',
        pending!['body'],
      );
      final destination = pending!['navigate'];
      pending = null;
      if (result != null && destination != null) {
        widget.navigate(destination);
        return;
      }
      await refresh();
    } catch (e) {
      // ApiError exposes a stable code; a transport failure keeps the original ID.
      final code = e.toString();
      if (code.startsWith('ApiError:')) {
        pending = null;
        error = code.substring(9);
        await refresh();
      } else {
        error = 'network';
        online = false;
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String category(dynamic game) {
    if (game['trashed'] == true) return 'trash';
    if (game['archived']) return 'archived';
    if (game['phase'] == 'finished') return 'completed';
    if (['period_running', 'break', 'shootout'].contains(game['phase'])) {
      return 'running';
    }
    return 'planned';
  }

  static const currentSections = ['running', 'planned'];
  static const recentFinished = 10;
  int count(String key) => boards
      .expand((b) => b['matches'] as List)
      .where((g) => category(g) == key)
      .length;

  List<Map<String, dynamic>> gamesIn(String filter) {
    final entries = <Map<String, dynamic>>[
      for (final board in boards)
        for (final game in board['matches'])
          if (category(game) == filter) {'board': board, 'game': game},
    ];
    entries.sort((a, b) {
      final first = a['game'], second = b['game'];
      if (filter == 'planned') {
        final int? firstDate = first['scheduled_at'];
        final int? secondDate = second['scheduled_at'];
        if (firstDate == null && secondDate != null) return 1;
        if (firstDate != null && secondDate == null) return -1;
        final order = (firstDate ?? first['created_at'] as int).compareTo(
          secondDate ?? second['created_at'] as int,
        );
        if (order != 0) return order;
      } else {
        final order = (second['scheduled_at'] ?? second['created_at'] as int)
            .compareTo(first['scheduled_at'] ?? first['created_at'] as int);
        if (order != 0) return order;
      }
      return (first['match_id'] as String).compareTo(
        second['match_id'] as String,
      );
    });
    return entries;
  }

  List<String> get shownSections => filter == 'current'
      ? currentSections
      : filter == 'archived'
      ? ['completed', 'archived']
      : [filter];

  /// In the combined list only the latest finished games, until asked.
  List<Map<String, dynamic>> limited(String section) {
    final games = gamesIn(section);
    return filter == 'current' && section == 'completed' && !showOlder
        ? games.take(recentFinished).toList()
        : games;
  }

  String dateLabel(int milliseconds) {
    return europeanDateTime(
      DateTime.fromMillisecondsSinceEpoch(milliseconds),
      widget.language,
    );
  }

  Future<bool> confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('confirm')),
            ),
          ],
        ),
      ) ??
      false;

  Future<DateTime?> chooseDateTime(DateTime current) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current.isBefore(now) ? now : current,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
      initialTime: TimeOfDay.fromDateTime(current),
    );
    return time == null
        ? null
        : DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> newGame(dynamic board) async {
    final home = TextEditingController(text: 'Home'),
        away = TextEditingController(text: 'Guest');
    final games = board['matches'] as List;
    final previous = games.isEmpty ? null : games.first;
    String sport = previous?['sport'] ?? 'football';
    final tennisFormat = <String, dynamic>{
      'category': previous?['tennis']?['category'] ?? 'women',
      'best_of': previous?['tennis']?['best_of'] ?? 3,
      'mode': previous?['tennis']?['mode'] ?? 'detailed',
      'final_tiebreak': previous?['tennis']?['final_tiebreak'] ?? 7,
    };
    int periods = previous?['period_count'] ?? widget.periods;
    int minutes = previous?['period_length_min'] ?? widget.minutes;
    bool scheduled = false;
    DateTime when = DateTime.now().add(const Duration(days: 1));
    String validation = '';
    Map<String, dynamic>? fixture;
    int? lineup;
    final shorts = {
      'home': TextEditingController(),
      'away': TextEditingController(),
    };
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('game.new')),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (sport != 'tennis')
                    FixtureImport(
                      api: widget.api,
                      t: t,
                      enabled: enabled,
                      open: widget.openLink,
                      onLoaded: (f) => update(() {
                        fixture = f;
                        sport = f['sport'];
                        final format = f['format'];
                        periods =
                            format?['period_count'] ??
                            (sport == 'basketball'
                                ? widget.basketballPeriods
                                : widget.periods);
                        minutes =
                            format?['period_length_min'] ??
                            (sport == 'basketball'
                                ? widget.basketballMinutes
                                : widget.minutes);
                        lineup = format?['lineup_size'];
                        for (final team in ['home', 'away']) {
                          final name = f[team]['name'] as String;
                          (team == 'home' ? home : away).text = name.length > 60
                              ? name.substring(0, 60)
                              : name;
                          shorts[team]!.text = f[team]['short'] ?? '';
                        }
                        final int? kickoff = f['kickoff'];
                        scheduled =
                            kickoff != null &&
                            kickoff > DateTime.now().millisecondsSinceEpoch;
                        if (scheduled) {
                          when = DateTime.fromMillisecondsSinceEpoch(kickoff!);
                        }
                      }),
                    ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(sport),
                    initialValue: sport,
                    items: [
                      for (final value in ['football', 'basketball', 'tennis'])
                        DropdownMenuItem(value: value, child: Text(t(value))),
                    ],
                    onChanged: (value) => update(() {
                      sport = value!;
                      periods = sport == 'basketball'
                          ? widget.basketballPeriods
                          : widget.periods;
                      minutes = sport == 'basketball'
                          ? widget.basketballMinutes
                          : widget.minutes;
                    }),
                  ),
                  if (sport == 'tennis')
                    TennisFormat(
                      value: tennisFormat,
                      t: t,
                      onChanged: (k, v) => update(() => tennisFormat[k] = v),
                    ),
                  if (sport == 'basketball')
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final format in [
                          [4, 10],
                          [4, 12],
                          [8, 5],
                          [2, 20],
                        ])
                          ChoiceChip(
                            label: Text('${format[0]} × ${format[1]}'),
                            selected:
                                periods == format[0] && minutes == format[1],
                            onSelected: (_) => update(() {
                              periods = format[0];
                              minutes = format[1];
                            }),
                          ),
                      ],
                    ),
                  if (sport == 'basketball') Text(t('basketball.pilot')),
                  const SizedBox(height: 12),
                  for (final team in ['home', 'away']) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: team == 'home' ? home : away,
                            maxLength: 60,
                            decoration: InputDecoration(
                              labelText: t(team),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        if (fixture != null) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 84,
                            child: TextField(
                              controller: shorts[team],
                              maxLength: 3,
                              textCapitalization: TextCapitalization.characters,
                              decoration: InputDecoration(
                                labelText: t('fixture.short'),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (team == 'home') const SizedBox(height: 12),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('game.schedule')),
                    value: scheduled,
                    onChanged: (v) => update(() => scheduled = v),
                  ),
                  if (!scheduled)
                    Text(
                      t('schedule.hint'),
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xfffbbf24),
                      ),
                    ),
                  if (scheduled)
                    OutlinedButton(
                      onPressed: () async {
                        final selected = await chooseDateTime(when);
                        if (selected != null && context.mounted) {
                          update(() => when = selected);
                        }
                      },
                      child: Text(dateLabel(when.millisecondsSinceEpoch)),
                    ),
                  if (scheduled)
                    Text(t('time.local'), style: const TextStyle(fontSize: 14)),
                  if (sport != 'tennis') Text('$periods × $minutes min'),
                  if (validation.isNotEmpty)
                    Text(
                      validation,
                      style: const TextStyle(color: Colors.orange),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (!enabled) {
                  update(() => validation = t('offline'));
                  return;
                }
                if (home.text.trim().isEmpty || away.text.trim().isEmpty) {
                  update(() => validation = t('error.invalid_value'));
                  return;
                }
                if (scheduled && !when.isAfter(DateTime.now())) {
                  update(() => validation = t('error.schedule_future'));
                  return;
                }
                final body = <String, dynamic>{
                  'command_id': const Uuid().v4(),
                  'home': home.text.trim(),
                  'away': away.text.trim(),
                  'scheduled_at': scheduled
                      ? when.millisecondsSinceEpoch
                      : null,
                  'sport': sport,
                  if (sport == 'tennis')
                    for (final entry in tennisFormat.entries)
                      'tennis_${entry.key}': entry.value
                  else ...{
                    'period_count': periods,
                    'period_length_min': minutes,
                  },
                  // The next game keeps the team's format (players on the field),
                  // unless the imported game suggests one.
                  if (lineup != null)
                    'lineup_size': lineup
                  else if (previous?['sport'] == sport &&
                      previous?['lineup_size'] != null)
                    'lineup_size': previous!['lineup_size'],
                  if (fixture != null) ...{
                    for (final team in ['home', 'away'])
                      if (shorts[team]!.text.trim().isNotEmpty)
                        '${team}_short': shorts[team]!.text.trim(),
                    'fixture': fixture,
                    'fixture_logos': fixture!['use_logos'] == true,
                  },
                };
                Navigator.pop(context);
                write('/api/s/${board['slug']}/matches', body);
              },
              child: Text(t(scheduled ? 'game.schedule' : 'game.create')),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    home.dispose();
    away.dispose();
  }

  Future<void> manage(
    dynamic board,
    dynamic game,
    String action, {
    Map<String, dynamic>? data,
  }) async {
    if (!enabled) return;
    // Moving to the trash is reversible; only a running game asks first.
    final ask =
        ['archive', 'delete'].contains(action) ||
        (action == 'trash' && category(game) == 'running');
    if (ask &&
        !await confirm(
          '${game['home']['name']} – ${game['away']['name']}\n\n${t(action == 'trash' ? 'game.delete.running.confirm' : 'game.$action.confirm')}',
        )) {
      return;
    }
    await write(
      '/api/s/${board['slug']}/matches/${game['match_id']}/commands',
      {
        'command_id': const Uuid().v4(),
        'expected_revision': game['revision'],
        'action': action,
        'data': data ?? {},
      },
      navigate: action == 'activate' ? '/s/${board['slug']}/control' : null,
    );
  }

  Widget gameCard(dynamic board, dynamic game) {
    final status = category(game);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xff344154)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${t(game['sport'] ?? 'football')} · ${t('games.$status')}',
            style: TextStyle(
              color: status == 'running'
                  ? const Color(0xffb6f36e)
                  : const Color(0xffb5c2d4),
              fontSize: 14,
            ),
          ),
          if (game['sport'] == 'tennis')
            Text(
              '${t('tennis.${game['tennis']?['category'] ?? 'women'}')} · ${t('tennis.best_of_${game['period_count']}')}',
            ),
          const SizedBox(height: 10),
          Text(
            '${game['home']['name']}  ${game['home']['score']} : ${game['away']['score']}  ${game['away']['name']}${game['shootout'] == null ? '' : ' (${t('shootout.result').replaceAll('{h}', '${game['shootout']['score'][0]}').replaceAll('{a}', '${game['shootout']['score'][1]}')})'}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          if ((board['description'] ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(board['description'], style: const TextStyle(fontSize: 15)),
          ],
          if (game['fixture'] != null) ...[
            const SizedBox(height: 4),
            FixtureFacts(
              fixture: game['fixture'],
              t: t,
              open: widget.openLink,
              fontSize: 13,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${t('scheduled')}: ${game['scheduled_at'] == null ? t('game.unscheduled') : dateLabel(game['scheduled_at'])}',
            style: const TextStyle(fontSize: 14, color: Color(0xffb5c2d4)),
          ),
          if (game['scheduled_at'] == null && status == 'planned')
            Text(
              t('schedule.hint'),
              style: const TextStyle(fontSize: 14, color: Color(0xfffbbf24)),
            ),
          Text(
            '${t('created')}: ${dateLabel(game['created_at'])}',
            style: const TextStyle(fontSize: 13, color: Color(0xff8d9bb0)),
          ),
          if (status == 'trash')
            Text(
              '${t('trash.reason.${game['trash_reason'] ?? 'manual'}')} · ${dateLabel(game['trashed_at'])} · ${t('trash.retention')}',
              style: const TextStyle(fontSize: 13, color: Color(0xffffb4ab)),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // One clear action per status instead of a generic "Controls".
              if (game['active'] && status == 'planned')
                FilledButton.icon(
                  onPressed: enabled
                      ? () => widget.navigate('/s/${board['slug']}/control')
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(t('game.start')),
                ),
              if (game['active'] && status == 'running')
                FilledButton.icon(
                  onPressed: enabled
                      ? () => widget.navigate('/s/${board['slug']}/control')
                      : null,
                  icon: const Icon(Icons.play_circle_outline),
                  label: Text(t('game.resume')),
                ),
              if (status == 'completed')
                FilledButton.icon(
                  onPressed: enabled
                      ? () => write(
                          '/api/s/${board['slug']}/matches/${game['match_id']}/commands',
                          {
                            'command_id': const Uuid().v4(),
                            'expected_revision': game['revision'],
                            'action': 'new_match',
                            'data': {},
                          },
                          navigate: '/s/${board['slug']}/control',
                        )
                      : null,
                  icon: const Icon(Icons.replay),
                  label: Text(t('game.restart')),
                ),
              if (game['active'] && status == 'completed')
                TextButton(
                  onPressed: enabled
                      ? () => widget.navigate('/s/${board['slug']}/control')
                      : null,
                  child: Text(t('game.correct')),
                ),
              if (status == 'trash') ...[
                FilledButton(
                  onPressed: enabled
                      ? () => manage(board, game, 'restore')
                      : null,
                  child: Text(t('game.restore')),
                ),
                TextButton(
                  onPressed: enabled
                      ? () => manage(board, game, 'delete')
                      : null,
                  child: Text(
                    t('trash.delete_forever'),
                    style: const TextStyle(color: Color(0xffffb4ab)),
                  ),
                ),
              ] else ...[
                if (!game['active'] &&
                    !game['archived'] &&
                    game['phase'] == 'pre_game')
                  FilledButton(
                    onPressed: enabled
                        ? () => manage(
                            board,
                            game,
                            'activate',
                            data: {
                              'expected_active_match': board['active_match'],
                            },
                          )
                        : null,
                    child: Text(t('game.start')),
                  ),
                // Every game: its Viewer (the active one without ?match=).
                OutlinedButton.icon(
                  onPressed: () => widget.navigate(
                    game['active']
                        ? '/s/${board['slug']}'
                        : '/s/${board['slug']}?match=${game['match_id']}',
                  ),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: Text(t('viewer')),
                ),
                OutlinedButton.icon(
                  onPressed: enabled
                      ? () async {
                          final saved = await showDialog<bool>(
                            context: context,
                            builder: (context) => GameEditorDialog(
                              api: widget.api,
                              t: t,
                              board: Map<String, dynamic>.from(board),
                              game: Map<String, dynamic>.from(game),
                              pickLogo: widget.pickLogo,
                            ),
                          );
                          if (saved == true) await refresh();
                        }
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(t('game.edit')),
                ),
                if (game['phase'] == 'pre_game' && !game['archived'])
                  OutlinedButton(
                    onPressed: enabled
                        ? () async {
                            final selected = await chooseDateTime(
                              DateTime.fromMillisecondsSinceEpoch(
                                game['scheduled_at'] ??
                                    DateTime.now()
                                        .add(const Duration(days: 1))
                                        .millisecondsSinceEpoch,
                              ),
                            );
                            if (selected != null) {
                              manage(
                                board,
                                game,
                                'schedule',
                                data: {
                                  'scheduled_at':
                                      selected.millisecondsSinceEpoch,
                                },
                              );
                            }
                          }
                        : null,
                    child: Text(t('game.reschedule')),
                  ),
                if (status != 'running' && !game['archived'])
                  OutlinedButton(
                    onPressed: enabled
                        ? () => manage(board, game, 'archive')
                        : null,
                    child: Text(t('game.archive')),
                  ),
                if (game['archived'])
                  FilledButton(
                    onPressed: enabled
                        ? () => manage(board, game, 'restore')
                        : null,
                    child: Text(t('game.restore')),
                  ),
                TextButton(
                  onPressed: enabled
                      ? () => manage(board, game, 'trash')
                      : null,
                  child: Text(
                    t('game.delete'),
                    style: const TextStyle(color: Color(0xffffb4ab)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              t('dashboard'),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: refresh,
            tooltip: t('refresh'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        t('dashboard.device'),
        style: const TextStyle(color: Color(0xffb5c2d4)),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: busy ? null : () => widget.navigate('/new'),
        child: Text(t('create')),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: () => widget.navigate('/live'),
        child: Text(t('live.title')),
      ),
      const SizedBox(height: 18),
      if (error.isNotEmpty)
        Text(
          t('error.$error'),
          style: const TextStyle(color: Color(0xffffb4ab)),
        ),
      if (pending != null) ...[
        Text(t('uncertain')),
        OutlinedButton(onPressed: busy ? null : retry, child: Text(t('check'))),
      ],
      if (loading)
        const Center(child: CircularProgressIndicator())
      else ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final key in ['current', 'archived', 'trash'])
              ChoiceChip(
                label: Text(
                  key == 'current'
                      ? t('games.current')
                      : '${t('games.$key')} (${count(key) + (key == 'archived' ? count('completed') : 0)})',
                ),
                selected: filter == key,
                onSelected: (_) => setState(() => filter = key),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (boards.isEmpty) Text(t('dashboard.empty')),
        if (boards.isNotEmpty && shownSections.every((k) => count(k) == 0))
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(t('games.filtered_empty')),
          ),
        for (final section in shownSections)
          if (count(section) > 0) ...[
            if (filter == 'current')
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '${t('games.$section')} (${count(section)})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            for (final entry in limited(section))
              Container(
                key: ValueKey('match:${entry['game']['match_id']}'),
                margin: const EdgeInsets.only(bottom: 20),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xff151e2a),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      [
                        entry['board']['slug'],
                        if ((entry['board']['creator'] ?? '').isNotEmpty)
                          t(
                            'creator.by',
                          ).replaceAll('{name}', entry['board']['creator']),
                      ].join(' · '),
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xffb5c2d4),
                      ),
                    ),
                    const SizedBox(height: 12),
                    gameCard(entry['board'], entry['game']),
                    if (!(entry['board']['matches'] as List).any(
                      (g) => category(g) == 'running',
                    ))
                      OutlinedButton(
                        onPressed: enabled
                            ? () => newGame(entry['board'])
                            : null,
                        child: Text(t('game.new')),
                      ),
                  ],
                ),
              ),
            if (limited(section).length < count(section))
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: OutlinedButton(
                  onPressed: () => setState(() => showOlder = true),
                  child: Text(t('dashboard.show_older')),
                ),
              ),
          ],
        if (boards.any((b) => (b['matches'] as List).isEmpty))
          ExpansionTile(
            title: Text(
              '${t('dashboard.empty_boards')} (${boards.where((b) => (b['matches'] as List).isEmpty).length})',
            ),
            subtitle: Text(t('dashboard.empty_boards.note')),
            children: [
              for (final board in boards)
                if ((board['matches'] as List).isEmpty)
                  ListTile(
                    title: Text(board['slug']),
                    subtitle: Text(
                      [
                        if ((board['description'] ?? '').isNotEmpty)
                          board['description'],
                        '${t('created')}: ${dateLabel(board['created_at'])}',
                      ].join('\n'),
                    ),
                    trailing: OutlinedButton(
                      onPressed: enabled ? () => newGame(board) : null,
                      child: Text(t('game.new')),
                    ),
                  ),
            ],
          ),
      ],
      // Below the games: they are what people open this page for.
      if (widget.origin.isNotEmpty)
        DeviceLinkCard(
          api: widget.api,
          t: widget.t,
          origin: widget.origin,
          browsers: browsers,
          onJoined: joined,
          share: widget.share,
        ),
      AccountPanel(
        api: widget.api,
        t: widget.t,
        language: widget.language,
        onChanged: refresh,
        card: true,
      ),
    ],
  );
}
