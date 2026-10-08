import 'dart:async';

import 'package:flutter/material.dart';

import 'displays.dart' show Api;

/// Sharing tab: connect a Score67 LED panel to this game with the code shown
/// on the panel, see which panels show the game, switch or disconnect them.
class BoardDisplaysPanel extends StatefulWidget {
  final Api api;
  final String Function(String) t;
  final String slug;
  final bool enabled;
  const BoardDisplaysPanel({
    super.key,
    required this.api,
    required this.t,
    required this.slug,
    required this.enabled,
  });

  @override
  State<BoardDisplaysPanel> createState() => _BoardDisplaysPanelState();
}

class _BoardDisplaysPanelState extends State<BoardDisplaysPanel> {
  List<Map<String, dynamic>> displays = [];
  final code = TextEditingController();
  bool busy = false;
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
    code.dispose();
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
      });
    } catch (_) {
      // Viewers (no controller access) simply see no panels.
    }
  }

  Future<void> run(Future<dynamic> Function() action, String failure) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
      await load();
    } catch (_) {
      if (mounted) setState(() => error = t(failure));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> connect() async {
    final value = code.text.trim();
    if (value.length < 6) return;
    await run(() async {
      await widget.api(base, 'POST', {'code': value});
      code.clear();
    }, 'display.claim_invalid');
  }

  @override
  Widget build(BuildContext context) {
    final can = widget.enabled && !busy;
    final here = displays.where((d) => d['board'] == widget.slug).toList();
    final other = displays.where((d) => d['board'] != widget.slug).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('ledlink.title'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(t('ledlink.hint'), style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: code,
                enabled: can,
                keyboardType: TextInputType.number,
                maxLength: 6,
                onSubmitted: (_) => connect(),
                decoration: InputDecoration(
                  labelText: t('display.claim_label'),
                  counterText: '',
                ),
                style: const TextStyle(letterSpacing: 4, fontSize: 18),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: can ? connect : null,
              icon: const Icon(Icons.link),
              label: Text(t('ledlink.connect')),
            ),
          ],
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
        for (final d in here)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: dot(d),
            title: Text(d['name'] ?? ''),
            subtitle: Text(t('ledlink.shows_this')),
            trailing: TextButton(
              onPressed: can
                  ? () => run(
                      () => widget.api('$base/${d['id']}', 'DELETE', null),
                      'error.generic',
                    )
                  : null,
              child: Text(t('ledlink.disconnect')),
            ),
          ),
        for (final d in other)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: dot(d),
            title: Text(d['name'] ?? ''),
            subtitle: Text(
              t(
                d['board'] == null
                    ? 'ledlink.shows_nothing'
                    : 'ledlink.shows_other',
              ),
            ),
            trailing: TextButton(
              onPressed: can
                  ? () => run(
                      () => widget.api('$base/${d['id']}', 'PUT', {}),
                      'error.generic',
                    )
                  : null,
              child: Text(t('ledlink.show_here')),
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
