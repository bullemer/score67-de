import 'dart:async';

import 'package:flutter/material.dart';

import 'display_api.dart';
import 'display_disconnect.dart';
import 'led_display.dart';

/// Manage physical LED displays and choose which scoreboard each shows.
class DisplaysDialog extends StatefulWidget {
  final Api api;
  final String Function(String) t;

  /// Shown as a section of the console's Settings tab instead of a dialog.
  final bool inline;
  const DisplaysDialog({
    super.key,
    required this.api,
    required this.t,
    this.inline = false,
  });

  @override
  State<DisplaysDialog> createState() => _DisplaysDialogState();
}

class _DisplaysDialogState extends State<DisplaysDialog> {
  List<Map<String, dynamic>> displays = [];
  List<Map<String, dynamic>> boards = [];
  bool loading = true, busy = false;
  String error = '';
  Timer? timer;

  /// The code a Score67 LED panel shows until it is added here.
  final claim = TextEditingController();

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
    claim.dispose();
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

  /// Adds a self-registered LED panel by the code on its display.
  Future<void> claimPanel() async {
    final code = claim.text.trim();
    if (code.length < 6) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.api('/api/displays/claim', 'POST', {'code': code});
      claim.clear();
      await load();
    } catch (_) {
      if (mounted) setState(() => error = t('display.claim_invalid'));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> run(
    Future<dynamic> Function() action, {
    String errorKey = 'error.generic',
  }) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
      await load();
    } catch (_) {
      await load();
      if (mounted) setState(() => error = t(errorKey));
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
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final current = boards
                  .where((b) => b['slug'] == d['board'])
                  .firstOrNull;
              final board = d['board'] as String?;
              return DropdownButton<String>(
                key: ValueKey('${d['id']}:$board'),
                value: board,
                isExpanded: true,
                hint: Text(t('display.shows')),
                items: [
                  DropdownMenuItem<String>(
                    value: null,
                    child: Text(t('display.nothing')),
                  ),
                  if (board != null && current == null)
                    DropdownMenuItem<String>(
                      value: board,
                      child: Text(d['board_description'] ?? board),
                    ),
                  for (final b in boards)
                    DropdownMenuItem<String>(
                      value: b['slug'] as String,
                      child: Text(boardLabel(b)),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (selected) => run(
                        () => selected == null
                            ? disconnectDisplay(context, widget.api, t, d)
                            : widget.api('/api/displays/${d['id']}', 'PUT', {
                                'board': selected,
                              }),
                        errorKey: selected == null
                            ? 'error.display_connection_changed'
                            : 'error.generic',
                      ),
              );
            },
          ),
          if (d['board'] != null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => run(
                        () => disconnectDisplay(context, widget.api, t, d),
                        errorKey: 'error.display_connection_changed',
                      ),
                icon: const Icon(Icons.link_off),
                label: Text(t('ledlink.disconnect')),
              ),
            ),
          if (d['device'] == true) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(t('display.brightness')),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final level in const [20, 40, 60, 80, 100])
                        ChoiceChip(
                          label: Text('$level %'),
                          selected: d['brightness'] == level,
                          onSelected: busy
                              ? null
                              : (_) => run(
                                  () => widget.api(
                                    '/api/displays/${d['id']}',
                                    'PUT',
                                    {'brightness': level},
                                  ),
                                ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Text(
              [
                if (d['fw_version'] != null)
                  '${t('display.fw')} ${d['fw_version']}',
                if (d['rssi'] != null)
                  '${t('display.signal')} ${d['rssi']} dBm',
              ].join(' · '),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            // Over-the-air updates: installed by the panel when no game runs.
            if (d['update'] != null)
              Text(
                t('display.update').replaceAll('{version}', '${d['update']}'),
                style: const TextStyle(fontSize: 12, color: Color(0xfffbbf24)),
              ),
            if (d['ota_status'] != null)
              Text(
                '${t('display.ota_status')}: ${d['ota_status']}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t('display.follow')),
              subtitle: Text(t('display.follow_note')),
              value: d['follow'] == true,
              onChanged: busy
                  ? null
                  : (on) => run(
                      () => widget.api('/api/displays/${d['id']}', 'PUT', {
                        'follow': on,
                      }),
                    ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t('display.beta')),
              subtitle: Text(t('display.beta_note')),
              value: d['beta'] == true,
              onChanged: busy
                  ? null
                  : (on) => run(
                      () => widget.api('/api/displays/${d['id']}', 'PUT', {
                        'beta': on,
                      }),
                    ),
            ),
          ],
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => run(
                        () => widget.api(
                          '/api/displays/${d['id']}/identify',
                          'POST',
                          {},
                        ),
                      ),
                icon: const Icon(Icons.flare),
                label: Text(t('display.identify')),
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

  List<Widget> body() => [
    Text(t('display.intro'), style: const TextStyle(fontSize: 14)),
    const SizedBox(height: 12),
    if (error.isNotEmpty)
      Text(error, style: const TextStyle(color: Colors.orange)),
    for (final d in displays) card(d),
    // A Score67 LED panel shows its own code: add it here.
    Text(t('display.claim_hint'), style: const TextStyle(fontSize: 14)),
    const SizedBox(height: 6),
    Row(
      children: [
        Expanded(
          child: TextField(
            controller: claim,
            maxLength: 7,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => claimPanel(),
            decoration: InputDecoration(
              labelText: t('display.claim_label'),
              counterText: '',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: busy ? null : claimPanel,
          icon: const Icon(Icons.add),
          label: Text(t('display.claim')),
        ),
      ],
    ),
    const Divider(height: 32),
    // A different kind of panel (Bluetooth signs driven by this phone);
    // folded away so it is not mistaken for the Score67 panels above.
    ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(t('ble.title'), style: const TextStyle(fontSize: 15)),
      subtitle: Text(t('ble.other_kind'), style: const TextStyle(fontSize: 12)),
      children: [BleDisplaysSection(t: widget.t)],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (widget.inline) {
      return loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: body(),
            );
    }
    return AlertDialog(
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
            : ListView(shrinkWrap: true, children: body()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('close')),
        ),
      ],
    );
  }
}
