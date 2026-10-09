import 'dart:async';

import 'package:flutter/material.dart';

import 'display_api.dart';
import 'display_disconnect.dart';

/// Connect an LED panel to this game by its displayed code, or switch an
/// already managed panel between this game and its idle code screen.
class BoardDisplaysPanel extends StatefulWidget {
  final Api api;
  final String Function(String) t;
  final String slug;
  final bool enabled;
  final VoidCallback onSettings;
  const BoardDisplaysPanel({
    super.key,
    required this.api,
    required this.t,
    required this.slug,
    required this.enabled,
    required this.onSettings,
  });

  @override
  State<BoardDisplaysPanel> createState() => _BoardDisplaysPanelState();
}

class _BoardDisplaysPanelState extends State<BoardDisplaysPanel> {
  List<Map<String, dynamic>> displays = [];
  bool busy = false, loaded = false;
  String error = '';
  Timer? timer;
  final code = TextEditingController();

  String t(String key) => widget.t(key);
  String get base => '/api/s/${widget.slug}/displays';

  @override
  void initState() {
    super.initState();
    load();
    // Online status follows the panel while the tab is open.
    timer = Timer.periodic(const Duration(seconds: 10), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    code.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(BoardDisplaysPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slug != widget.slug) {
      displays = [];
      loaded = false;
      load();
    }
  }

  Future<void> load() async {
    try {
      final result = await widget.api(base, 'GET', null);
      if (!mounted) return;
      setState(() {
        displays = [
          for (final d in result['displays']) Map<String, dynamic>.from(d),
        ];
        loaded = true;
      });
    } catch (_) {
      // Viewers (no controller access) simply see no panels.
    }
  }

  Future<void> run(
    Future<dynamic> Function() action, {
    String? errorKey,
  }) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
      await load();
    } catch (_) {
      if (mounted) setState(() => error = t(errorKey ?? 'error.generic'));
      await load();
    }
    if (mounted) setState(() => busy = false);
  }

  /// Disconnect requires confirmation and an atomic server connection check.
  Future<void> show(Map<String, dynamic> d, bool on) => run(
    () => on
        ? widget.api('$base/${d['id']}', 'PUT', {})
        : disconnectDisplay(context, widget.api, t, d),
    errorKey: on ? 'error.generic' : 'error.display_connection_changed',
  );

  Future<void> connect() async {
    if (code.text.trim().length < 6) {
      setState(() => error = t('display.claim_invalid'));
      return;
    }
    await run(() async {
      await widget.api(base, 'POST', {'code': code.text.trim()});
      code.clear();
    }, errorKey: 'display.claim_invalid');
  }

  @override
  Widget build(BuildContext context) {
    final can = widget.enabled && !busy;
    final mine = displays.where((d) => d['managed'] == true).toList();
    final others = displays
        .where((d) => d['managed'] != true && d['board'] == widget.slug)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('ledlink.title'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(t('ledlink.connect_hint'), style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: code,
                maxLength: 6,
                keyboardType: TextInputType.number,
                onSubmitted: can ? (_) => connect() : null,
                decoration: InputDecoration(
                  labelText: t('display.claim_label'),
                  counterText: '',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: can ? connect : null,
              child: Text(t('ledlink.connect')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (loaded && mine.isEmpty) ...[
          Text(t('ledlink.none'), style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: widget.onSettings,
              icon: const Icon(Icons.settings_outlined),
              label: Text(t('app.settings')),
            ),
          ),
        ],
        for (final d in mine)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: dot(d),
            title: Text(
              t('ledlink.show_on').replaceAll('{name}', d['name'] ?? ''),
            ),
            subtitle: Text(
              d['board'] == widget.slug
                  ? t('ledlink.shows_this')
                  : d['board'] == null
                  ? t('ledlink.shows_nothing')
                  : t('ledlink.shows_other'),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: TextButton.icon(
              onPressed: can ? () => show(d, d['board'] != widget.slug) : null,
              icon: Icon(
                d['board'] == widget.slug ? Icons.link_off : Icons.link,
              ),
              label: Text(
                t(
                  d['board'] == widget.slug
                      ? 'ledlink.disconnect'
                      : 'ledlink.connect',
                ),
              ),
            ),
          ),
        // Someone else's panel showing this game (connected with the code).
        for (final d in others)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: dot(d),
            title: Text(d['name'] ?? ''),
            subtitle: Text(t('ledlink.shows_this')),
            trailing: TextButton(
              onPressed: can ? () => show(d, false) : null,
              child: Text(t('ledlink.disconnect')),
            ),
          ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
      ],
    );
  }

  Widget dot(Map<String, dynamic> d) => Icon(
    Icons.circle,
    size: 12,
    color: d['online'] == true ? const Color(0xff22c55e) : Colors.grey,
  );
}
