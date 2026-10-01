import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dashboard.dart';
import 'squad.dart';
import 'basketball_statistics.dart';
import 'command_queue.dart';
import 'package:web/web.dart' as web;
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final release = jsonDecode(
    await rootBundle.loadString('assets/release.json'),
  );
  // FastAPI owns the public routes; /app/ is only the static asset prefix.
  setUrlStrategy(null);
  runApp(Score67(releaseLabel: release['label']));
}

class ApiError implements Exception {
  final String code;
  ApiError(this.code);
  @override
  String toString() => 'ApiError:$code';
}

class Score67 extends StatefulWidget {
  final String releaseLabel;
  const Score67({super.key, required this.releaseLabel});
  @override
  State<Score67> createState() => _Score67State();
}

class _Score67State extends State<Score67> {
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final stopwatch = Stopwatch()..start();
  Map<String, dynamic> words = {}, state = {};
  Map<String, dynamic>? draftLocation;
  String lang = 'en', slug = '', pin = '', error = '';
  bool dashboardPage = false;
  String basketballTeam = 'home';
  bool basketballCorrecting = false;
  bool get liveBasketball =>
      ready &&
      admin &&
      basketball &&
      !dashboardPage &&
      slug.isNotEmpty &&
      pin.isEmpty &&
      state['match_id'] != null;
  int defaultPeriods = 2, defaultMinutes = 45;
  String draftSport = 'football';
  int draftPeriods = 4, draftMinutes = 10;
  bool get basketball => state['sport'] == 'basketball';
  int get periodLengthMs =>
      ((state['period'] > state['period_count']
              ? state['overtime_length_min'] ?? 5
              : state['period_length_min'])
          as int) *
      60000;
  bool ready = false,
      admin = false,
      busy = false,
      connected = false,
      polling = false,
      refreshQueued = false;
  int serverAt = 0, anchorAt = 0, reconnectMs = 500, ticks = 0;
  // `state` is what the UI shows: the last server state plus queued taps.
  Map<String, dynamic> serverState = {};
  final List<Map<String, dynamic>> queue = [];
  final completers = <String, Completer<Map<String, dynamic>?>>{};
  bool sending = false;
  int retryMs = 500;
  web.WakeLockSentinel? wakeLock;
  Timer? refreshTimer, renderTimer, reconnectTimer, retryTimer;
  WebSocketChannel? channel;
  StreamSubscription? subscription;
  final pinInput = TextEditingController();
  final deviceName = TextEditingController(text: 'Browser');

  String t(String key) =>
      (words[key] ?? words['error.generic'] ?? key).toString();
  Uri uri(String path) => Uri.parse('${web.window.location.origin}$path');
  bool get canWrite => admin && connected && !busy && queue.isEmpty;
  bool get canTap => admin && !busy && state['match_id'] != null;
  int get now => serverAt + stopwatch.elapsedMilliseconds - anchorAt;
  List<dynamic> get events => state['events'] ?? [];

  @override
  void initState() {
    super.initState();
    final url = Uri.parse(web.window.location.href);
    dashboardPage = url.path == '/dashboard';
    try {
      final preferences = jsonDecode(
        web.window.localStorage.getItem('score67-settings') ?? '{}',
      );
      defaultPeriods = (preferences['periods'] as int? ?? 2).clamp(1, 12);
      defaultMinutes = (preferences['minutes'] as int? ?? 45).clamp(1, 60);
    } catch (_) {}
    final segments = url.pathSegments;
    if (segments.length == 3 &&
        segments[0] == 's' &&
        segments[2] == 'control') {
      slug = segments[1];
    }
    String? saved;
    try {
      saved = web.window.localStorage.getItem('score67-language');
    } catch (_) {}
    final language =
        url.queryParameters['lang'] ?? saved ?? web.window.navigator.language;
    lang = language.startsWith('de') ? 'de' : 'en';
    initialize();
  }

