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
import 'account.dart';
import 'dashboard.dart';
import 'dates.dart';
import 'squad.dart';
import 'match_console.dart';
import 'team_editor.dart';
import 'displays.dart';
import 'logo_picker.dart';
import 'location_frame.dart';
import 'led_display.dart';
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
  runApp(Score67(releaseLabel: localReleaseLabel(release)));
}

/// "v0.19.1 · 02.10.2026 12:59" in the browser's time zone (stamped in UTC).
String localReleaseLabel(Map<String, dynamic> release) {
  final built = DateTime.tryParse(release['built_at'] ?? '')?.toLocal();
  if (built == null) return release['label'] ?? '';
  return 'v${release['version']} · ${europeanDate(built)} ${europeanTime(built)}';
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
  String lang = 'en', slug = '', error = '';
  bool dashboardPage = false, loginPage = false;
  String loginToken = '';

  /// The live match console (both sports, landscape only).
  bool get liveConsole =>
      ready &&
      admin &&
      !dashboardPage &&
      slug.isNotEmpty &&
      state['match_id'] != null;
  int defaultPeriods = 2, defaultMinutes = 45;
  // Create form: football defaults to 2 × 45, basketball to 4 × 10.
  String draftSport = 'football';
  final periodsInput = TextEditingController(text: '2');
  final minutesInput = TextEditingController(text: '45');
  // Players on the pitch/court at once (youth formats: 4 or 5; 5, 7, 9 or 11).
  final lineupInput = TextEditingController(text: '11');
  int get draftLineup => (int.tryParse(lineupInput.text) ?? 11).clamp(
    1,
    draftSport == 'basketball' ? 5 : 11,
  );
  int get draftPeriods => (int.tryParse(periodsInput.text) ?? 2).clamp(1, 12);
  int get draftMinutes => (int.tryParse(minutesInput.text) ?? 45).clamp(1, 120);
  set draftPeriods(int value) => periodsInput.text = '$value';
  set draftMinutes(int value) => minutesInput.text = '$value';
  bool get basketball => state['sport'] == 'basketball';

  /// Players on court/pitch at once: the game's setting, else the maximum.
  int get lineupSize => (state['lineup_size'] as int?) ?? (basketball ? 5 : 11);
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
  bool landscapeRequested = false;
  // Bluetooth LED displays driven directly by this phone (Android Chrome).
  List<LedConfig> ledConfigs = loadLedConfigs();
  final ledSent = <int, String>{};
  int ledTicks = 0;
  final consoleKey = GlobalKey<MatchConsoleState>();
  Timer? refreshTimer, renderTimer, reconnectTimer, retryTimer;
  WebSocketChannel? channel;
  StreamSubscription? subscription;
  final pinInput = TextEditingController();
  final deviceName = TextEditingController(text: 'Browser');
  final draftDescription = TextEditingController();
  final draftStream = TextEditingController();
  DateTime? draftStart;

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
    loginPage = url.path == '/login';
    loginToken = Uri.splitQueryString(url.fragment)['t'] ?? '';
    try {
      final preferences = jsonDecode(
        web.window.localStorage.getItem('score67-settings') ?? '{}',
      );
      defaultPeriods = (preferences['periods'] as int? ?? 2).clamp(1, 12);
      defaultMinutes = (preferences['minutes'] as int? ?? 45).clamp(1, 120);
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
          sendLed();
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
                  const Divider(height: 28),
                  OutlinedButton.icon(
                    onPressed: openDisplays,
                    icon: const Icon(Icons.scoreboard_outlined),
                    label: Text(t('display.title')),
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
              onPressed: () async {
                final p = int.tryParse(periods.text),
                    m = int.tryParse(minutes.text);
                if (p == null ||
                    p < 1 ||
                    p > 12 ||
                    m == null ||
                    m < 1 ||
                    m > 120) {
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

  /// Sends the current frame to each connected Bluetooth display when it
  /// changes (clock: once per second) and every 5 s as a heartbeat.
  void sendLed() {
    if (++ledTicks % 10 == 0) ledConfigs = loadLedConfigs();
    if (ledConfigs.isEmpty || !Ble.supported || state['match_id'] == null) {
      return;
    }
    for (var slot = 0; slot < ledConfigs.length; slot++) {
      if (Ble.status(slot) != 'connected') continue;
      final frame = ledFrame(
        ledConfigs[slot],
        state,
        clockText(),
        periodLabel(),
      );
      if (frame != ledSent[slot] || ledTicks % 25 == 0) {
        ledSent[slot] = frame;
        unawaited(Ble.write(slot, frame));
      }
    }
  }

  /// Header icon: connected LED displays; a tap connects the next one.
  Widget bleIndicator() {
    if (ledConfigs.isEmpty || !Ble.supported) return const SizedBox.shrink();
    final connected = [
      for (var slot = 0; slot < ledConfigs.length; slot++)
        Ble.status(slot) == 'connected',
    ];
    final count = connected.where((c) => c).length;
    final all = count == ledConfigs.length;
    return IconButton(
      tooltip: t('ble.title'),
      onPressed: all
          ? openDisplays
          : () async {
              final slot = connected.indexOf(false);
              try {
                await Ble.connect(slot);
                ledSent.remove(slot);
              } catch (_) {}
              if (mounted) setState(() {});
            },
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            all ? Icons.bluetooth_connected : Icons.bluetooth,
            color: all
                ? const Color(0xff22c55e)
                : count > 0
                ? Colors.orange
                : Colors.white54,
          ),
          Text(
            '$count/${ledConfigs.length}',
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// Global settings → Anzeigetafeln: pair devices and choose their board.
  Future<void> openDisplays() async {
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => DisplaysDialog(
        api: (path, method, body) => api(path, method: method, body: body),
        t: t,
      ),
    );
    ledConfigs = loadLedConfigs();
    ledSent.clear();
    if (mounted) setState(() {});
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

  /// Full screen plus orientation lock (Android browsers). Browsers without
  /// support (iPhone Safari) fall back to the rotate screen in portrait.
  Future<void> lockLandscape() async {
    landscapeRequested = true;
    try {
      if (web.document.fullscreenElement == null) {
        await web.document.documentElement!.requestFullscreen().toDart;
      }
      await web.window.screen.orientation.lock('landscape').toDart;
    } catch (_) {}
  }

  Widget rotateView() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 12),
    child: Column(
      children: [
        const Icon(Icons.screen_rotation, size: 96, color: Color(0xffb6f36e)),
        const SizedBox(height: 24),
        Text(
          t('basketball.rotate'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20),
        ),
        const SizedBox(height: 24),
        action(t('landscape.enter'), lockLandscape, primary: true),
      ],
    ),
  );

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
          'period_count': draftPeriods,
          'period_length_min': draftMinutes,
          'lineup_size': draftLineup,
          'location': draftLocation,
          'description': draftDescription.text.trim().isEmpty
              ? null
              : draftDescription.text.trim(),
          'scheduled_at': draftStart?.millisecondsSinceEpoch,
          'stream_url': draftStream.text.trim().isEmpty
              ? null
              : draftStream.text.trim(),
        },
      );
      // Straight to the console; PIN and links live in its Sharing tab.
      savePin(result['slug'], result['pin']);
      web.window.location.assign('/s/${result['slug']}/control?lang=$lang');
      return;
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

  /// Spelled-out period for buttons and the game flow: "2. Viertel",
  /// "1. Halbzeit", "Periode 5/8", "Verlängerung 1".
  String periodName(int period) {
    final count = state['period_count'] as int;
    if (period > count && basketball) {
      return t('period.name.ot').replaceAll('{n}', '${period - count}');
    }
    if (count == 1) return t('period.name.game');
    final key = count == 2
        ? 'period.name.half'
        : count == 4
        ? 'period.name.quarter'
        : 'period.name.generic';
    return t(key).replaceAll('{n}', '$period').replaceAll('{count}', '$count');
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
          // Top-aligned so the phone keyboard never covers the fields.
          alignment: Alignment.topCenter,
          insetPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          title: Text(t('settings')),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  field('${t('home')} · ${t('name')}', home, maxLength: 60),
                  field(t('short'), homeShort, maxLength: 3),
                  field('${t('away')} · ${t('name')}', away, maxLength: 60),
                  field(t('short'), awayShort, maxLength: 3),
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
                    l > 120 ||
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
                    savePin(slug, r['pin']);
                    setState(() {});
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
                if (isPrivate)
                  Text(
                    t('privacy.note'),
                    style: const TextStyle(color: Colors.orange),
                  )
                else ...[
                  SelectableText(spectatorUrl),
                  const SizedBox(height: 16),
                  shareActions(),
                ],
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

  bool get isPrivate => state['private'] == true;

  /// The OBS link carries the overlay key so it keeps working while private.
  String get overlayPath => state['overlay_key'] == null
      ? '/s/$slug/overlay'
      : '/s/$slug/overlay?k=${state['overlay_key']}';

  Future<void> setPrivate(bool value) async {
    try {
      await api(
        '/api/s/$slug/privacy',
        method: 'PUT',
        body: {'private': value},
      );
      await refresh();
    } catch (_) {
      notify(t('error.network'));
    }
  }

  List<Widget> linkWidgets() => [
    if (isPrivate)
      Text(t('privacy.note'), style: const TextStyle(color: Colors.orange))
    else ...[
      Text(t('share.spectator')),
      const SizedBox(height: 8),
      shareActions(),
    ],
    const SizedBox(height: 20),
    for (final entry in {
      if (!isPrivate) 'spectator': '/s/$slug',
      'overlay.link': overlayPath,
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

  String dateLabel(int milliseconds) {
    return europeanDateTime(
      DateTime.fromMillisecondsSinceEpoch(milliseconds),
      lang,
    );
  }

  Future<DateTime?> chooseStart(DateTime? current) async {
    final now = DateTime.now();
    final initial = current ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: navigator.currentContext!,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: navigator.currentContext!,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    final chosen = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!chosen.isAfter(DateTime.now())) {
      notify(t('error.schedule_future'));
      return null;
    }
    return chosen;
  }

  Future<void> editDescription() async {
    final input = TextEditingController(text: state['description'] ?? '');
    final stream = TextEditingController(text: state['stream_url'] ?? '');
    final saved = await showDialog<bool>(
      context: navigator.currentContext!,
      builder: (context) => AlertDialog(
        // Top-aligned so the phone keyboard never covers the fields.
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
        title: Text(t('description.edit')),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: input,
                  autofocus: true,
                  maxLength: 300,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: t('description'),
                    hintText: t('description.hint'),
                    helperText: t('description.private'),
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: stream,
                  maxLength: 300,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: t('stream.label'),
                    hintText: 'https://youtube.com/live/…',
                    helperText: t('stream.hint'),
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                  ),
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
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('save')),
          ),
        ],
      ),
    );
    final (text, link) = (input.text.trim(), stream.text.trim());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    stream.dispose();
    if (saved != true) return;
    try {
      await api(
        '/api/s/$slug/description',
        method: 'PUT',
        body: {'description': text.isEmpty ? null : text},
      );
      await api(
        '/api/s/$slug/stream',
        method: 'PUT',
        body: {'stream_url': link.isEmpty ? null : link},
      );
      await refresh();
    } on ApiError catch (e) {
      notify(t('error.${e.code}'));
      await refresh();
    } catch (_) {
      notify(t('error.network'));
    }
  }

  /// Private game facts for controllers: description, creation and start time.
  Widget matchInfo() {
    const muted = TextStyle(fontSize: 14, color: Color(0xffb5c2d4));
    final description = (state['description'] ?? '') as String;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (description.isNotEmpty)
                Text(description, style: const TextStyle(fontSize: 16)),
              if ((state['stream_url'] ?? '').isNotEmpty)
                Text(
                  '▶ ${state['stream_url']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xffff8b8b),
                  ),
                ),
              if (state['created_at'] != null)
                Text(
                  '${t('created')}: ${dateLabel(state['created_at'])}',
                  style: muted,
                ),
              if (state['scheduled_at'] != null)
                Text(
                  '${t('scheduled')}: ${dateLabel(state['scheduled_at'])}',
                  style: muted,
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: t('description.edit'),
          icon: const Icon(Icons.edit_note),
          onPressed: admin && connected ? editDescription : null,
        ),
      ],
    );
  }

  /// − value + around a typeable number, clamped to [low, high].
  Widget numberStepper(
    String label,
    TextEditingController input,
    int low,
    int high, {
    String suffix = '',
  }) {
    final value = (int.tryParse(input.text) ?? low).clamp(low, high);
    void set(int next) => setState(() => input.text = '$next');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton.outlined(
            tooltip: '−',
            onPressed: value > low ? () => set(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 80,
            child: TextField(
              controller: input,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              maxLength: 3,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                suffixText: suffix,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
                set(value);
              },
            ),
          ),
          IconButton.outlined(
            tooltip: '+',
            onPressed: value < high ? () => set(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Widget createView() => section(t('create'), [
    Wrap(
      spacing: 12,
      children: [
        for (final sport in ['football', 'basketball'])
          ChoiceChip(
            label: Text(t(sport)),
            selected: draftSport == sport,
            onSelected: busy
                ? null
                : (_) => setState(() {
                    draftSport = sport;
                    draftPeriods = sport == 'basketball' ? 4 : 2;
                    draftMinutes = sport == 'basketball' ? 10 : 45;
                    lineupInput.text = sport == 'basketball' ? '5' : '11';
                  }),
          ),
      ],
    ),
    const SizedBox(height: 12),
    numberStepper(t('period_count'), periodsInput, 1, 12),
    numberStepper(t('period_length'), minutesInput, 1, 120),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final format
            in draftSport == 'basketball'
                ? const [
                    [4, 10],
                    [4, 12],
                    [8, 5],
                    [2, 20],
                  ]
                : const [
                    [2, 45],
                    [2, 40],
                    [2, 35],
                    [2, 30],
                    [2, 20],
                    [1, 10],
                  ])
          ChoiceChip(
            label: Text('${format[0]} × ${format[1]}'),
            selected: draftPeriods == format[0] && draftMinutes == format[1],
            onSelected: (_) => setState(() {
              draftPeriods = format[0];
              draftMinutes = format[1];
            }),
          ),
      ],
    ),
    Text(
      '$draftPeriods × $draftMinutes min = ${draftPeriods * draftMinutes} min',
      style: const TextStyle(color: Color(0xffb6f36e)),
    ),
    if (draftSport == 'basketball') Text(t('basketball.pilot')),
    const SizedBox(height: 12),
    numberStepper(
      t('lineup_size'),
      lineupInput,
      1,
      draftSport == 'basketball' ? 5 : 11,
    ),
    Wrap(
      spacing: 8,
      children: [
        for (final size
            in draftSport == 'basketball' ? const [4, 5] : const [5, 7, 9, 11])
          ChoiceChip(
            label: Text('$size'),
            selected: draftLineup == size,
            onSelected: (_) => setState(() => lineupInput.text = '$size'),
          ),
      ],
    ),
    Text(t('lineup_size.note')),
    const SizedBox(height: 12),
    Text(t('create.note')),
    const SizedBox(height: 16),
    TextField(
      controller: draftDescription,
      maxLength: 300,
      minLines: 1,
      maxLines: 3,
      decoration: InputDecoration(
        labelText: t('description'),
        hintText: t('description.hint'),
        helperText: t('description.private'),
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 4),
    TextField(
      controller: draftStream,
      maxLength: 300,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        labelText: t('stream.label'),
        hintText: 'https://youtube.com/live/…',
        helperText: t('stream.hint'),
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 12),
    Text(
      '${t('scheduled')}: ${draftStart == null ? t('game.unscheduled') : dateLabel(draftStart!.millisecondsSinceEpoch)}',
    ),
    if (draftStart == null)
      Text(
        t('schedule.hint'),
        style: const TextStyle(fontSize: 14, color: Color(0xfffbbf24)),
      ),
    Wrap(
      spacing: 8,
      children: [
        action(
          t('schedule.choose'),
          busy
              ? null
              : () async {
                  final chosen = await chooseStart(draftStart);
                  if (chosen != null) setState(() => draftStart = chosen);
                },
        ),
        if (draftStart != null)
          action(
            t('schedule.clear'),
            busy ? null : () => setState(() => draftStart = null),
          ),
      ],
    ),
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

  Widget claimView() => section(t('claim'), [
    field(t('pin'), pinInput, numeric: true, maxLength: 6),
    field(t('device'), deviceName, maxLength: 60),
    action(t('claim'), busy || !connected ? null : claim, primary: true),
    const Divider(height: 32),
    Text(t('claim.forgot')),
    const SizedBox(height: 10),
    AccountPanel(
      api: (path, method, body) => api(path, method: method, body: body),
      t: t,
      language: lang,
      intro: false,
    ),
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
          // Top-aligned so the phone keyboard never covers the fields.
          alignment: Alignment.topCenter,
          insetPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
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
                            .take(3)
                            .toString();
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: short,
                    maxLength: 3,
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

  bool get basketballClockRunning =>
      state['clock']['running'] == true && elapsed() < periodLengthMs;

  Future<void> setBasketballClock() async {
    final input = TextEditingController(
      text: mmss((periodLengthMs - elapsed()).clamp(0, periodLengthMs)),
    );
    final revision = state['revision'], match = state['match_id'];
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => AlertDialog(
        // Top-aligned so the phone keyboard never covers the fields.
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
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

  /// Live basketball in landscape replaces the whole page with the console.
  bool console(BuildContext context) =>
      liveConsole && MediaQuery.orientationOf(context) == Orientation.landscape;

  Widget basketballConsole() {
    final phase = state['phase'];
    final last = events.where((e) => e['cancelled'] == false).lastOrNull;
    final running = basketball && basketballClockRunning;
    // Football: the clock runs continuously; Play starts the next half.
    final finalBreak =
        phase == 'break' && state['period'] >= state['period_count'];
    final String? nextPeriod =
        phase == 'pre_game' || (phase == 'break' && !finalBreak)
        ? 'period_start'
        : finalBreak && state['home']['score'] == state['away']['score']
        ? 'overtime_start'
        : null;
    final periodOver =
        basketball &&
        phase == 'period_running' &&
        state['clock']['enabled'] == true &&
        elapsed() >= periodLengthMs;
    // Between periods the console already shows the next one, ready for Play.
    final upcoming =
        (basketball ? nextPeriod != null : false) ||
        (!basketball &&
            (phase == 'pre_game' || phase == 'break') &&
            state['period'] < state['period_count']);
    final nextNumber = (state['period'] as int) + 1;
    final nextMinutes =
        (nextNumber > (state['period_count'] as int)
                ? state['overtime_length_min'] ?? 5
                : state['period_length_min'])
            as int;
    final kickOff =
        !basketball &&
        (phase == 'pre_game' || phase == 'break') &&
        state['period'] < state['period_count'];
    // The period an entry would open before kickoff or in a break.
    final opening = basketball ? nextPeriod : (kickOff ? 'period_start' : null);
    final tied = state['home']['score'] == state['away']['score'];
    final lastPeriod =
        (state['period'] as int) >= (state['period_count'] as int);
    // ⏭ ends a period whose clock was stopped (or never started) before 0:00;
    // in the last period, and after it when not tied, it ends the match.
    final canSkip =
        canWrite &&
        ((phase == 'period_running' &&
                (!basketball || (!running && !periodOver))) ||
            (basketball && finalBreak && !tied));
    return MatchConsole(
      key: consoleKey,
      state: state,
      t: t,
      clock: upcoming && phase != 'pre_game'
          ? basketball
                ? mmss(nextMinutes * 60000)
                : mmss((nextNumber - 1) * nextMinutes * 60000)
          : clockText(),
      period: upcoming
          ? periodLabel({...state, 'period': nextNumber})
          : periodLabel().isEmpty
          ? '–'
          : periodLabel(),
      periodOver: periodOver,
      nextPeriod: opening == null ? null : periodName(nextNumber),
      endedPeriod: (state['period'] as int) == 0
          ? null
          : periodName(state['period'] as int),
      currentPeriod: periodName(state['period'] as int),
      // Prepared (Play not pressed yet): the clock still shows the full period.
      clockNotStarted:
          basketball &&
          phase == 'period_running' &&
          state['clock']['enabled'] == true &&
          !running &&
          elapsed() == 0,
      onStartClock: () => command('clock_start'),
      // Starting a forgotten period also starts its clock, like Play.
      onStartNext: () async {
        if (opening == null) return true;
        if (!await command(opening)) return false;
        return !basketball || state['clock']['enabled'] != true
            ? true
            : command('clock_start');
      },
      onSkipPeriod: canSkip ? endPeriod : null,
      skipEndsGame: lastPeriod && !(basketball && tied),
      onToggleActive: toggleActive,
      lineupMax: lineupSize,
      running: running,
      canToggleClock: basketball
          ? canWrite &&
                state['clock']['enabled'] == true &&
                (phase == 'period_running' || nextPeriod != null)
          : canWrite && kickOff,
      canTap: canTap,
      canWrite: canWrite,
      connected: connected,
      sync: Row(
        mainAxisSize: MainAxisSize.min,
        children: [bleIndicator(), syncBadge()],
      ),
      onMenu: openMenu,
      onToggleClock: periodOver
          ? endPeriod
          : basketball
          ? () async {
              // Play also opens the next period (or overtime), then starts the clock.
              if (phase != 'period_running' && !await command(nextPeriod!)) {
                return;
              }
              await command(running ? 'clock_stop' : 'clock_start');
            }
          : () => command('period_start'),
      onClockTap: () {
        if (basketball && canWrite && phase == 'period_running') {
          setBasketballClock();
        }
      },
      onUndo: last != null && canWrite ? undoVisible : null,
      onSubstitutions: editLineup,
      onAction: consoleAction,
      onPossession: (team) => command('possession', {'team': team}),
      onEditTeam: (team) {
        if (canWrite) editTeam(team);
      },
      onEditPlayer: editPlayer,
      onScoreTap: adjustScore,
      tabs: [
        (t('console.flow'), gameFlow()),
        (t('console.team'), teamTab()),
        (t('console.period'), periodPanel()),
        (t('console.settings'), settingsPanel()),
        (t('console.sharing'), sharingPanel()),
      ],
    );
  }

  /// Ends the running period. The last one (and a final break that is not
  /// tied) ends the match after the final result is confirmed; a tied last
  /// basketball period leads to overtime instead.
  Future<void> endPeriod() async {
    final last = (state['period'] as int) >= (state['period_count'] as int);
    final tied = state['home']['score'] == state['away']['score'];
    if (state['phase'] == 'break') {
      if (await confirmFinal()) await command('game_end');
      return;
    }
    if (basketball) {
      // The server ends the match after the last period unless tied.
      if (last && !tied && !await confirmFinal()) return;
      await command('period_end');
    } else if (last) {
      if (await confirmFinal()) await command('game_end');
    } else {
      await command('period_end');
    }
  }

  /// The match's end: the final result (and per-period scores) to confirm.
  Future<bool> confirmFinal() async =>
      await showDialog<bool>(
        context: navigator.currentContext!,
        builder: (context) => AlertDialog(
          alignment: Alignment.topCenter,
          insetPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          title: Text(t('final.title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${state['home']['name']}  ${state['home']['score']} : ${state['away']['score']}  ${state['away']['name']}',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                periodScores(),
                const SizedBox(height: 8),
                Text(t('final.note'), style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('final.confirm')),
            ),
          ],
        ),
      ) ??
      false;

  /// A player tapped without an action: on court or back to the bench.
  void toggleActive(String team, String playerId) {
    final court = [...(state[team]['on_court'] as List? ?? []).cast<String>()];
    court.contains(playerId) ? court.remove(playerId) : court.add(playerId);
    command('lineup', {'team': team, 'player_ids': court});
  }

  /// Action first, then a player; a team tile records for the team only.
  void consoleAction(String action, String team, String? playerId) {
    final player = {'player_id': ?playerId};
    switch (action) {
      case 'goal':
        command('score', {'team': team, 'points': 1, ...player});
      case 'penalty_goal':
        command('score', {
          'team': team,
          'points': 1,
          'detail': 'penalty',
          ...player,
        });
      case 'yellow' || 'red':
        command('${action}_card', {'team': team, ...player});
      case 'penalty' || 'free_kick':
        command(action, {'team': team, ...player});
      case 'foul' when !basketball:
        command('foul', {'team': team, ...player});
      case 'ft' || '2pt' || '3pt':
        final points = {'ft': 1, '2pt': 2, '3pt': 3}[action]!;
        command('score', {'team': team, 'points': points, ...player});
      case 'foul':
        if (state['foul_mode'] == 'team') {
          command('team_foul', {'team': team});
        } else {
          command('personal_foul', {'team': team, ...player});
        }
      case 'tech':
        command('technical_foul', {'team': team, ...player});
      case 'reb':
        command('rebound', {'team': team, ...player});
      case 'ft_hit':
        command('score', {
          'team': team,
          'points': 1,
          'detail': 'free_throw',
          ...player,
        });
      case 'ft_miss':
        command('free_throw_missed', {'team': team, ...player});
      case 'timeout':
        command('timeout', {'team': team});
    }
  }

  String eventStamp(dynamic e) {
    final label = periodLabel(Map<String, dynamic>.from(e));
    if (e['clock_ms'] == null || (e['period'] ?? 0) == 0) return label;
    if (!basketball) {
      // Football: the started match minute, e.g. 23′ or 45+2′.
      final length = e['period_length_min'] * 60000;
      final ms = e['clock_ms'] as num;
      return ms > length
          ? '${e['period'] * e['period_length_min']}+${((ms - length) / 60000).ceil()}′'
          : '${((e['period'] - 1) * length + ms) ~/ 60000 + 1}′';
    }
    final length = e['period_duration_ms'] ?? e['period_length_min'] * 60000;
    return '$label ${mmss((length - e['clock_ms']).toInt().clamp(0, 3600000))}';
  }

  String flowWhat(dynamic e) {
    String players(List? list) =>
        (list ?? []).map((p) => playerLabel(p)).join(', ');
    switch (e['type']) {
      case 'score' when !basketball:
        return '${t('console.goal_short')}${e['detail'] == 'penalty' ? ' (${t('console.penalty_short')})' : ''}';
      case 'score_correction' when !basketball:
        return t('score_correction');
      case 'foul':
        return t('console.foul_short');
      case 'free_kick':
        return t('console.free_kick_short');
      case 'free_throw_missed':
        return t('console.ft_missed');
      case 'score_adjust':
        return '${t('console.admin_adjust')} ${e['points'] > 0 ? '+' : ''}${e['points']}';
      case 'penalty':
        return t('console.penalty_short');
      case 'score':
        return e['points'] == 1 ? t('console.ft_made') : '${e['points']} PTS';
      case 'score_correction':
        return '${e['points']} PTS';
      case 'lineup':
        return '${t('console.subs_short')} ↑ ${players(e['entered'])}${(e['left'] as List? ?? []).isEmpty ? '' : ' ↓ ${players(e['left'])}'}';
      case 'personal_foul':
        return t('console.foul_short');
      case 'technical_foul':
        return t('console.tech_short');
      case 'team_foul':
        return t('console.team_foul_short');
      case 'timeout':
        return t('console.timeout_short');
      case 'possession':
        return '${t('possession')} ${e['team'] == null ? '–' : state[e['team']]['short']}';
      case 'period_start' || 'overtime_start':
        return t(
          'flow.period_started',
        ).replaceAll('{p}', periodName((e['period'] ?? 1) as int));
      case 'period_end':
        return t(
          'flow.period_ended',
        ).replaceAll('{p}', periodName((e['period'] ?? 1) as int));
      default:
        return t(e['type']);
    }
  }

  /// Admin correction of a wrong score; logged as its own game-flow entry.
  Future<void> adjustScore(String team) async {
    final current = state[team]['score'] as int;
    final input = TextEditingController(text: '$current');
    final revision = state['revision'];
    final target = await showDialog<int>(
      context: navigator.currentContext!,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final value = int.tryParse(input.text.trim());
          void step(int by) => update(() {
            input.text = '${((value ?? current) + by).clamp(0, 999)}';
          });
          return AlertDialog(
            alignment: Alignment.topCenter,
            insetPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            title: Text('${t('score.adjust')} · ${state[team]['name']}'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.outlined(
                        onPressed: () => step(-1),
                        icon: const Icon(Icons.remove),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 96,
                        child: TextField(
                          controller: input,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          maxLength: 3,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                          ),
                          decoration: const InputDecoration(
                            counterText: '',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => update(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.outlined(
                        onPressed: () => step(1),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    value == null || value == current
                        ? t('score.adjust_note')
                        : '${t('console.admin_adjust')} ${value > current ? '+' : ''}${value - current}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('cancel')),
              ),
              FilledButton(
                onPressed: value == null || value < 0 || value == current
                    ? null
                    : () => Navigator.pop(context, value),
                child: Text(t('save')),
              ),
            ],
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (target == null || !mounted) return;
    if (state['revision'] != revision) {
      notify(t('error.state_changed'));
      return;
    }
    await command('score_adjust', {'team': team, 'delta': target - current});
  }

  /// Change one player's number or name (double-tap on a console tile).
  Future<void> editPlayer(String team, String playerId) async {
    if (!canWrite) return;
    final squad = [
      for (final p in state[team]['squad'] as List? ?? [])
        Map<String, dynamic>.from(p),
    ];
    final player = squad.where((p) => p['id'] == playerId).firstOrNull;
    if (player == null) return;
    final number = TextEditingController(text: player['number']);
    final name = TextEditingController(text: player['name']);
    final revision = state['revision'];
    final ok = await showDialog<bool>(
      context: navigator.currentContext!,
      builder: (context) => AlertDialog(
        // Top-aligned so the phone keyboard never covers the fields.
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
        title: Text('${t('player.edit')} · ${state[team]['short']}'),
        content: SizedBox(
          width: 360,
          child: Row(
            children: [
              SizedBox(
                width: 80,
                child: TextField(
                  controller: number,
                  maxLength: 3,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t('player.number'),
                    counterText: '',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: t('player.name'),
                    counterText: '',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => Navigator.pop(context, true),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('save')),
          ),
        ],
      ),
    );
    final values = (number.text.trim(), name.text.trim());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    number.dispose();
    name.dispose();
    if (ok != true || !mounted) return;
    if (state['revision'] != revision) {
      notify(t('error.state_changed'));
      return;
    }
    player
      ..['number'] = values.$1
      ..['name'] = values.$2;
    // Server validation reports duplicates, missing basketball numbers etc.
    await command('squad', {'team': team, 'players': squad});
  }

  Widget teamTab() => TeamEditor(
    state: state,
    t: t,
    enabled: canWrite,
    onSave: (team, players, onCourt) async {
      // Squad first: the lineup may only name players in the saved squad.
      if (!await command('squad', {'team': team, 'players': players})) {
        return false;
      }
      return command('lineup', {'team': team, 'player_ids': onCourt});
    },
  );

  /// Clock toggles and team/match setup stay recorded (undo, history) but
  /// are not shown in the game flow. Substitutions during play are shown.
  static const hiddenInFlow = {
    'clock_start',
    'clock_stop',
    'clock_set',
    'clock_adjust',
    'squad',
    'settings',
    'overlay',
  };
  bool visibleInFlow(dynamic e) =>
      !hiddenInFlow.contains(e['type']) &&
      !(e['type'] == 'lineup' && (e['period'] ?? 0) == 0);

  static const removableTallies = {
    'score',
    'personal_foul',
    'technical_foul',
    'team_foul',
    'timeout',
    'red_card',
    'yellow_card',
    'foul',
    'free_kick',
    'penalty',
    'free_throw_missed',
  };

  /// Undo what the game flow shows last. A hidden clock entry after it is
  /// left alone: a tally is removed by correction instead.
  Future<void> undoVisible() async {
    final active = events.where((e) => e['cancelled'] == false).toList();
    if (active.isEmpty) return;
    final visible = active
        .where(
          (e) =>
              visibleInFlow(e) &&
              e['corrected'] != true &&
              !(e['type'] as String).endsWith('_correction'),
        )
        .lastOrNull;
    if (visible == null || identical(visible, active.last)) {
      await command('undo', {'event_id': active.last['id']});
    } else if (removableTallies.contains(visible['type'])) {
      await command('${visible['type']}_correction', {
        'team': visible['team'],
        'event_id': visible['id'],
      });
    } else {
      await command('undo', {'event_id': active.last['id']});
    }
  }

  Widget gameFlow() {
    final list = events.reversed.where(visibleInFlow).toList();
    if (list.isEmpty) {
      return Center(child: Text(t('log.empty')));
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, index) {
        final e = list[index];
        final inactive = e['cancelled'] == true || e['corrected'] == true;
        final team = e['team'];
        final player = e['player'];
        final line = [
          if (team != null && e['type'] != 'possession') state[team]['short'],
          eventStamp(e),
          flowWhat(e),
          if (player != null) playerLabel(player),
        ].where((part) => '$part'.isNotEmpty).join('  ');
        return InkWell(
          onTap: inactive ? null : () => eventMenu(e),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              line,
              style: TextStyle(
                fontSize: 17,
                color: inactive ? Colors.grey : null,
                decoration: inactive ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Remove a recorded entry or give it to another player.
  Future<void> eventMenu(dynamic e) async {
    const removable = {
      'score',
      'personal_foul',
      'technical_foul',
      'team_foul',
      'timeout',
      'red_card',
      'yellow_card',
      'foul',
      'free_kick',
      'penalty',
      'free_throw_missed',
    };
    const assignable = {
      'score',
      'personal_foul',
      'red_card',
      'yellow_card',
      'foul',
      'free_kick',
      'penalty',
      'free_throw_missed',
    };
    final type = e['type'] as String;
    final choice = await showModalBottomSheet<String>(
      context: navigator.currentContext!,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(flowWhat(e)), subtitle: Text(eventStamp(e))),
            if (removable.contains(type))
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(t('console.remove')),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            if (assignable.contains(type) &&
                (state[e['team']]['squad'] as List? ?? []).isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person),
                title: Text(t('assign_player')),
                onTap: () => Navigator.pop(context, 'assign'),
              ),
          ],
        ),
      ),
    );
    if (choice == 'remove') {
      await command('${type}_correction', {
        'team': e['team'],
        'event_id': e['id'],
      });
    } else if (choice == 'assign') {
      await playerAction(type, e['team'], event: e);
    }
  }

  Widget footballPeriodPanel() {
    final phase = state['phase'];
    final last = state['period'] >= state['period_count'];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Center(
          child: Text(
            t(
              phase == 'break' && state['period_count'] == 2
                  ? 'halftime'
                  : phase,
            ),
            style: const TextStyle(
              color: Color(0xffb6f36e),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if ((phase == 'pre_game' || phase == 'break') && !last)
          action(
            t(
              'period.start_named',
            ).replaceAll('{p}', periodName((state['period'] as int) + 1)),
            canWrite ? () => command('period_start') : null,
            primary: true,
          ),
        if (phase == 'period_running' && !last)
          HoldAction(
            label:
                '${t('period.end_named').replaceAll('{p}', periodName(state['period'] as int))} · ${t('hold')}',
            enabled: canWrite,
            onActivate: () => command('period_end'),
          ),
        if (phase != 'finished')
          HoldAction(
            label: '${t('game_end')} · ${t('hold')}',
            enabled: canWrite,
            onActivate: () async {
              if (await confirmFinal()) {
                await command('game_end');
              }
            },
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
        if (state['clock']['enabled'] == true) ...[
          const SizedBox(height: 8),
          Text(t('console.clock_correct')),
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
        ],
      ],
    );
  }

  Widget periodPanel() {
    if (!basketball) return footballPeriodPanel();
    final phase = state['phase'];
    final finalBreak =
        phase == 'break' && state['period'] >= state['period_count'];
    final tied = state['home']['score'] == state['away']['score'];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Center(child: periodScores()),
        if (phase == 'pre_game' || (phase == 'break' && !finalBreak))
          action(
            t(
              'period.prepare_named',
            ).replaceAll('{p}', periodName((state['period'] as int) + 1)),
            canWrite ? () => command('period_start') : null,
            primary: true,
          ),
        if (finalBreak && tied)
          action(
            t('overtime_start'),
            canWrite ? () => command('overtime_start') : null,
            primary: true,
          ),
        if (phase == 'period_running')
          HoldAction(
            label:
                '${t('period.end_named').replaceAll('{p}', periodName(state['period'] as int))} · ${t('hold')}',
            enabled: canWrite,
            onActivate: () => command('period_end'),
          ),
        if (phase != 'finished')
          action(
            t('game_end'),
            canWrite
                ? () async {
                    if (await confirmFinal()) {
                      await command('game_end');
                    }
                  }
                : null,
            primary: finalBreak && !tied,
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
        if (state['clock']['enabled'] == true && phase == 'period_running')
          action(t('clock_set'), canWrite ? setBasketballClock : null),
      ],
    );
  }

  /// The PIN is stored hashed on the server; only the creating (or rotating)
  /// device keeps a copy so it can be shown again here.
  String get pinKey => 'score67-pin:$slug';
  String? get storedPin {
    try {
      return web.window.localStorage.getItem(pinKey);
    } catch (_) {
      return null;
    }
  }

  void savePin(String board, String value) {
    try {
      web.window.localStorage.setItem('score67-pin:$board', value);
    } catch (_) {}
  }

  Widget sharingPanel() {
    final known = storedPin;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('privacy.private')),
          subtitle: Text(
            t(isPrivate ? 'privacy.private_on' : 'privacy.private_off'),
          ),
          value: isPrivate,
          onChanged: admin && connected ? setPrivate : null,
        ),
        const Divider(height: 20),
        Text(t('pin'), style: const TextStyle(fontWeight: FontWeight.w700)),
        if (known != null) ...[
          SelectableText(
            known,
            style: const TextStyle(
              fontSize: 24,
              letterSpacing: 8,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(t('sharing.pin_note'), style: const TextStyle(fontSize: 14)),
          action(t('copy'), () => copy(known)),
        ] else
          Text(t('sharing.pin_unknown'), style: const TextStyle(fontSize: 14)),
        action(t('pin.rotate'), canWrite ? rotatePin : null),
        action(t('admins'), manageAccess),
        const Divider(height: 28),
        OwnerPanel(
          api: (path, method, body) => api(path, method: method, body: body),
          t: t,
          slug: slug,
          language: lang,
          enabled: admin && connected,
        ),
        const Divider(height: 28),
        const SizedBox(height: 8),
        ...linkWidgets(),
      ],
    );
  }

  Future<void> rotatePin() async {
    if (!await confirm(t('pin.rotate.confirm'))) return;
    try {
      final r = await api('/api/s/$slug/pin', method: 'POST');
      savePin(slug, r['pin']);
      if (mounted) setState(() {});
    } catch (_) {
      notify(t('error.network'));
    }
  }

  // Settings tab: every game setting inline (no dialogs). Drafts follow the
  // game until edited; a section with unsaved edits keeps them (Save/Reset).
  final setPeriods = TextEditingController(),
      setMinutes = TextEditingController(),
      setLineup = TextEditingController(),
      setSeconds = TextEditingController(text: '0'),
      setDelay = TextEditingController(),
      setDescription = TextEditingController(),
      setStream = TextEditingController();
  final setName = {
        'home': TextEditingController(),
        'away': TextEditingController(),
      },
      setShort = {
        'home': TextEditingController(),
        'away': TextEditingController(),
      };
  final setColor = <String, String>{};
  bool setClock = true;
  String settingsSeen = '';
  Map<String, Object?> formatSynced = {}, teamsSynced = {}, textsSynced = {};
  bool showMap = false;
  Map<String, dynamic>? mapLocation;
  String? venueLabel;

  Map<String, Object?> formatDraft() => {
    'count': setPeriods.text,
    'minutes': setMinutes.text,
    'lineup': setLineup.text,
    'clock': setClock,
    'delay': setDelay.text,
  };
  Map<String, Object?> teamsDraft() => {
    for (final team in ['home', 'away']) ...{
      '$team.name': setName[team]!.text,
      '$team.short': setShort[team]!.text,
      '$team.color': setColor[team],
    },
  };
  Map<String, Object?> textsDraft() => {
    'description': setDescription.text,
    'stream': setStream.text,
  };
  bool same(Map a, Map b) =>
      a.length == b.length && a.keys.every((k) => a[k] == b[k]);

  /// Loads the game's values into every section that has no unsaved edits.
  void syncSettings({bool force = false}) {
    final seen = '${state['match_id']}:${state['revision']}';
    if (!force && seen == settingsSeen) return;
    settingsSeen = seen;
    if (force || formatSynced.isEmpty || same(formatDraft(), formatSynced)) {
      setPeriods.text = '${state['period_count']}';
      setMinutes.text = '${state['period_length_min']}';
      setLineup.text = '$lineupSize';
      setClock = state['clock']['enabled'] == true;
      setDelay.text = '${state['overlay']['delay_ms']}';
      formatSynced = formatDraft();
    }
    if (force || teamsSynced.isEmpty || same(teamsDraft(), teamsSynced)) {
      for (final team in ['home', 'away']) {
        setName[team]!.text = state[team]['name'];
        setShort[team]!.text = state[team]['short'];
        setColor[team] = state[team]['color'];
      }
      teamsSynced = teamsDraft();
    }
    if (force || textsSynced.isEmpty || same(textsDraft(), textsSynced)) {
      setDescription.text = state['description'] ?? '';
      setStream.text = state['stream_url'] ?? '';
      textsSynced = textsDraft();
    }
  }

  Widget settingsCard(
    String title,
    List<Widget> children, {
    bool dirty = false,
    VoidCallback? onSave,
    VoidCallback? onReset,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xff111a26),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: dirty ? const Color(0xffb6f36e) : const Color(0xff2a3647),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          dirty ? '$title •' : title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        ...children,
        if (onSave != null)
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: dirty && canWrite ? onSave : null,
                child: Text(t('save')),
              ),
              if (dirty)
                TextButton(onPressed: onReset, child: Text(t('reset'))),
            ],
          ),
      ],
    ),
  );

  Future<void> saveFormat() async {
    final c = int.tryParse(setPeriods.text),
        l = int.tryParse(setMinutes.text),
        n = int.tryParse(setLineup.text),
        d = int.tryParse(setDelay.text),
        e = int.tryParse(setSeconds.text);
    if (c == null || l == null || n == null || d == null || e == null) {
      notify(t('error.invalid_value'));
      return;
    }
    final payload = <String, dynamic>{
      'period_count': c,
      'period_length_min': l,
      'lineup_size': n,
    };
    if (setClock != (state['clock']['enabled'] == true)) {
      payload['clock_enabled'] = setClock;
      if (setClock) payload['clock_elapsed_ms'] = e * 1000;
    }
    final draft = formatDraft();
    if (await command('settings', payload) &&
        (d == state['overlay']['delay_ms'] ||
            await command('overlay', {'delay_ms': d}))) {
      formatSynced = draft;
      syncSettings(force: true);
      if (mounted) setState(() {});
    }
  }

  Future<void> saveTeams() async {
    final payload = <String, dynamic>{
      for (final team in ['home', 'away'])
        team: {
          'name': setName[team]!.text,
          'short': setShort[team]!.text,
          'color': setColor[team],
        },
    };
    final draft = teamsDraft();
    if (await command('settings', payload)) {
      teamsSynced = draft;
      syncSettings(force: true);
      if (mounted) setState(() {});
    }
  }

  Future<void> saveTexts() async {
    final (text, link) = (setDescription.text.trim(), setStream.text.trim());
    try {
      await api(
        '/api/s/$slug/description',
        method: 'PUT',
        body: {'description': text.isEmpty ? null : text},
      );
      await api(
        '/api/s/$slug/stream',
        method: 'PUT',
        body: {'stream_url': link.isEmpty ? null : link},
      );
      textsSynced = textsDraft();
      await refresh();
      notify(t('saved'));
    } on ApiError catch (e) {
      notify(t('error.${e.code}'));
    } catch (_) {
      notify(t('error.network'));
    }
  }

  Future<void> toggleMap() async {
    if (showMap) {
      setState(() => showMap = false);
      return;
    }
    try {
      final result = await api('/api/s/$slug/location');
      mapLocation = result['location'] == null
          ? null
          : Map<String, dynamic>.from(result['location']);
      if (mounted) setState(() => showMap = true);
    } catch (_) {
      notify(t('error.network'));
    }
  }

  Widget settingsPanel() {
    syncSettings();
    final formatDirty = !same(formatDraft(), formatSynced);
    final teamsDirty = !same(teamsDraft(), teamsSynced);
    final textsDirty = !same(textsDraft(), textsSynced);
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
    void edited() => setState(() {});
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        matchInfo(),
        const SizedBox(height: 8),
        settingsCard(
          t('settings.format'),
          [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final format
                    in basketball
                        ? const [
                            [4, 10],
                            [4, 12],
                            [8, 5],
                            [2, 20],
                          ]
                        : const [
                            [2, 45],
                            [2, 40],
                            [2, 35],
                            [2, 30],
                            [2, 20],
                            [1, 10],
                          ])
                  ChoiceChip(
                    label: Text('${format[0]} × ${format[1]}'),
                    selected:
                        setPeriods.text == '${format[0]}' &&
                        setMinutes.text == '${format[1]}',
                    onSelected: (_) => setState(() {
                      setPeriods.text = '${format[0]}';
                      setMinutes.text = '${format[1]}';
                    }),
                  ),
              ],
            ),
            numberStepper(t('period_count'), setPeriods, 1, 12),
            numberStepper(t('period_length'), setMinutes, 1, 120),
            numberStepper(t('lineup_size'), setLineup, 1, basketball ? 5 : 11),
            Wrap(
              spacing: 8,
              children: [
                for (final size
                    in basketball ? const [4, 5] : const [5, 7, 9, 11])
                  ChoiceChip(
                    label: Text('$size'),
                    selected: setLineup.text == '$size',
                    onSelected: (_) => setState(() => setLineup.text = '$size'),
                  ),
              ],
            ),
            Text(
              t('lineup_size.note'),
              style: const TextStyle(fontSize: 13, color: Color(0xffb5c2d4)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('clock_enabled')),
              value: setClock,
              onChanged: (v) => setState(() => setClock = v),
            ),
            if (setClock &&
                state['clock']['enabled'] != true &&
                state['phase'] == 'period_running')
              field(t('clock_elapsed'), setSeconds, numeric: true),
            field(t('delay'), setDelay, numeric: true),
          ],
          dirty: formatDirty,
          onSave: saveFormat,
          onReset: () => setState(() => syncSettings(force: true)),
        ),
        if (basketball)
          settingsCard(t('foul.mode'), [
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
          ]),
        settingsCard(
          t('settings.teams'),
          [
            for (final team in ['home', 'away']) ...[
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: setName[team],
                      maxLength: 60,
                      onChanged: (_) => edited(),
                      decoration: InputDecoration(
                        labelText: '${t(team)} · ${t('name')}',
                        counterText: '',
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: setShort[team],
                      maxLength: 3,
                      textCapitalization: TextCapitalization.characters,
                      onChanged: (_) => edited(),
                      decoration: InputDecoration(
                        labelText: t('short'),
                        counterText: '',
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final color in palette)
                    InkWell(
                      onTap: () => setState(() => setColor[team] = color),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: hexColor(color),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: setColor[team] == color
                                ? const Color(0xffb6f36e)
                                : Colors.white24,
                            width: setColor[team] == color ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ],
          dirty: teamsDirty,
          onSave: saveTeams,
          onReset: () => setState(() => syncSettings(force: true)),
        ),
        settingsCard(t('overlay'), [
          Wrap(
            spacing: 8,
            children: [
              for (final entry in {
                'small': 'scoreboard',
                'big': 'score_big',
                'hidden': 'hidden',
              }.entries)
                ChoiceChip(
                  label: Text(t(entry.key)),
                  selected: state['overlay']['view'] == entry.value,
                  onSelected: canWrite
                      ? (_) => command('overlay', {
                          'view': entry.value,
                          'auto_big': false,
                        })
                      : null,
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('auto_big')),
            value: state['overlay']['auto_big'] == true,
            onChanged: canWrite
                ? (v) => command('overlay', {'auto_big': v})
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('right')),
            value: state['overlay']['position'] == 'top_right',
            onChanged: canWrite
                ? (v) => command('overlay', {
                    'position': v ? 'top_right' : 'top_left',
                  })
                : null,
          ),
        ]),
        settingsCard(
          t('description.edit'),
          [
            TextField(
              controller: setDescription,
              maxLength: 300,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => edited(),
              decoration: InputDecoration(
                labelText: t('description'),
                hintText: t('description.hint'),
                helperText: t('description.private'),
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: setStream,
              maxLength: 300,
              keyboardType: TextInputType.url,
              onChanged: (_) => edited(),
              decoration: InputDecoration(
                labelText: t('stream.label'),
                hintText: 'https://youtube.com/live/…',
                helperText: t('stream.hint'),
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          dirty: textsDirty,
          onSave: saveTexts,
          onReset: () => setState(() => syncSettings(force: true)),
        ),
        settingsCard(t('location.title'), [
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: admin && connected ? toggleMap : null,
              icon: Icon(showMap ? Icons.expand_less : Icons.map_outlined),
              label: Text(t(showMap ? 'close' : 'location.edit_map')),
            ),
          ),
          if (showMap) ...[
            const SizedBox(height: 8),
            LocationFrame(
              current: mapLocation,
              lang: lang,
              title: t('location.title'),
              onSave: (chosen) async {
                try {
                  await api(
                    '/api/s/$slug/location',
                    method: 'PUT',
                    body: {'location': chosen},
                  );
                  await refresh();
                  notify(t('saved'));
                  if (mounted) setState(() => showMap = false);
                  return true;
                } catch (_) {
                  notify(t('error.network'));
                  return false;
                }
              },
            ),
          ],
        ]),
        settingsCard(t('display.title'), [
          DisplaysDialog(
            api: (path, method, body) => api(path, method: method, body: body),
            t: t,
            inline: true,
          ),
        ]),
        settingsCard(t('language'), [
          Wrap(
            spacing: 8,
            children: [
              for (final entry in {'de': 'Deutsch', 'en': 'English'}.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: lang == entry.key,
                  onSelected: (_) {
                    if (lang != entry.key) switchLanguage();
                  },
                ),
            ],
          ),
        ]),
        Text(widget.releaseLabel, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Future<void> openMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: navigator.currentContext!,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in [
                ('teams', Icons.groups, t('menu.edit_teams')),
                if (state['phase'] != 'finished') ...[
                  ('pause', Icons.pause_circle_outline, t('menu.pause')),
                  ('close', Icons.flag_outlined, t('menu.close')),
                ],
                ('dashboard', Icons.dashboard_outlined, t('dashboard')),
                ('displays', Icons.scoreboard_outlined, t('display.title')),
                ('links', Icons.link, t('links')),
                ('share', Icons.share_outlined, t('share.spectator')),
                ('location', Icons.place_outlined, t('location.title')),
                ('description', Icons.edit_note, t('description.edit')),
                (
                  'language',
                  Icons.language,
                  lang == 'de' ? 'English' : 'Deutsch',
                ),
              ])
                ListTile(
                  leading: Icon(entry.$2),
                  title: Text(entry.$3),
                  onTap: () => Navigator.pop(context, entry.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    final [kind, ...rest] = choice.split(':');
    switch (kind) {
      case 'teams':
        consoleKey.currentState?.showTab(1);
      case 'pause':
        // The game stays open (resume from "My scoreboards"); a running
        // basketball clock is stopped first.
        if (basketball && basketballClockRunning) {
          if (!await command('clock_stop')) return;
        }
        navigate('/');
      case 'close':
        if (!await confirmFinal()) return;
        if (await command('game_end')) navigate('/');
      case 'dashboard':
        navigate('/dashboard');
      // In the console these live inline in the Settings / Sharing tabs.
      case 'displays' || 'location' || 'description'
          when consoleKey.currentState != null:
        consoleKey.currentState!.showTab(3);
      case 'links' || 'share' when consoleKey.currentState != null:
        consoleKey.currentState!.showTab(4);
      case 'displays':
        await openDisplays();
      case 'links':
        await manageAccess();
      case 'share':
        await showSharing();
      case 'location':
        await editLocation();
      case 'description':
        await editDescription();
      case 'language':
        await switchLanguage();
    }
  }

  /// Choose the players on court (5 basketball, 11 football); the console
  /// shows only them.
  Future<void> editLineup(String team) async {
    final squad = [
      for (final p in state[team]['squad'] as List? ?? [])
        Map<String, dynamic>.from(p),
    ];
    if (squad.isEmpty) {
      await editSquad(team);
      return;
    }
    squad.sort(
      (a, b) => (int.tryParse(a['number'] ?? '') ?? 999).compareTo(
        int.tryParse(b['number'] ?? '') ?? 999,
      ),
    );
    final selected = {
      ...(state[team]['on_court'] as List? ?? []).cast<String>(),
    };
    final limit = lineupSize;
    final revision = state['revision'], match = state['match_id'];
    final result = await showDialog<List<String>>(
      context: navigator.currentContext!,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            '${t('console.lineup')} · ${state[team]['name']} (${selected.length}/$limit)',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in squad)
                    FilterChip(
                      label: Text(
                        playerLabel(p),
                        style: const TextStyle(fontSize: 18),
                      ),
                      selected: selected.contains(p['id']),
                      onSelected: (on) => update(() {
                        if (!on) {
                          selected.remove(p['id']);
                        } else if (selected.length < limit) {
                          selected.add(p['id']);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                editSquad(team);
              },
              child: Text(t('squad')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected.toList()),
              child: Text(t('save')),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (state['revision'] != revision || state['match_id'] != match) {
      notify(t('error.state_changed'));
      return;
    }
    await command('lineup', {'team': team, 'player_ids': result});
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    scaffoldMessengerKey: messenger,
    debugShowCheckedModeBanner: false,
    title: 'Score67',
    // English uses the British locale: day-first date picker, weeks
    // starting Monday and a 24-hour time picker (European defaults).
    locale: lang == 'en' ? const Locale('en', 'GB') : Locale(lang),
    supportedLocales: const [Locale('de'), Locale('en', 'GB'), Locale('en')],
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
      builder: (context) => Listener(
        // Fullscreen and orientation lock need a user gesture: use the first tap.
        onPointerUp: (_) {
          if (liveConsole && !landscapeRequested) unawaited(lockLandscape());
        },
        child: Scaffold(
          bottomNavigationBar: liveConsole
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
          appBar: console(context)
              ? null
              : AppBar(
                  leading: IconButton(
                    tooltip: t('back'),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () =>
                        navigate(dashboardPage ? '/' : '/dashboard'),
                  ),
                  title: liveConsole && basketball
                      ? basketballHeader()
                      : const Text(
                          'SCORE67',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1,
                          ),
                        ),
                  actions: liveConsole
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
          body: console(context)
              ? SafeArea(child: basketballConsole())
              : SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: basketball && admin ? 1400 : 760,
                      ),
                      child: !ready
                          ? const Center(child: CircularProgressIndicator())
                          : ListView(
                              padding: EdgeInsets.all(
                                basketball && admin ? 8 : 20,
                              ),
                              children: [
                                if (error.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 18),
                                    child: Text(
                                      t('error.$error'),
                                      style: const TextStyle(
                                        color: Color(0xffffb4ab),
                                      ),
                                    ),
                                  ),
                                if (loginPage)
                                  LoginConfirm(
                                    api: (path, method, body) =>
                                        api(path, method: method, body: body),
                                    t: t,
                                    token: loginToken,
                                    navigate: navigate,
                                  )
                                else if (dashboardPage)
                                  Dashboard(
                                    language: lang,
                                    api: (path, method, body) =>
                                        api(path, method: method, body: body),
                                    t: t,
                                    navigate: navigate,
                                    periods: defaultPeriods,
                                    minutes: defaultMinutes,
                                    pickLogo: pickLogo,
                                  )
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
                                else if (liveConsole &&
                                    MediaQuery.orientationOf(context) ==
                                        Orientation.portrait)
                                  rotateView()
                                else
                                  basketballConsole(),
                              ],
                            ),
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
    draftDescription.dispose();
    draftStream.dispose();
    periodsInput.dispose();
    minutesInput.dispose();
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
