import 'dart:async';

import 'package:flutter/material.dart';

import 'led_display.dart';

typedef Api =
    Future<dynamic> Function(
      String path,
      String method,
      Map<String, dynamic>? body,
    );

/// Global settings: connect physical displays (Anzeigetafeln, e.g. a
/// Raspberry Pi driving an LED board) and choose which scoreboard each shows.
class DisplaysDialog extends StatefulWidget {
  final Api api;
  final String Function(String) t;
  const DisplaysDialog({super.key, required this.api, required this.t});

  @override
  State<DisplaysDialog> createState() => _DisplaysDialogState();
}

class _DisplaysDialogState extends State<DisplaysDialog> {
  List<Map<String, dynamic>> displays = [];
  List<Map<String, dynamic>> boards = [];
  bool loading = true, busy = false;
  String error = '';
  Timer? timer;
  final name = TextEditingController(text: 'Anzeigetafel');

  String t(String key) => widget.t(key);

  @override
  void initState() {
    super.initState();
    load();
    // Status and pairing progress refresh while the dialog is open.
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    name.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final result = await widget.api('/api/displays', 'GET', null);
      final dashboard = await widget.api('/api/dashboard', 'GET', null);
      if (!mounted) return;
      setState(() {
        displays = [
          for (final d in result['displays']) Map<String, dynamic>.from(d),
        ];
        boards = [
          for (final b in dashboard['boards']) Map<String, dynamic>.from(b),
        ];
        loading = false;
        error = '';
      });
    } catch (_) {
      if (mounted) setState(() => error = t('error.network'));
    }
  }

  Future<void> run(Future<dynamic> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await load();
    } catch (_) {
      if (mounted) setState(() => error = t('error.generic'));
    }
    if (mounted) setState(() => busy = false);
  }

  String boardLabel(Map<String, dynamic> board) {
    final description = (board['description'] ?? '') as String;
    final active = (board['matches'] as List? ?? [])
        .where((m) => m['active'] == true)
        .firstOrNull;
    final teams = active == null
        ? ''
        : '${active['home']['name']} – ${active['away']['name']}';
    return [
      if (description.isNotEmpty) description,
      if (teams.isNotEmpty) teams,
      if (description.isEmpty && teams.isEmpty) board['slug'],
    ].join(' · ');
  }

  String clock(int milliseconds) {
    final time = TimeOfDay.fromDateTime(
      DateTime.fromMillisecondsSinceEpoch(milliseconds),
    );
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(time, alwaysUse24HourFormat: true);
  }

  Widget status(Map<String, dynamic> d) {
    final (label, color) = d['code'] != null && d['paired'] != true
        ? (t('display.waiting'), Colors.orange)
        : d['online'] == true
        ? (t('display.online'), const Color(0xff22c55e))
        : (t('display.offline'), Colors.grey);
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Future<void> rename(Map<String, dynamic> d) async {
    final input = TextEditingController(text: d['name']);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        alignment: Alignment.topCenter,
        title: Text(t('display.rename')),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 60,
          onSubmitted: (text) => Navigator.pop(context, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: Text(t('save')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value == null || value.trim().isEmpty) return;
    await run(
      () =>
          widget.api('/api/displays/${d['id']}', 'PUT', {'name': value.trim()}),
    );
  }

  Widget card(Map<String, dynamic> d) {
    final known = boards.any((b) => b['slug'] == d['board']);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xff344154)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.scoreboard_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: busy ? null : () => rename(d),
                  child: Text(
                    d['name'],
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              status(d),
            ],
          ),
          if (d['code'] != null) ...[
            const SizedBox(height: 8),
            Text(t('display.code_hint'), style: const TextStyle(fontSize: 13)),
            SelectableText(
              d['code'],
              style: const TextStyle(
                fontSize: 30,
                letterSpacing: 6,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              '${t('display.code_valid')} ${clock(d['code_expires_at'])}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            key: ValueKey('board:${d['id']}:${d['board']}:${boards.length}'),
            initialValue: known ? d['board'] : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: t('display.shows'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(t('display.nothing')),
              ),
              for (final b in boards)
                DropdownMenuItem<String?>(
                  value: b['slug'],
                  child: Text(boardLabel(b), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: busy
                ? null
                : (slug) => run(
                    () => widget.api('/api/displays/${d['id']}', 'PUT', {
                      'board': slug,
                    }),
                  ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => run(
                        () => widget.api(
                          '/api/displays/${d['id']}/code',
                          'POST',
                          {},
                        ),
                      ),
                icon: const Icon(Icons.qr_code_2),
                label: Text(t('display.new_code')),
              ),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            content: Text(t('display.remove_confirm')),
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
                        );
                        if (ok == true) {
                          await run(
                            () => widget.api(
                              '/api/displays/${d['id']}',
                              'DELETE',
                              {},
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.link_off),
                label: Text(t('display.remove')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    alignment: Alignment.topCenter,
    insetPadding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    title: Text(t('display.title')),
    content: SizedBox(
      width: 520,
      child: loading
          ? const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            )
          : ListView(
              shrinkWrap: true,
              children: [
                Text(t('display.intro'), style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 12),
                if (error.isNotEmpty)
                  Text(error, style: const TextStyle(color: Colors.orange)),
                for (final d in displays) card(d),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: name,
                        maxLength: 60,
                        decoration: InputDecoration(
                          labelText: t('display.name'),
                          counterText: '',
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: busy || name.text.trim().isEmpty
                          ? null
                          : () => run(
                              () => widget.api('/api/displays', 'POST', {
                                'name': name.text.trim(),
                              }),
                            ),
                      icon: const Icon(Icons.add_link),
                      label: Text(t('display.connect')),
                    ),
                  ],
                ),
                const Divider(height: 32),
                BleDisplaysSection(t: widget.t),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('close')),
      ),
    ],
  );
}
