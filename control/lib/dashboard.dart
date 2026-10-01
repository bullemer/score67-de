import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

typedef DashboardApi =
    Future<dynamic> Function(String, String, Map<String, dynamic>?);

class Dashboard extends StatefulWidget {
  final DashboardApi api;
  final String Function(String) t;
  final void Function(String) navigate;
  final int periods, minutes;
  const Dashboard({
    super.key,
    required this.api,
    required this.t,
    required this.navigate,
    required this.periods,
    required this.minutes,
  });
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  List<dynamic> boards = [];
  String filter = 'all', error = '';
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
    if (game['archived']) return 'archived';
    if (game['phase'] == 'finished') return 'completed';
    if (['period_running', 'break'].contains(game['phase'])) return 'running';
    if (game['scheduled_at'] != null) return 'scheduled';
    return 'ready';
  }

  String dateLabel(int milliseconds) {
    final value = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final l = MaterialLocalizations.of(context);
    return '${l.formatMediumDate(value)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(value), alwaysUse24HourFormat: true)}';
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
      initialTime: TimeOfDay.fromDateTime(current),
    );
    return time == null
        ? null
        : DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> newGame(dynamic board) async {
    final home = TextEditingController(text: 'Home'),
        away = TextEditingController(text: 'Guest');
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
                  Text('${widget.periods} × ${widget.minutes} min'),
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
                  'period_count': widget.periods,
                  'period_length_min': widget.minutes,
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
    if (['archive', 'delete'].contains(action) &&
        !await confirm(t('game.$action.confirm'))) {
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
            t('games.$status'),
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
          const SizedBox(height: 8),
          Text(
            dateLabel(game['scheduled_at'] ?? game['created_at']),
            style: const TextStyle(fontSize: 14, color: Color(0xffb5c2d4)),
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
                                'scheduled_at': selected.millisecondsSinceEpoch,
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
              if (status != 'running')
                TextButton(
                  onPressed: enabled
                      ? () => manage(board, game, 'delete')
                      : null,
                  child: Text(
                    t('game.delete'),
                    style: const TextStyle(color: Color(0xffffb4ab)),
                  ),
                ),
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
              'all',
              'ready',
              'running',
              'scheduled',
              'completed',
              'archived',
            ])
              ChoiceChip(
                label: Text(
                  '${t('games.$key')} (${boards.expand((b) => b['matches'] as List).where((g) => key == 'all' || category(g) == key).length})',
                ),
                selected: filter == key,
                onSelected: (_) => setState(() => filter = key),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (boards.isEmpty) Text(t('dashboard.empty')),
        for (final board in boards)
          if (filter == 'all' ||
              (board['matches'] as List).any((g) => category(g) == filter))
            Container(
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
                    dateLabel(board['created_at']),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    board['slug'],
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xffb5c2d4),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: enabled ? () => newGame(board) : null,
                    child: Text(t('game.new')),
                  ),
                  const SizedBox(height: 12),
                  for (final game in board['matches'])
                    if (filter == 'all' || category(game) == filter)
                      gameCard(board, game),
                  if ((board['matches'] as List).isEmpty)
                    Text(t('games.empty')),
                ],
              ),
            ),
      ],
    ],
  );
}
