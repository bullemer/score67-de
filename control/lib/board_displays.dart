import 'dart:async';

import 'package:flutter/material.dart';

import 'displays.dart' show Api;

/// Sharing tab: a switch per connected LED panel, "show on this panel".
/// Setting a panel up (its code, name, follow option) happens in Settings.
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
    super.dispose();
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

  Future<void> run(Future<dynamic> Function() action) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
      await load();
    } catch (_) {
      if (mounted) setState(() => error = t('error.generic'));
    }
    if (mounted) setState(() => busy = false);
  }

  /// On: this game runs on the panel. Off: the panel shows its code again.
  Future<void> show(Map<String, dynamic> d, bool on) => run(
    () => on
        ? widget.api('$base/${d['id']}', 'PUT', {})
        : widget.api('$base/${d['id']}', 'DELETE', null),
  );

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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: dot(d),
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
            value: d['board'] == widget.slug,
            onChanged: can ? (on) => show(d, on) : null,
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
