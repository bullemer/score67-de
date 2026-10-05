import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'account.dart';
import 'dates.dart';
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
  const Dashboard({
    super.key,
    this.pickLogo = _noLogo,
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
  String filter = 'planned', error = '';
  bool loading = true, busy = false, online = false, refreshing = false;
  Map<String, dynamic>? pending;
  Timer? timer;
  String t(String key) => widget.t(key);
  bool get enabled => online && !busy && pending == null;

  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!busy) refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
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
    if (['period_running', 'break'].contains(game['phase'])) return 'running';
    return 'planned';
  }

  List<Map<String, dynamic>> get visibleGames {
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
    int periods = previous?['period_count'] ?? widget.periods;
    int minutes = previous?['period_length_min'] ?? widget.minutes;
    bool scheduled = false;
    DateTime when = DateTime.now().add(const Duration(days: 1));
    String validation = '';
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
                  DropdownButtonFormField<String>(
                    initialValue: sport,
                    items: [
                      for (final value in ['football', 'basketball'])
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
                  TextField(
                    controller: home,
                    maxLength: 60,
                    decoration: InputDecoration(
                      labelText: t('home'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: away,
                    maxLength: 60,
                    decoration: InputDecoration(
                      labelText: t('away'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
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
                  Text('$periods × $minutes min'),
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
                  'period_count': periods,
                  'period_length_min': minutes,
                  // The next game keeps the team's format (players on the field).
                  if (previous?['sport'] == sport &&
                      previous?['lineup_size'] != null)
                    'lineup_size': previous!['lineup_size'],
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
          const SizedBox(height: 10),
          Text(
            '${game['home']['name']}  ${game['home']['score']} : ${game['away']['score']}  ${game['away']['name']}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          if ((board['description'] ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(board['description'], style: const TextStyle(fontSize: 15)),
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
              if (game['active'] && !game['archived'])
                FilledButton(
                  onPressed: enabled
                      ? () => widget.navigate('/s/${board['slug']}/control')
                      : null,
                  child: Text(t('control')),
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
                    child: Text(t('game.use')),
                  ),
                if (game['phase'] == 'finished' || game['archived'])
                  OutlinedButton(
                    onPressed: () => widget.navigate(
                      '/s/${board['slug']}?match=${game['match_id']}',
                    ),
                    child: Text(t('game.view')),
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
      AccountPanel(
        api: widget.api,
        t: widget.t,
        language: widget.language,
        onChanged: refresh,
        card: true,
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
            for (final key in [
              'planned',
              'running',
              'completed',
              'archived',
              'trash',
            ])
              ChoiceChip(
                label: Text(
                  '${t('games.$key')} (${boards.expand((b) => b['matches'] as List).where((g) => category(g) == key).length})',
                ),
                selected: filter == key,
                onSelected: (_) => setState(() => filter = key),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (boards.isEmpty) Text(t('dashboard.empty')),
        if (boards.isNotEmpty &&
            !boards
                .expand((b) => b['matches'] as List)
                .any((g) => category(g) == filter))
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(t('games.filtered_empty')),
          ),
        for (final entry in visibleGames)
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
                  entry['board']['slug'],
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
                    onPressed: enabled ? () => newGame(entry['board']) : null,
                    child: Text(t('game.new')),
                  ),
              ],
            ),
          ),
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
    ],
  );
}