  Future<dynamic> api(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, uri(path));
    if (method != 'GET') {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body ?? {});
    }
    final client = http.Client();
    try {
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 8));
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 8));
      final data = jsonDecode(response.body);
      if (response.statusCode >= 400) {
        throw ApiError(data['error'] ?? 'generic');
      }
      return data;
    } finally {
      client.close();
    }
  }

  Future<void> initialize() async {
    try {
      words = Map<String, dynamic>.from(await api('/i18n/$lang.json'));
      if (slug.isNotEmpty) {
        await refresh();
        await checkAdmin();
        if (admin) {
          restoreQueue();
          await refresh();
        }
        connect();
        refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
          ticks++;
          unawaited(keepAwake());
          if (!connected || ticks % 7 == 0) {
            await refresh();
            if (admin) await checkAdmin();
          }
        });
        renderTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (mounted) setState(() {});
        });
      }
    } catch (_) {
      error = 'network';
    }
    if (mounted) setState(() => ready = true);
  }

  void navigate(String path) {
    final url = Uri.parse(path);
    web.window.location.assign(
      url
          .replace(queryParameters: {...url.queryParameters, 'lang': lang})
          .toString(),
    );
  }

  void updateLanguageUrl(String value) {
    final url = Uri.parse(web.window.location.href);
    web.window.history.replaceState(
      null,
      '',
      url
          .replace(queryParameters: {...url.queryParameters, 'lang': value})
          .toString(),
    );
  }

  Future<void> appSettings() async {
    String chosenLanguage = lang;
    final periods = TextEditingController(text: '$defaultPeriods');
    final minutes = TextEditingController(text: '$defaultMinutes');
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('app.settings')),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: chosenLanguage,
                    decoration: InputDecoration(labelText: t('language')),
                    items: const [
                      DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                    ],
                    onChanged: (value) =>
                        update(() => chosenLanguage = value ?? lang),
                  ),
                  const SizedBox(height: 18),
                  Text(t('app.defaults')),
                  field(t('period_count'), periods, numeric: true),
                  field(t('period_length'), minutes, numeric: true),
                  Text(t('app.local'), style: const TextStyle(fontSize: 14)),
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
              onPressed: () async {
                final p = int.tryParse(periods.text),
                    m = int.tryParse(minutes.text);
                if (p == null ||
                    p < 1 ||
                    p > 12 ||
                    m == null ||
                    m < 1 ||
                    m > 60) {
                  notify(t('error.invalid_value'));
                  return;
                }
                try {
                  final translated = await api('/i18n/$chosenLanguage.json');
                  web.window.localStorage.setItem(
                    'score67-settings',
                    jsonEncode({'periods': p, 'minutes': m}),
                  );
                  web.window.localStorage.setItem(
                    'score67-language',
                    chosenLanguage,
                  );
                  if (!mounted || !context.mounted) return;
                  setState(() {
                    defaultPeriods = p;
                    defaultMinutes = m;
                    lang = chosenLanguage;
                    words = Map<String, dynamic>.from(translated);
                  });
                  updateLanguageUrl(chosenLanguage);
                  Navigator.pop(context);
                  notify(t('saved'));
                } catch (_) {
                  notify(t('error.network'));
                }
              },
              child: Text(t('save')),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    periods.dispose();
    minutes.dispose();
  }

  Future<void> switchLanguage() async {
    final next = lang == 'de' ? 'en' : 'de';
    try {
      final data = await api('/i18n/$next.json');
      try {
        web.window.localStorage.setItem('score67-language', next);
      } catch (_) {}
      if (mounted) {
        setState(() {
          lang = next;
          words = Map<String, dynamic>.from(data);
        });
        updateLanguageUrl(next);
      }
    } catch (_) {
      notify(t('error.network'));
    }
  }

  void accept(Map<String, dynamic> data, [int latency = 0]) {
    final previous = serverState;
    if (previous.isNotEmpty && data['server_now'] < previous['server_now']) {
      return;
    }
    if (previous.isNotEmpty &&
        data['match_id'] == previous['match_id'] &&
        data['revision'] < previous['revision']) {
      return;
    }
    serverState = data;
    state = optimisticState(serverState, queue);
    serverAt = data['server_now'] + latency;
    anchorAt = stopwatch.elapsedMilliseconds;
    connected = true;
    if (mounted) setState(() {});
    if (queue.isNotEmpty && !sending) unawaited(pump());
  }

  String get queueKey => 'score67-queue:$slug';

  void queueChanged() {
    try {
      web.window.localStorage.setItem(queueKey, jsonEncode(queue));
    } catch (_) {}
    if (serverState.isNotEmpty) state = optimisticState(serverState, queue);
    if (mounted) setState(() {});
  }

  /// Taps recorded before a reload or crash are replayed with their original
  /// command IDs, so the server never counts them twice.
  void restoreQueue() {
    try {
      final saved = jsonDecode(
        web.window.localStorage.getItem(queueKey) ?? '[]',
      );
      queue
        ..clear()
        ..addAll([
          for (final item in saved as List)
            if (item is Map && queueable('${item['action']}'))
              Map<String, dynamic>.from(item),
        ]);
    } catch (_) {}
  }

  Future<void> keepAwake() async {
    if (!admin || slug.isEmpty || web.document.visibilityState != 'visible') {
      return;
    }
    if (wakeLock != null && !wakeLock!.released) return;
    try {
      wakeLock = await web.window.navigator.wakeLock.request('screen').toDart;
    } catch (_) {
      // Unsupported browsers and denied requests keep the normal screen timeout.
    }
  }

  Future<void> refresh() async {
    if (polling) return;
    polling = true;
    final start = stopwatch.elapsedMilliseconds;
    try {
      accept(
        Map<String, dynamic>.from(
          await api('/api/s/$slug/${admin ? 'control-state' : 'state'}'),
        ),
        (stopwatch.elapsedMilliseconds - start) ~/ 2,
      );
    } on ApiError catch (e) {
      connected = false;
      error = e.code;
    } catch (_) {
      connected = false;
    }
    polling = false;
    if (refreshQueued && mounted) {
      refreshQueued = false;
      unawaited(refresh());
    }
    if (mounted) setState(() {});
  }

  Future<void> checkAdmin() async {
    try {
      await api('/api/s/$slug/admins');
      admin = true;
    } on ApiError catch (e) {
      if (e.code == 'admin_required') admin = false;
    } catch (_) {
      connected = false;
    }
    if (mounted) setState(() {});
  }

  void connect() {
    if (!mounted) return;
    final url = uri(
      '/ws/s/$slug',
    ).replace(scheme: web.window.location.protocol == 'https:' ? 'wss' : 'ws');
    channel = WebSocketChannel.connect(url);
    subscription = channel!.stream.listen(
      (data) {
        reconnectMs = 500;
        if (admin) {
          if (polling) {
            refreshQueued = true;
          } else {
            refresh();
          }
        } else {
          accept(Map<String, dynamic>.from(jsonDecode(data)));
        }
      },
      onError: (_) {},
      onDone: () {
        if (!mounted) return;
        setState(() => connected = false);
        reconnectTimer = Timer(Duration(milliseconds: reconnectMs), connect);
        reconnectMs = (reconnectMs * 2).clamp(500, 5000);
      },
    );
  }

  void notify(String message) =>
      messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));

  Future<bool> confirm(String message) async =>
      await showDialog<bool>(
        context: navigator.currentContext!,
        builder: (context) => AlertDialog(
          content: Text(message),
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

  Future<bool> command(String action, [Map<String, dynamic>? data]) async =>
      await commandEvent(action, data) != null;

  /// Queues a command and completes with its recorded event once the server
  /// confirms it, or null when it was rejected. Taps never wait for each other.
  Future<Map<String, dynamic>?> commandEvent(
    String action, [
    Map<String, dynamic>? data,
  ]) {
    if (!(queueable(action) ? canTap : canWrite)) return Future.value(null);
    final id = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>?>();
    completers[id] = completer;
    queue.add({
      'command_id': id,
      'match_id': state['match_id'],
      'action': action,
      'data': data ?? {},
    });
    error = '';
    queueChanged();
    unawaited(pump());
    return completer.future;
  }

  Future<void> pump() async {
    if (sending || !mounted) return;
    sending = true;
    retryTimer?.cancel();
    while (queue.isNotEmpty && mounted) {
      final item = queue.first;
      // The revision is fixed when a command is first sent and kept for
      // retries: the server recognises a retry by its identical fingerprint.
      if (item['expected_revision'] == null) {
        item['expected_revision'] = serverState['revision'];
        queueChanged();
      }
      try {
        final result = await api(
          '/api/s/$slug/matches/${item['match_id']}/commands',
          method: 'POST',
          body: {
            for (final key in [
              'command_id',
              'expected_revision',
              'action',
              'data',
            ])
              key: item[key],
          },
        );
        final applied = (result['events'] as List? ?? [])
            .where((e) => e['command_id'] == item['command_id'])
            .firstOrNull;
        queue.removeAt(0);
        retryMs = 500;
        accept(Map<String, dynamic>.from(result));
        queueChanged();
        completers
            .remove(item['command_id'])
            ?.complete(
              applied == null
                  ? <String, dynamic>{}
                  : Map<String, dynamic>.from(applied),
            );
        if (!queueable(item['action'])) notify(t('saved'));
      } on ApiError catch (e) {
        queue.removeAt(0);
        queueChanged();
        completers.remove(item['command_id'])?.complete(null);
        error = e.code;
        notify(t('error.${e.code}'));
        if (e.code == 'admin_required') admin = false;
        sending = false;
        await refresh();
        sending = true;
      } catch (_) {
        // Unknown outcome: keep the command and retry it unchanged.
        if (mounted) setState(() => connected = false);
        retryTimer = Timer(Duration(milliseconds: retryMs), pump);
        retryMs = (retryMs * 2).clamp(500, 5000);
        break;
      }
    }
    sending = false;
    if (mounted) setState(() {});
  }

  Widget syncBadge() {
    final waiting = queue.length;
    if (connected && waiting == 0) return const SizedBox.shrink();
    return Tooltip(
      message: t(connected ? 'sync.pending' : 'sync.offline'),
      child: Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: connected
            ? const Color(0xff3a3216)
            : const Color(0xff4a1d1d),
        avatar: Icon(
          connected ? Icons.sync : Icons.cloud_off,
          size: 16,
          color: Colors.orange,
        ),
        label: Text(
          waiting == 0 ? t('sync.offline_short') : '$waiting',
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }

  Future<void> create() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await api(
        '/api/scoreboards',
        method: 'POST',
        body: {
          'sport': draftSport,
          'language': lang,
          'period_count': draftSport == 'basketball'
              ? draftPeriods
              : defaultPeriods,
          'period_length_min': draftSport == 'basketball'
              ? draftMinutes
              : defaultMinutes,
          'location': draftLocation,
        },
      );
      slug = result['slug'];
      pin = result['pin'];
    } on ApiError catch (e) {
      error = e.code;
    } catch (_) {
      error = 'network';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> claim() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await api(
        '/api/s/$slug/admin/claim',
        method: 'POST',
        body: {'pin': pinInput.text, 'label': deviceName.text},
      );
      pinInput.clear();
      admin = true;
      await refresh();
    } on ApiError catch (e) {
      error = e.code;
    } catch (_) {
      error = 'network';
    }
    if (mounted) setState(() => busy = false);
  }

  String periodLabel([Map<String, dynamic>? value]) {
    final s = value ?? state;
    final period = s['period'] ?? 0, count = s['period_count'];
    if (period > count && (s['sport'] ?? state['sport']) == 'basketball') {
      return 'OT${period - count}';
    }
    if (period == 0 || count == 1) return '';
    if (count == 2) return t('half').replaceAll('{n}', '$period');
    if (count == 4) return t('quarter').replaceAll('{n}', '$period');
    return '$period/$count';
  }

  int elapsed() {
    final c = state['clock'];
    return (c['elapsed_ms'] as num).round() +
        (c['running'] == true
            ? (now - (c['started_at'] as num).round()).clamp(0, 86400000)
            : 0);
  }

  String clockText() {
    if (state['clock']['enabled'] != true) return '';
    final length = periodLengthMs;
    if (basketball) return mmss((length - elapsed()).clamp(0, length));
    final start = ((state['period'] as int) - 1).clamp(0, 12) * length;
    final e = elapsed();
    if (e > length) {
      return '${(start + length) ~/ 60000}+${((e - length) / 60000).ceil()}';
    }
    final seconds = (start + e) ~/ 1000;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String mmss(int ms) {
    final seconds = (ms / 1000).ceil();
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String eventText(dynamic e) {
    final team = e['team'];
    String stamp = periodLabel(Map<String, dynamic>.from(e));
    if (e['clock_ms'] != null && e['period'] > 0) {
      final length = e['period_length_min'] * 60000;
      final ms = e['clock_ms'];
      stamp = basketball
          ? '$stamp ${mmss(((e['period_duration_ms'] ?? length) - ms).toInt().clamp(0, 3600000))}'
          : ms > length
          ? '${e['period'] * e['period_length_min']}+${((ms - length) / 60000).ceil()}'
          : '${((e['period'] - 1) * length + ms) ~/ 60000 + 1}′';
    }
    return '${basketball && e['type'].toString().startsWith('score') ? '${e['points'] > 0 ? '+' : ''}${e['points']}' : t(e['type'])}${team == null ? '' : ' · ${state[team]['name']}'}${e['player'] == null ? ((e['type'] == 'personal_foul' || (basketball && e['type'] == 'score')) ? ' · ${t('foul.unknown')}' : '') : ' · ${playerLabel(e['player'])}'}${stamp.isEmpty ? '' : ' · $stamp'}';
  }

  Future<void> copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    notify(t('copied'));
  }

  Widget action(String label, VoidCallback? callback, {bool primary = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: primary
            ? FilledButton(onPressed: callback, child: Text(label))
            : OutlinedButton(onPressed: callback, child: Text(label)),
      );

  Widget field(
    String label,
    TextEditingController controller, {
    bool numeric = false,
    int? maxLength,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: TextField(
      controller: controller,
      maxLength: maxLength,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget section(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 18),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xff151e2a),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 14),
        ...children,
      ],
    ),
  );

  Future<void> editSettings() async {
    final home = TextEditingController(text: state['home']['name']);
    final away = TextEditingController(text: state['away']['name']);
    final homeShort = TextEditingController(text: state['home']['short']);
    final awayShort = TextEditingController(text: state['away']['short']);
    final count = TextEditingController(text: '${state['period_count']}');
    final length = TextEditingController(text: '${state['period_length_min']}');
    final seconds = TextEditingController(text: '${elapsed() ~/ 1000}');
    final delay = TextEditingController(
      text: '${state['overlay']['delay_ms']}',
    );
    String foulMode = state['foul_mode'] ?? 'team';
    bool clock = state['clock']['enabled'],
        auto = state['overlay']['auto_big'],
        right = state['overlay']['position'] == 'top_right';
    final initialRevision = state['revision'];
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('settings')),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  field('${t('home')} · ${t('name')}', home, maxLength: 60),
                  field(t('short'), homeShort, maxLength: 5),
                  field('${t('away')} · ${t('name')}', away, maxLength: 60),
                  field(t('short'), awayShort, maxLength: 5),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (basketball)
                        for (final format in [
                          [4, 10],
                          [4, 12],
                          [8, 5],
                          [2, 20],
                        ])
                          action('${format[0]} × ${format[1]}', () {
                            count.text = '${format[0]}';
                            length.text = '${format[1]}';
                            update(
                              () => foulMode = format[0] == 8
                                  ? 'personal'
                                  : 'team',
                            );
                          }),
                      if (!basketball)
                        action(t('format.halves'), () {
                          count.text = '2';
                          length.text = '45';
                        }),
                      if (!basketball)
                        action(t('format.mini'), () {
                          count.text = '1';
                          length.text = '10';
                        }),
                    ],
                  ),
                  field(t('period_count'), count, numeric: true),
                  field(t('period_length'), length, numeric: true),
                  if (basketball)
                    DropdownButtonFormField<String>(
                      key: ValueKey(foulMode),
                      initialValue: foulMode,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: t('foul.mode')),
                      items: [
                        for (final mode in ['team', 'personal', 'both', 'off'])
                          DropdownMenuItem(
                            value: mode,
                            child: Text(t('foul.mode.$mode')),
                          ),
                      ],
                      onChanged: (value) => update(() => foulMode = value!),
                    ),
                  if (basketball) Text(t('basketball.pilot')),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('clock_enabled')),
                    value: clock,
                    onChanged: (v) => update(() => clock = v),
                  ),
                  if (clock != state['clock']['enabled'] && clock)
                    field(t('clock_elapsed'), seconds, numeric: true),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('auto_big')),
                    value: auto,
                    onChanged: (v) => update(() => auto = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('right')),
                    value: right,
                    onChanged: (v) => update(() => right = v),
                  ),
                  field(t('delay'), delay, numeric: true),
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
              onPressed: () async {
                if (state['revision'] != initialRevision) {
                  notify(t('error.state_changed'));
                  Navigator.pop(context);
                  return;
                }
                final c = int.tryParse(count.text),
                    l = int.tryParse(length.text),
                    d = int.tryParse(delay.text),
                    e = int.tryParse(seconds.text);
                if (c == null ||
                    l == null ||
                    d == null ||
                    e == null ||
                    c < 1 ||
                    c > 12 ||
                    c <
                        (basketball
                            ? (state['period'] as int).clamp(
                                0,
                                state['period_count'] as int,
                              )
                            : state['period']) ||
                    l < 1 ||
                    l > 60 ||
                    d < 0 ||
                    d > 30000 ||
                    e < 0 ||
                    e > 86400 ||
                    home.text.trim().isEmpty ||
                    away.text.trim().isEmpty ||
                    homeShort.text.trim().isEmpty ||
                    awayShort.text.trim().isEmpty) {
                  notify(t('error.invalid_value'));
                  return;
                }
                Navigator.pop(context);
                final payload = <String, dynamic>{
                  'home': {'name': home.text, 'short': homeShort.text},
                  'away': {'name': away.text, 'short': awayShort.text},
                  'period_count': c,
                  'period_length_min': l,
                  if (basketball) 'foul_mode': foulMode,
                };
                if (clock != state['clock']['enabled']) {
                  payload['clock_enabled'] = clock;
                  if (clock) payload['clock_elapsed_ms'] = e * 1000;
                }
                if (await command('settings', payload)) {
                  await command('overlay', {
                    'auto_big': auto,
                    'position': right ? 'top_right' : 'top_left',
                    'delay_ms': d,
                  });
                }
              },
              child: Text(t('save')),
            ),
          ],
        ),
      ),
    );
    // Controllers belong to the dialog and are released after its close animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final c in [
      home,
      away,
      homeShort,
      awayShort,
      count,
      length,
      seconds,
      delay,
    ]) {
      c.dispose();
    }
  }

  Future<void> manageAccess() async {
    List<dynamic> devices;
    try {
      devices = await api('/api/s/$slug/admins');
    } catch (_) {
      notify(t('error.network'));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => AlertDialog(
        title: Text(t('links')),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...linkWidgets(),
                const Divider(),
                Text(t('admins')),
                ...devices.map(
                  (d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(d['label']),
                    subtitle: d['current'] ? Text(t('current')) : null,
                    trailing: IconButton(
                      tooltip: t('revoke'),
                      icon: const Icon(Icons.link_off),
                      onPressed: () async {
                        if (!await confirm(t('revoke.confirm'))) return;
                        try {
                          await api(
                            '/api/s/$slug/admins/${d['id']}',
                            method: 'DELETE',
                          );
                          await checkAdmin();
                          if (context.mounted) Navigator.pop(context);
                        } catch (_) {
                          notify(t('error.generic'));
                        }
                      },
                    ),
                  ),
                ),
                action(t('pin.rotate'), () async {
                  if (!await confirm(t('pin.rotate.confirm'))) return;
                  try {
                    final r = await api('/api/s/$slug/pin', method: 'POST');
                    if (context.mounted) Navigator.pop(context);
                    setState(() => pin = r['pin']);
                  } catch (_) {
                    notify(t('error.network'));
                  }
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('cancel')),
          ),
        ],
      ),
    );
  }

  String get spectatorUrl =>
      uri('/s/$slug').replace(queryParameters: {'lang': lang}).toString();

  Future<void> nativeShare() async {
    final data = web.ShareData(title: t('spectator'), url: spectatorUrl);
    bool supported = false;
    try {
      supported = web.window.navigator.canShare(data);
    } catch (_) {}
    if (!supported) {
      await copy(spectatorUrl);
      return;
    }
    try {
      await web.window.navigator.share(data).toDart;
    } catch (_) {
      /* The share sheet can be cancelled. */
    }
  }

  Widget shareActions() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      OutlinedButton(
        onPressed: () => web.window.open(
          'https://wa.me/?text=${Uri.encodeComponent(spectatorUrl)}',
          '_blank',
          'noopener,noreferrer',
        ),
        child: const Text('WhatsApp'),
      ),
      OutlinedButton(
        onPressed: () => web.window.open(
          'https://www.facebook.com/sharer/sharer.php?u=${Uri.encodeComponent(spectatorUrl)}',
          '_blank',
          'noopener,noreferrer',
        ),
        child: const Text('Facebook'),
      ),
      OutlinedButton(
        onPressed: () => copy(spectatorUrl),
        child: Text(t('share.copy')),
      ),
      OutlinedButton(onPressed: nativeShare, child: Text(t('share.more'))),
    ],
  );

  Future<void> showSharing() async {
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => AlertDialog(
        title: Text(t('share.spectator')),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(spectatorUrl),
                const SizedBox(height: 16),
                shareActions(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('close')),
          ),
        ],
      ),
    );
  }

  List<Widget> linkWidgets() => [
    Text(t('share.spectator')),
    const SizedBox(height: 8),
    shareActions(),
    const SizedBox(height: 20),
    for (final entry in {
      'spectator': '/s/$slug',
      'overlay.link': '/s/$slug/overlay',
      'control': '/s/$slug/control',
    }.entries)
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t(entry.key)),
            const SizedBox(height: 4),
            SelectableText(
              uri(entry.value).toString(),
              style: const TextStyle(fontSize: 14),
            ),
            action(t('copy'), () => copy(uri(entry.value).toString())),
          ],
        ),
      ),
    Text(t('obs.note'), style: const TextStyle(color: Color(0xffb1bfd0))),
  ];

  Future<void> editLocation() async {
    Map<String, dynamic>? current = draftLocation;
    if (slug.isNotEmpty) {
      try {
        final result = await api('/api/s/$slug/location');
        current = result['location'] == null
            ? null
            : Map<String, dynamic>.from(result['location']);
      } catch (_) {
        notify(t('error.network'));
        return;
      }
    }
    if (!mounted) return;
    web.HTMLIFrameElement? frame;
    BuildContext? dialogContext;
    bool saving = false;
    Future<void> handleMessage(web.MessageEvent event) async {
      if (event.origin != web.window.location.origin ||
          frame == null ||
          event.source != frame!.contentWindow) {
        return;
      }
      final data = event.data.dartify();
      if (data is! Map) return;
      if (data['type'] == 'score67-location-ready') {
        frame!.contentWindow!.postMessage(
          {'type': 'score67-location-init', 'location': current}.jsify(),
          web.window.location.origin.toJS,
        );
      } else if (data['type'] == 'score67-location-save' && !saving) {
        saving = true;
        final chosen = data['location'] == null
            ? null
            : Map<String, dynamic>.from(data['location']);
        try {
          if (slug.isEmpty) {
            setState(() => draftLocation = chosen);
          } else {
            await api(
              '/api/s/$slug/location',
              method: 'PUT',
              body: {'location': chosen},
            );
            await refresh();
          }
          if (dialogContext != null && dialogContext!.mounted) {
            Navigator.pop(dialogContext!);
          }
          notify(t('saved'));
        } catch (_) {
          notify(t('error.network'));
        } finally {
          saving = false;
        }
      }
    }

    final listener = ((web.MessageEvent event) {
      unawaited(handleMessage(event));
    }).toJS;
    web.window.addEventListener('message', listener);
    try {
      await showDialog<void>(
        context: navigator.currentContext!,
        builder: (context) {
          dialogContext = context;
          return Dialog(
            insetPadding: const EdgeInsets.all(12),
            child: SizedBox(
              width: 650,
              height: 760,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t('location.title'),
                            style: const TextStyle(fontSize: 20),
                          ),
                        ),
                        IconButton(
                          tooltip: t('close'),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: HtmlElementView.fromTagName(
                      tagName: 'iframe',
                      onElementCreated: (element) {
                        frame = element as web.HTMLIFrameElement;
                        frame!.title = t('location.title');
                        frame!.allow = 'geolocation';
                        frame!.style.border = '0';
                        frame!.style.width = '100%';
                        frame!.style.height = '100%';
                        frame!.src = '/location-picker?lang=$lang';
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      web.window.removeEventListener('message', listener);
    }
  }

  Widget createView() => section(t('create'), [
    Wrap(
      spacing: 12,
      children: [
        for (final sport in ['football', 'basketball'])
          ChoiceChip(
            label: Text(t(sport)),
            selected: draftSport == sport,
            onSelected: busy ? null : (_) => setState(() => draftSport = sport),
          ),
      ],
    ),
    if (draftSport == 'basketball') ...[
      const SizedBox(height: 12),
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
              label: Text('${format[0]} × ${format[1]} min'),
              selected: draftPeriods == format[0] && draftMinutes == format[1],
              onSelected: (_) => setState(() {
                draftPeriods = format[0];
                draftMinutes = format[1];
              }),
            ),
        ],
      ),
      Text(t('basketball.pilot')),
    ],
    const SizedBox(height: 12),
    Text(t('create.note')),
    const SizedBox(height: 16),
    Text(t('location.optional')),
    if (draftLocation != null)
      Text(
        '${draftLocation!['label']} · ${draftLocation!['lat']}, ${draftLocation!['lng']}',
      ),
    if (draftLocation != null)
      Text(
        t(
          draftLocation!['visible'] == true
              ? 'location.visible'
              : 'location.private',
        ),
      ),
    action(t('location.choose'), busy ? null : editLocation),
    action(t('create'), busy ? null : create, primary: true),
  ]);

  Widget pinView() => section(t('pin.save'), [
    SelectableText(
      pin,
      style: const TextStyle(
        fontSize: 48,
        letterSpacing: 10,
        fontWeight: FontWeight.bold,
      ),
    ),
    Text(t('pin.note')),
    action(t('copy'), () => copy(pin)),
    const SizedBox(height: 20),
    ...linkWidgets(),
    action(
      t('continue'),
      () => web.window.location.assign('/s/$slug/control?lang=$lang'),
      primary: true,
    ),
    action(t('dashboard'), () => navigate('/dashboard')),
  ]);

  Widget claimView() => section(t('claim'), [
    field(t('pin'), pinInput, numeric: true, maxLength: 6),
    field(t('device'), deviceName, maxLength: 60),
    action(t('claim'), busy || !connected ? null : claim, primary: true),
  ]);

  Color teamColor(String value) =>
      Color(int.parse(value.replaceFirst('#', 'ff'), radix: 16));

  Future<void> editTeam(String team) async {
    if (!canWrite) return;
    final revision = state['revision'];
    final name = TextEditingController(text: state[team]['name']);
    final short = TextEditingController(text: state[team]['short']);
    final hex = TextEditingController(text: state[team]['color']);
    String selected = state[team]['color'];
    bool shortEdited = false;
    const palette = [
      '#c8102e',
      '#ef4444',
      '#f97316',
      '#facc15',
      '#16a34a',
      '#14b8a6',
      '#1d4ed8',
      '#38bdf8',
      '#7c3aed',
      '#ec4899',
      '#ffffff',
      '#111827',
    ];
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('team.edit')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    maxLength: 60,
                    decoration: InputDecoration(
                      labelText: t('name'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      if (!shortEdited) {
                        short.text = value
                            .trim()
                            .replaceAll(RegExp(r'\s+'), '')
                            .toUpperCase()
                            .characters
                            .take(5)
                            .toString();
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: short,
                    maxLength: 5,
                    onChanged: (_) => shortEdited = true,
                    decoration: InputDecoration(
                      labelText: t('short'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(t('team.color')),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: palette
                        .map(
                          (value) => SizedBox(
                            width: 56,
                            height: 56,
                            child: Tooltip(
                              message: value,
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: teamColor(value),
                                  padding: EdgeInsets.zero,
                                  side: BorderSide(
                                    color: selected == value
                                        ? const Color(0xffb6f36e)
                                        : const Color(0xff69788c),
                                    width: selected == value ? 3 : 1,
                                  ),
                                ),
                                onPressed: () => update(() {
                                  selected = value;
                                  hex.text = value;
                                }),
                                child: selected == value
                                    ? Icon(
                                        Icons.check,
                                        color:
                                            teamColor(
                                                  value,
                                                ).computeLuminance() >
                                                .179
                                            ? Colors.black
                                            : Colors.white,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: hex,
                    maxLength: 7,
                    decoration: InputDecoration(
                      labelText: t('team.hex'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
                        update(() => selected = value.toLowerCase());
                      }
                    },
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
                if (!canWrite) {
                  notify(t('offline'));
                  return;
                }
                if (state['revision'] != revision) {
                  notify(t('error.state_changed'));
                  Navigator.pop(context);
                  return;
                }
                if (name.text.trim().isEmpty ||
                    short.text.trim().isEmpty ||
                    !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex.text)) {
                  notify(t('error.invalid_value'));
                  return;
                }
                final data = {
                  team: {
                    'name': name.text.trim(),
                    'short': short.text.trim(),
                    'color': hex.text.toLowerCase(),
                  },
                };
                Navigator.pop(context);
                command('settings', data);
              },
              child: Text(t('save')),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    short.dispose();
    hex.dispose();
  }

  String playerLabel(dynamic player) => [
    if ((player['number'] ?? '').isNotEmpty) '#${player['number']}',
    if ((player['name'] ?? '').isNotEmpty) player['name'],
  ].join(' ');

  Future<void> editSquad(String team) async {
    final revision = state['revision'], match = state['match_id'];
    final players = await showDialog<List<Map<String, dynamic>>>(
      context: navigator.currentContext!,
      builder: (context) => SquadDialog(
        teamName: state[team]['name'],
        requireNumber: basketball,
        players: state[team]['squad'] ?? [],
        t: t,
      ),
    );
    if (players == null || !mounted) return;
    if (state['revision'] != revision || state['match_id'] != match) {
      notify(t('error.state_changed'));
      return;
    }
    await command('squad', {'team': team, 'players': players});
  }

  Future<void> playerAction(
    String action,
    String team, {
    dynamic event,
    int points = 1,
  }) async {
    if (event == null) {
      // Count immediately; selecting or dismissing a player must never delay the score.
      final recorded = await commandEvent(action, {
        'team': team,
        if (action == 'score') 'points': points,
      });
      if (recorded != null &&
          recorded['id'] != null &&
          (state[team]['squad'] as List? ?? []).isNotEmpty) {
        await playerAction(action, team, event: recorded);
      }
      return;
    }
    final personal = action == 'personal_foul';
    final numberInput = personal ? TextEditingController() : null;
    final players =
        (personal ? state[team]['personal_fouls'] : state[team]['squad'])
            as List? ??
        [];
    final revision = state['revision'], match = state['match_id'];
    final selected = await showDialog<String>(
      context: navigator.currentContext!,
      builder: (context) => SimpleDialog(
        title: Text('${t('assign_player')} · ${state[team]['name']}'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(t('player.recorded')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(t(personal ? 'foul.unknown' : 'player.none')),
            ),
          ),
          for (final player in players)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, player['id']),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(playerLabel(player)),
              ),
            ),
          if (personal)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                controller: numberInput,
                maxLength: 3,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t('player.number')),
              ),
            ),
          if (personal)
            SimpleDialogOption(
              onPressed: () {
                final value = numberInput!.text.trim();
                if (!RegExp(r'^[0-9]{1,3}$').hasMatch(value)) {
                  notify(t('foul.number_error'));
                  return;
                }
                Navigator.pop(context, 'number:$value');
              },
              child: Text(t('foul.assign_number')),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: Text(t('close')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    numberInput?.dispose();
    if (selected == null || !mounted) return;
    if (state['revision'] != revision || state['match_id'] != match) {
      notify(t('error.state_changed'));
      return;
    }
    if (selected.isEmpty && event['player'] == null) return;
    await command(personal ? 'assign_foul_player' : 'assign_player', {
      'team': team,
      if (personal && selected.startsWith('number:'))
        'player_number': selected.substring(7)
      else
        'player_id': selected.isEmpty ? null : selected,
      'event_id': event['id'],
    });
  }

  Future<void> correctEvent(String kind, String team) async {
    final candidates = events
        .where(
          (e) =>
              e['type'] == kind &&
              e['team'] == team &&
              e['cancelled'] == false &&
              e['corrected'] != true,
        )
        .toList();
    final revision = state['revision'], match = state['match_id'];
    int? target;
    if ((basketball && kind == 'score') ||
        candidates.any((e) => e['player'] != null)) {
      target = await showDialog<int>(
        context: navigator.currentContext!,
        builder: (context) => SimpleDialog(
          title: Text(t('event.remove')),
          children: [
            for (final e in candidates.reversed)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, e['id']),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(eventText(e)),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
          ],
        ),
      );
      if (target == null || !mounted) return;
      if (state['revision'] != revision || state['match_id'] != match) {
        notify(t('error.state_changed'));
        return;
      }
    }
    await command('${kind}_correction', {
      'team': team,
      if (kind == 'score')
        'points':
            -(candidates.firstWhere(
                  (e) => e['id'] == target,
                  orElse: () => candidates.last,
                )['points']
                as int),
      'event_id': target,
    });
  }

  Widget cardControls(String team, String color) {
    final count = state[team]['counters']?['${color}_cards'] ?? 0;
    final tint = color == 'yellow'
        ? const Color(0xfffacc15)
        : const Color(0xffef4444);
    return Column(
      children: [
        Text(
          '${t('${color}_cards')}: $count',
          textAlign: TextAlign.center,
          style: TextStyle(color: tint, fontSize: 14),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton.filled(
              tooltip: '+ ${t('${color}_card')}',
              onPressed: canWrite
                  ? () => playerAction('${color}_card', team)
                  : null,
              style: IconButton.styleFrom(
                backgroundColor: tint,
                foregroundColor: Colors.black,
              ),
              icon: const Icon(Icons.add),
            ),
            IconButton.outlined(
              tooltip: '− ${t('${color}_card')}',
              onPressed: canWrite && count > 0
                  ? () => correctEvent('${color}_card', team)
                  : null,
              icon: const Icon(Icons.remove),
            ),
          ],
        ),
      ],
    );
  }

  bool get basketballClockRunning =>
      state['clock']['running'] == true && elapsed() < periodLengthMs;

  Widget basketballPlayStop() {
    final running = basketballClockRunning;
    final enabled =
        canWrite &&
        state['clock']['enabled'] == true &&
        state['phase'] == 'period_running' &&
        elapsed() < periodLengthMs;
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(64),
        backgroundColor: running
            ? const Color(0xffdc2626)
            : const Color(0xffb6f36e),
        foregroundColor: running ? Colors.white : Colors.black,
        textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
      ),
      onPressed: enabled
          ? () => command(running ? 'clock_stop' : 'clock_start')
          : null,
      icon: Icon(running ? Icons.stop : Icons.play_arrow, size: 32),
      label: Text(t(running ? 'basketball.stop' : 'basketball.play')),
    );
  }

  dynamic matchingBasket(String team, String? playerId, int points) => events
      .where(
        (e) =>
            e['type'] == 'score' &&
            e['team'] == team &&
            e['player']?['id'] == playerId &&
            e['points'] == points &&
            e['cancelled'] == false &&
            e['corrected'] != true,
      )
      .lastOrNull;

  Future<bool> adjustBasket(
    String team,
    String? playerId,
    int points,
    bool subtract,
  ) async {
    if (subtract) {
      final target = matchingBasket(team, playerId, points);
      if (target == null) return false;
      return command('score_correction', {
        'team': team,
        'event_id': target['id'],
      });
    }
    return command('score', {
      'team': team,
      'player_id': playerId,
      'points': points,
    });
  }

  Future<bool> recordStatistic(
    String team,
    String kind,
    String? playerId,
    bool correcting,
  ) async {
    if (correcting) {
      final target = events
          .where(
            (e) =>
                e['type'] == kind &&
                e['team'] == team &&
                e['cancelled'] == false &&
                e['corrected'] != true &&
                e['player']?['id'] == playerId,
          )
          .lastOrNull;
      if (target == null) return false;
      return command('${kind}_correction', {
        'team': team,
        'event_id': target['id'],
      });
    }
    return command(kind, {'team': team, 'player_id': playerId});
  }

  Widget teamPanel(String team) {
    final s = state[team];
    final color = teamColor(s['color']);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xff151e2a),
          border: Border(top: BorderSide(color: color, width: 4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Tooltip(
              message: t('team.edit'),
              child: TextButton(
                onPressed: canWrite ? () => editTeam(team) : null,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                child: Column(
                  children: [
                    Text(
                      s['name'],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Icon(Icons.edit_outlined, size: 16),
                  ],
                ),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.groups),
              onPressed: canWrite ? () => editSquad(team) : null,
              label: Text(
                '${t('squad')} (${(s['squad'] as List? ?? []).length})',
              ),
            ),
            Text(
              '${s['score']}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 76,
                fontWeight: FontWeight.w800,
                height: 1.4,
              ),
            ),
            if (basketball && s['statistics'] != null) ...[
              const Divider(height: 24),
              BasketballStatistics(
                key: ValueKey('stats:${state['match_id']}:$team'),
                statistics: Map<String, dynamic>.from(s['statistics']),
                t: t,
                enabled: canWrite,
                personalFoulsEnabled: [
                  'personal',
                  'both',
                ].contains(state['foul_mode']),
                scoringEnabled: true,
                score: (playerId, points, subtract) =>
                    adjustBasket(team, playerId, points, subtract),
                canRemoveScore: (playerId, points) =>
                    matchingBasket(team, playerId, points) != null,
                record: (kind, playerId, correcting) =>
                    recordStatistic(team, kind, playerId, correcting),
              ),
            ],
            if (!basketball)
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: color,
                  foregroundColor: color.computeLuminance() > .179
                      ? Colors.black
                      : Colors.white,
                ),
                onPressed: canWrite ? () => playerAction('score', team) : null,
                child: Text('+ ${t('score')}'),
              ),
            const SizedBox(height: 8),
            if (!basketball)
              OutlinedButton(
                onPressed: canWrite && s['score'] > 0
                    ? () => correctEvent('score', team)
                    : null,
                child: Text(
                  basketball ? t('basketball.correct') : '− ${t('score')}',
                ),
              ),
            const Divider(height: 24),
            if (!basketball) ...[
              cardControls(team, 'red'),
              const SizedBox(height: 16),
              cardControls(team, 'yellow'),
            ] else ...[
              if (state['foul_mode'] == 'team')
                basketballCounter(team, 'team_foul', 'team_fouls'),
              if (state['foul_mode'] == 'both')
                Text(
                  '${t('team_fouls')}: ${s['counters']['team_fouls']}',
                  textAlign: TextAlign.center,
                ),
              basketballCounter(team, 'timeout', 'timeouts'),
            ],
          ],
        ),
      ),
    );
  }

  Widget basketballCounter(String team, String kind, String counter) {
    final count = state[team]['counters']?[counter] ?? 0;
    return Column(
      children: [
        Text('${t(counter)}: $count', textAlign: TextAlign.center),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: '− ${t(kind)}',
              onPressed: canWrite && count > 0
                  ? () => correctEvent(kind, team)
                  : null,
              icon: const Icon(Icons.remove),
            ),
            IconButton(
              tooltip: '+ ${t(kind)}',
              onPressed: canWrite ? () => command(kind, {'team': team}) : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> setBasketballClock() async {
    final input = TextEditingController(
      text: mmss((periodLengthMs - elapsed()).clamp(0, periodLengthMs)),
    );
    final revision = state['revision'], match = state['match_id'];
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => AlertDialog(
        title: Text(t('clock_set')),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'MM:SS',
            hintText: '04:31',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final parts = RegExp(
                r'^(\d{1,2}):([0-5]\d)$',
              ).firstMatch(input.text.trim());
              final ms = parts == null
                  ? -1
                  : (int.parse(parts[1]!) * 60 + int.parse(parts[2]!)) * 1000;
              if (ms < 0 || ms > periodLengthMs) {
                notify(t('error.invalid_value'));
                return;
              }
              Navigator.pop(context);
              if (revision != state['revision'] || match != state['match_id']) {
                notify(t('error.state_changed'));
                return;
              }
              command('clock_set', {'remaining_ms': ms});
            },
            child: Text(t('save')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
  }

  Widget basketballHeader() {
    final running = basketballClockRunning;
    final canToggle =
        canWrite &&
        state['phase'] == 'period_running' &&
        state['clock']['enabled'] == true &&
        elapsed() < periodLengthMs;
    return Row(
      children: [
        Icon(
          connected ? Icons.wifi : Icons.wifi_off,
          size: 18,
          color: connected ? const Color(0xffb6f36e) : Colors.orange,
        ),
        const SizedBox(width: 8),
        Text(
          periodLabel(),
          style: const TextStyle(fontSize: 15, color: Color(0xffb6f36e)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: canWrite && state['phase'] == 'period_running'
                ? setBasketballClock
                : null,
            child: Text(
              clockText(),
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        syncBadge(),
        IconButton(
          tooltip: t('stats.correct'),
          color: basketballCorrecting ? Colors.orange : null,
          isSelected: basketballCorrecting,
          icon: Icon(
            basketballCorrecting ? Icons.remove_circle : Icons.edit_outlined,
          ),
          onPressed: () =>
              setState(() => basketballCorrecting = !basketballCorrecting),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 116,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(100, 48),
              backgroundColor: running
                  ? const Color(0xffdc2626)
                  : const Color(0xffb6f36e),
              foregroundColor: running ? Colors.white : Colors.black,
            ),
            onPressed: canToggle
                ? () => command(running ? 'clock_stop' : 'clock_start')
                : null,
            icon: Icon(running ? Icons.stop : Icons.play_arrow),
            label: Text(t(running ? 'basketball.stop' : 'basketball.play')),
          ),
        ),
      ],
    );
  }

  Widget basketballTeamBar() => Row(
    children: [
      for (final team in ['home', 'away'])
        Expanded(
          child: TextButton(
            style: TextButton.styleFrom(
              backgroundColor: basketballTeam == team
                  ? const Color(0xff34452b)
                  : null,
              minimumSize: const Size(48, 48),
            ),
            onPressed: () => setState(() => basketballTeam = team),
            child: Text(
              '${state[team]['short']}  ${state[team]['score']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ),
    ],
  );

  /// Tap adds; in correction mode the same chip subtracts.
  Widget counterChip(
    String team,
    String kind,
    String counter, {
    String? short,
    IconData? icon,
    bool tappable = true,
    Color? tint,
  }) {
    final count = (state[team]['counters']?[counter] ?? 0) as int;
    final active = tappable && canTap && (!basketballCorrecting || count > 0);
    final label = Text(
      '${short == null ? '' : '$short '}$count',
      style: TextStyle(
        fontWeight: FontWeight.w700,
        color: basketballCorrecting && active ? Colors.orange : tint,
      ),
    );
    final side = BorderSide(color: tint ?? const Color(0xff3b4a5c));
    final avatar = icon == null ? null : Icon(icon, size: 16, color: tint);
    return Tooltip(
      message: tappable
          ? '${basketballCorrecting ? '−' : '+'} ${t(kind)}'
          : t(counter),
      child: tappable
          ? ActionChip(
              visualDensity: VisualDensity.compact,
              backgroundColor: tint?.withValues(alpha: .18),
              side: side,
              avatar: avatar,
              label: label,
              onPressed: active
                  ? () => basketballCorrecting
                        ? correctEvent(kind, team)
                        : command(kind, {'team': team})
                  : null,
            )
          : Chip(
              visualDensity: VisualDensity.compact,
              backgroundColor: tint?.withValues(alpha: .18),
              side: side,
              avatar: avatar,
              label: label,
            ),
    );
  }

  Widget basketballTeamPanel(String team) {
    final s = state[team];
    final mode = state['foul_mode'];
    final teamFouls = (s['counters']?['team_fouls'] ?? 0) as int;
    // FIBA: from the fifth team foul in a period the opponent shoots free throws.
    final penalty = teamFouls >= 5
        ? BasketballStatistics.fouledOut
        : teamFouls == 4
        ? BasketballStatistics.foulTrouble
        : null;
    return SizedBox(
      width: BasketballStatistics.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: teamColor(s['color']), width: 6),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: s['name'],
                    child: Text(
                      s['short'],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                if (mode == 'team' || mode == 'both')
                  counterChip(
                    team,
                    'team_foul',
                    'team_fouls',
                    short: t('stats.tf'),
                    tappable: mode == 'team',
                    tint: penalty,
                  ),
                const SizedBox(width: 4),
                counterChip(
                  team,
                  'timeout',
                  'timeouts',
                  icon: Icons.timer_outlined,
                ),
                const SizedBox(width: 6),
                Text(
                  '${s['score']}',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                IconButton(
                  tooltip:
                      '${t('squad')} (${(s['squad'] as List? ?? []).length})',
                  icon: const Icon(Icons.groups),
                  onPressed: canWrite ? () => editSquad(team) : null,
                ),
              ],
            ),
          ),
          if (s['statistics'] != null)
            BasketballStatistics(
              key: ValueKey('fast:${state['match_id']}:$team'),
              statistics: Map<String, dynamic>.from(s['statistics']),
              t: t,
              enabled: canTap,
              scoringEnabled: true,
              correcting: basketballCorrecting,
              personalFoulsEnabled: ['personal', 'both'].contains(mode),
              record: (kind, id, subtract) =>
                  recordStatistic(team, kind, id, subtract),
              score: (id, points, subtract) =>
                  adjustBasket(team, id, points, subtract),
              canRemoveScore: (id, points) =>
                  matchingBasket(team, id, points) != null,
            ),
        ],
      ),
    );
  }

  Widget periodScores() {
    final home = state['home']['period_scores'] as List? ?? [];
    final away = state['away']['period_scores'] as List? ?? [];
    if (home.isEmpty) return const SizedBox.shrink();
    final count = state['period_count'] as int;
    String heading(int index) => index >= count
        ? 'OT${index - count + 1}'
        : count == 4
        ? 'Q${index + 1}'
        : '${index + 1}';
    TableRow line(String label, List values, {bool bold = false}) => TableRow(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        for (final value in values)
          Text(
            '$value',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w700 : null,
            ),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Table(
        defaultColumnWidth: const FixedColumnWidth(40),
        columnWidths: const {0: FixedColumnWidth(64)},
        children: [
          line('', [for (var i = 0; i < home.length; i++) heading(i)]),
          line(state['home']['short'], home, bold: true),
          line(state['away']['short'], away, bold: true),
        ],
      ),
    );
  }

  Widget basketballFastView() {
    final last = events.where((e) => e['cancelled'] == false).lastOrNull;
    final phase = state['phase'];
    final finalBreak =
        phase == 'break' && state['period'] >= state['period_count'];
    final tied = state['home']['score'] == state['away']['score'];
    final expired =
        phase == 'period_running' &&
        state['clock']['enabled'] == true &&
        elapsed() >= periodLengthMs;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 2 * BasketballStatistics.width + 24;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phase == 'pre_game' || (phase == 'break' && !finalBreak))
              action(
                t('basketball.period_start'),
                canWrite ? () => command('period_start') : null,
                primary: true,
              ),
            if (finalBreak && tied)
              action(
                t('overtime_start'),
                canWrite ? () => command('overtime_start') : null,
                primary: true,
              ),
            if (finalBreak)
              action(
                t('game_end'),
                canWrite
                    ? () async {
                        if (await confirm(t('finish.confirm'))) {
                          await command('game_end');
                        }
                      }
                    : null,
                primary: !tied,
              ),
            if (expired)
              HoldAction(
                label: '${t('period_end')} · ${t('hold')}',
                enabled: canWrite,
                onActivate: () => command('period_end'),
              ),
            if (phase == 'finished')
              action(
                t('new_match'),
                canWrite
                    ? () async {
                        if (await confirm(t('new.confirm'))) {
                          await command('new_match');
                        }
                      }
                    : null,
                primary: true,
              ),
            if (basketballCorrecting)
              Text(
                t('stats.correct'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orange),
              ),
            if (!['personal', 'both'].contains(state['foul_mode']))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: canWrite
                      ? () => command('settings', {
                          'foul_mode': state['foul_mode'] == 'team'
                              ? 'both'
                              : 'personal',
                        })
                      : null,
                  child: Text(t('stats.enable_pf_short')),
                ),
              ),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  basketballTeamPanel('home'),
                  basketballTeamPanel('away'),
                ],
              )
            else
              Center(child: basketballTeamPanel(basketballTeam)),
            if (last != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      eventText(last),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: canWrite
                        ? () => command('undo', {'event_id': last['id']})
                        : null,
                    icon: const Icon(Icons.undo),
                    label: Text(t('undo')),
                  ),
                ],
              ),
            Center(child: periodScores()),
            basketballAdvanced(phase),
          ],
        );
      },
    );
  }

  Widget basketballAdvanced(String phase) => ExpansionTile(
    title: Text(t('advanced')),
    children: [
      Wrap(
        spacing: 8,
        children: [
          action(t('settings'), canWrite ? editSettings : null),
          action(t('clock_set'), canWrite ? setBasketballClock : null),
          for (final team in ['home', 'away'])
            action(
              '${t('team.edit')} · ${state[team]['short']}',
              canWrite ? () => editTeam(team) : null,
            ),
          action(t('links'), manageAccess),
          action(t('share.spectator'), showSharing),
          action(t('location.title'), editLocation),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final mode in ['team', 'personal', 'both', 'off'])
            ChoiceChip(
              label: Text(t('foul.mode.$mode')),
              selected: state['foul_mode'] == mode,
              onSelected: canWrite
                  ? (_) => command('settings', {'foul_mode': mode})
                  : null,
            ),
        ],
      ),
      if (phase == 'period_running')
        HoldAction(
          label: '${t('period_end')} · ${t('hold')}',
          enabled: canWrite,
          onActivate: () => command('period_end'),
        ),
      if (phase != 'finished')
        action(
          t('game_end'),
          canWrite
              ? () async {
                  if (await confirm(t('finish.confirm'))) {
                    await command('game_end');
                  }
                }
              : null,
        ),
      Wrap(
        spacing: 8,
        children: [
          for (final entry in {
            'small': 'scoreboard',
            'big': 'score_big',
            'hidden': 'hidden',
          }.entries)
            action(
              t(entry.key),
              canWrite
                  ? () => command('overlay', {
                      'view': entry.value,
                      'auto_big': false,
                    })
                  : null,
              primary: state['overlay']['view'] == entry.value,
            ),
        ],
      ),
      ExpansionTile(
        title: Text(t('log')),
        children: [
          for (final e in events.reversed.take(30))
            ListTile(
              title: Text(
                eventText(e),
                style: TextStyle(
                  color: e['cancelled'] == true || e['corrected'] == true
                      ? Colors.grey
                      : null,
                ),
              ),
              trailing:
                  ['score', 'personal_foul'].contains(e['type']) &&
                      e['cancelled'] == false &&
                      e['corrected'] != true
                  ? IconButton(
                      tooltip: t('assign_player'),
                      icon: const Icon(Icons.person),
                      onPressed: canTap
                          ? () => playerAction(e['type'], e['team'], event: e)
                          : null,
                    )
                  : null,
            ),
        ],
      ),
      TextButton(
        onPressed: switchLanguage,
        child: Text(lang == 'de' ? 'EN' : 'DE'),
      ),
      Text(widget.releaseLabel, style: const TextStyle(fontSize: 12)),
    ],
  );

  Widget matchView() {
    if (basketball) return basketballFastView();
    final phase = state['phase'];
    final last = events.where((e) => e['cancelled'] == false).lastOrNull;
    final nextAction =
        basketball &&
            phase == 'break' &&
            state['period'] >= state['period_count']
        ? 'game_end'
        : phase == 'pre_game' || phase == 'break'
        ? 'period_start'
        : basketball || state['period'] < state['period_count']
        ? 'period_end'
        : 'game_end';
    final nextLabel = basketball
        ? t(
            nextAction == 'period_start'
                ? 'basketball.period_start'
                : nextAction,
          )
        : phase == 'break'
        ? t('resume')
        : t(nextAction);
    final periodControl = HoldAction(
      label: '$nextLabel · ${t('hold')}',
      enabled: canWrite,
      onActivate: () async {
        if (nextAction == 'game_end' && !await confirm(t('finish.confirm'))) {
          return;
        }
        await command(nextAction);
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (basketball &&
            MediaQuery.orientationOf(navigator.currentContext!) ==
                Orientation.portrait)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                const Icon(Icons.screen_rotation),
                const SizedBox(width: 12),
                Expanded(child: Text(t('basketball.rotate'))),
              ],
            ),
          ),
        Row(
          children: [
            Icon(
              connected ? Icons.wifi : Icons.wifi_off,
              size: 18,
              color: connected ? const Color(0xffb6f36e) : Colors.orange,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t(connected ? 'connected' : 'offline'),
                style: const TextStyle(fontSize: 14),
              ),
            ),
            IconButton(
              tooltip: t('links'),
              onPressed: admin ? manageAccess : null,
              icon: const Icon(Icons.link),
            ),
            IconButton(
              tooltip: t('share.spectator'),
              onPressed: showSharing,
              icon: const Icon(Icons.share_outlined),
            ),
            IconButton(
              tooltip: t('location.title'),
              onPressed: admin ? editLocation : null,
              icon: const Icon(Icons.place_outlined),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            t(
              phase == 'break' && state['period_count'] == 2
                  ? 'halftime'
                  : basketball && phase == 'pre_game'
                  ? 'basketball.ready'
                  : phase,
            ),
            style: const TextStyle(
              color: Color(0xffb6f36e),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Center(
          child: Text(
            clockText(),
            style: const TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Center(child: Text(periodLabel())),
        if (basketball && (phase == 'pre_game' || phase == 'break'))
          periodControl,
        if (basketball) ...[
          const SizedBox(height: 12),
          basketballPlayStop(),
          if (state['clock']['enabled'] == true && phase == 'period_running')
            action(t('clock_set'), canWrite ? setBasketballClock : null),
        ],
        if (basketball)
          Text(t('basketball.scoring_note'), textAlign: TextAlign.center),
        const SizedBox(height: 18),
        if (basketball) ...[
          Text(t('foul.mode')),
          Wrap(
            spacing: 8,
            children: [
              for (final mode in ['team', 'personal', 'both', 'off'])
                ChoiceChip(
                  label: Text(t('foul.mode.$mode')),
                  selected: state['foul_mode'] == mode,
                  onSelected: canWrite
                      ? (_) => command('settings', {'foul_mode': mode})
                      : null,
                ),
            ],
          ),
        ],
        if (basketball && ['personal', 'both'].contains(state['foul_mode']))
          Text(t('foul.note')),
        LayoutBuilder(
          builder: (context, constraints) {
            if (basketball) {
              return Column(
                children: [
                  Row(children: [teamPanel('home')]),
                  const SizedBox(height: 12),
                  Row(children: [teamPanel('away')]),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                teamPanel('home'),
                const SizedBox(width: 12),
                teamPanel('away'),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        if (!basketball)
          Text(
            t('yellow.note'),
            style: const TextStyle(fontSize: 13, color: Color(0xffb5c2d4)),
          ),
        const SizedBox(height: 12),
        if (basketball &&
            phase == 'break' &&
            state['period'] >= state['period_count'] &&
            state['home']['score'] == state['away']['score'])
          action(
            t('overtime_start'),
            canWrite ? () => command('overtime_start') : null,
            primary: true,
          ),
        if (phase != 'finished' && (!basketball || phase == 'period_running'))
          periodControl,
        if (phase == 'finished')
          action(
            t('new_match'),
            canWrite
                ? () async {
                    if (await confirm(t('new.confirm'))) command('new_match');
                  }
                : null,
          ),
        const SizedBox(height: 18),
        section(t('overlay'), [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final entry in {
                'small': 'scoreboard',
                'big': 'score_big',
                'hidden': 'hidden',
              }.entries)
                action(
                  t(entry.key),
                  canWrite
                      ? () => command('overlay', {
                          'view': entry.value,
                          'auto_big': false,
                        })
                      : null,
                  primary: state['overlay']['view'] == entry.value,
                ),
            ],
          ),
          Text(
            t('obs.note'),
            style: const TextStyle(fontSize: 14, color: Color(0xffb1bfd0)),
          ),
          action(
            t('preview'),
            () => web.window.open(
              '/s/$slug/overlay?preview=1',
              '_blank',
              'noopener',
            ),
          ),
        ]),
        ExpansionTile(
          title: Text(t('advanced')),
          children: [
            if (state['clock']['enabled'])
              Wrap(
                spacing: 8,
                children: [
                  for (final seconds in [-60, -10, 10, 60])
                    action(
                      '${seconds > 0 ? '+' : ''}$seconds s',
                      canWrite
                          ? () => command('clock_adjust', {'seconds': seconds})
                          : null,
                    ),
                ],
              ),
            action(t('settings'), canWrite ? editSettings : null),
            if (phase != 'finished')
              action(
                t('game_end'),
                canWrite
                    ? () async {
                        if (await confirm(t('finish.confirm'))) {
                          command('game_end');
                        }
                      }
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 18),
        section(t('log'), [
          if (last != null)
            action(
              '${t('undo')}: ${eventText(last)}',
              canWrite
                  ? () async {
                      if (await confirm(
                        '${t('undo.confirm')}\n${eventText(last)}',
                      )) {
                        command('undo', {'event_id': last['id']});
                      }
                    }
                  : null,
            ),
          if (events.isEmpty) Text(t('log.empty')),
          ...events.reversed
              .take(30)
              .map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${eventText(e)}${e['cancelled']
                            ? ' · ${t('cancelled')}'
                            : e['corrected'] == true
                            ? ' · ${t('event.corrected')}'
                            : ''}',
                        style: TextStyle(
                          color: e['cancelled'] || e['corrected'] == true
                              ? const Color(0xff778497)
                              : Colors.white,
                        ),
                      ),
                      if ([
                            'score',
                            'red_card',
                            'yellow_card',
                            'personal_foul',
                          ].contains(e['type']) &&
                          e['cancelled'] == false &&
                          e['corrected'] != true)
                        TextButton(
                          onPressed: canWrite
                              ? () =>
                                    playerAction(e['type'], e['team'], event: e)
                              : null,
                          child: Text(t('assign_player')),
                        ),
                    ],
                  ),
                ),
              ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    scaffoldMessengerKey: messenger,
    debugShowCheckedModeBanner: false,
    title: 'Score67',
    locale: Locale(lang),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff0b1018),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffb6f36e),
        brightness: Brightness.dark,
        primary: const Color(0xffb6f36e),
        onPrimary: const Color(0xff15200b),
        surface: const Color(0xff151e2a),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(56, 56),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(56, 56),
          textStyle: const TextStyle(fontSize: 16),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(56, 56)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff0b1018),
        surfaceTintColor: Colors.transparent,
      ),
    ),
    home: Builder(
      builder: (context) => Scaffold(
        bottomNavigationBar: liveBasketball
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    widget.releaseLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xffb5c2d4),
                    ),
                  ),
                ),
              ),
        appBar: AppBar(
          leading: IconButton(
            tooltip: t('back'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () => navigate(dashboardPage ? '/' : '/dashboard'),
          ),
          title: liveBasketball
              ? basketballHeader()
              : const Text(
                  'SCORE67',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
          bottom:
              liveBasketball &&
                  MediaQuery.sizeOf(context).width <
                      2 * BasketballStatistics.width + 40
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: basketballTeamBar(),
                )
              : null,
          actions: liveBasketball
              ? []
              : [
                  if (admin && slug.isNotEmpty) syncBadge(),
                  IconButton(
                    tooltip: t('app.settings'),
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: ready ? appSettings : null,
                  ),
                  TextButton(
                    onPressed: ready ? switchLanguage : null,
                    child: Text(lang == 'de' ? 'EN' : 'DE'),
                  ),
                  const SizedBox(width: 12),
                ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: basketball && admin ? 1400 : 760,
              ),
              child: !ready
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: EdgeInsets.all(basketball && admin ? 8 : 20),
                      children: [
                        if (error.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 18),
                            child: Text(
                              t('error.$error'),
                              style: const TextStyle(color: Color(0xffffb4ab)),
                            ),
                          ),
                        if (dashboardPage)
                          Dashboard(
                            api: (path, method, body) =>
                                api(path, method: method, body: body),
                            t: t,
                            navigate: navigate,
                            periods: defaultPeriods,
                            minutes: defaultMinutes,
                          )
                        else if (pin.isNotEmpty)
                          pinView()
                        else if (slug.isEmpty)
                          createView()
                        else if (state.isEmpty)
                          section(t('connecting'), [
                            action(t('retry'), refresh),
                          ])
                        else if (!admin)
                          claimView()
                        else if (state['match_id'] == null)
                          section(t('no_match'), [
                            action(
                              t('dashboard'),
                              () => navigate('/dashboard'),
                              primary: true,
                            ),
                          ])
                        else
                          matchView(),
                      ],
                    ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    refreshTimer?.cancel();
    renderTimer?.cancel();
    reconnectTimer?.cancel();
    retryTimer?.cancel();
    unawaited(wakeLock?.release().toDart);
    subscription?.cancel();
    channel?.sink.close();
    pinInput.dispose();
    deviceName.dispose();
    super.dispose();
  }
}

class HoldAction extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onActivate;
  const HoldAction({
    super.key,
    required this.label,
    required this.enabled,
    required this.onActivate,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    label: label,
    onTap: enabled ? onActivate : null,
    child: Focus(
      onKeyEvent: (_, event) {
        if (enabled &&
            event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: RawGestureDetector(
        gestures: {
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: const Duration(seconds: 1),
                ),
                (instance) =>
                    instance.onLongPress = enabled ? onActivate : null,
              ),
        },
        child: Container(
          padding: const EdgeInsets.all(20),
          constraints: const BoxConstraints(minHeight: 64),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled ? const Color(0xffb6f36e) : const Color(0xff354132),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xff15200b),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}
