import 'dart:async';

import 'package:flutter/material.dart';

import 'display_api.dart';

/// LED tab: greetings, cheers and small charts that interrupt the score on
/// the LED panels showing this game for a few seconds (led_messages.py).
class LedMessagePanel extends StatefulWidget {
  final Api api;
  final String Function(String) t;
  final String slug, homeShort, awayShort;
  final bool enabled;
  const LedMessagePanel({
    super.key,
    required this.api,
    required this.t,
    required this.slug,
    required this.homeShort,
    required this.awayShort,
    required this.enabled,
  });

  @override
  State<LedMessagePanel> createState() => _LedMessagePanelState();
}

const _icons = {
  'heart': Icons.favorite,
  'star': Icons.star,
  'basketball': Icons.sports_basketball,
  'football': Icons.sports_soccer,
  'trophy': Icons.emoji_events,
  'flame': Icons.local_fire_department,
};
const _colors = [
  '#ffa31a',
  '#ffffff',
  '#ef4444',
  '#22c55e',
  '#3b82f6',
  '#facc15',
];

Color _color(String hex) =>
    Color(int.parse('ff${hex.substring(1)}', radix: 16));

class _LedMessagePanelState extends State<LedMessagePanel> {
  final text = TextEditingController();
  String? icon;
  String color = _colors.first, effect = 'static';
  int seconds = 8;
  bool busy = false;
  String error = '';

  /// When the message on the panels ends (for the countdown and Stop).
  DateTime? until;
  Timer? ticker;

  String t(String key) => widget.t(key);

  @override
  void dispose() {
    ticker?.cancel();
    text.dispose();
    super.dispose();
  }

  Future<void> send(Map<String, dynamic> body) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.api(
        '/api/s/${widget.slug}/led/message',
        'POST',
        {'seconds': seconds, ...body},
      );
      until = DateTime.now().add(Duration(milliseconds: result['ms'] as int));
      ticker?.cancel();
      ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        if (until == null || DateTime.now().isAfter(until!)) {
          timer.cancel();
          until = null;
        }
        setState(() {});
      });
    } catch (_) {
      error = t('ledmsg.failed');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> stop() async {
    try {
      await widget.api('/api/s/${widget.slug}/led/message', 'DELETE', null);
    } catch (_) {}
    ticker?.cancel();
    if (mounted) setState(() => until = null);
  }

  void sendText(String value, {String? withIcon}) => send({
    'kind': 'text',
    'text': value,
    'icon': withIcon,
    'color': color,
    'effect': effect,
  });

  Widget chips<T>(
    List<T> values,
    T selected,
    Widget Function(T) label,
    void Function(T) pick,
  ) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final v in values)
        ChoiceChip(
          label: label(v),
          selected: v == selected,
          onSelected: (_) => setState(() => pick(v)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final can = widget.enabled && !busy;
    final left = until?.difference(DateTime.now()).inSeconds;
    final presets = [
      (t('ledmsg.preset.welcome'), null),
      (t('ledmsg.preset.go').replaceAll('{team}', widget.homeShort), 'flame'),
      (t('ledmsg.preset.go').replaceAll('{team}', widget.awayShort), 'flame'),
      ('DEFENSE!', null),
      (t('ledmsg.preset.thanks'), 'heart'),
      (t('ledmsg.preset.timeout'), null),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t('ledmsg.hint'), style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        // Always the same height: buttons must not move while tapping fast.
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  left != null && left >= 0
                      ? t('ledmsg.showing').replaceAll('{s}', '${left + 1}')
                      : '',
                  style: const TextStyle(color: Color(0xffb6f36e)),
                ),
              ),
              OutlinedButton.icon(
                onPressed: left != null && left >= 0 ? stop : null,
                icon: const Icon(Icons.stop),
                label: Text(t('ledmsg.stop')),
              ),
            ],
          ),
        ),
        // One tap sends: the usual cheers and the two charts.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: can ? () => send({'kind': 'polonia'}) : null,
              icon: Image.asset('assets/polonia.png', width: 30, height: 30),
              label: const Text('Polonia'),
            ),
            FilledButton.tonalIcon(
              onPressed: can ? () => send({'kind': 'bram'}) : null,
              icon: Image.asset('assets/bramfelder.png', width: 30, height: 30),
              label: const Text('Bramfelder SV'),
            ),
            for (final (label, presetIcon) in presets)
              FilledButton.tonal(
                onPressed: can && label.trim().isNotEmpty
                    ? () => sendText(label, withIcon: presetIcon)
                    : null,
                child: Text(label),
              ),
            FilledButton.tonalIcon(
              onPressed: can ? () => send({'kind': 'periods'}) : null,
              icon: const Icon(Icons.bar_chart),
              label: Text(t('ledmsg.periods')),
            ),
            FilledButton.tonalIcon(
              onPressed: can ? () => send({'kind': 'lead'}) : null,
              icon: const Icon(Icons.show_chart),
              label: Text(t('ledmsg.lead')),
            ),
          ],
        ),
        const Divider(height: 24),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: text,
                maxLength: 60,
                textCapitalization: TextCapitalization.characters,
                onSubmitted: (_) => sendText(text.text, withIcon: icon),
                decoration: InputDecoration(
                  labelText: t('ledmsg.own'),
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: can ? () => sendText(text.text, withIcon: icon) : null,
              icon: const Icon(Icons.send),
              label: Text(t('ledmsg.send')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        chips<String?>(
          [null, ..._icons.keys],
          icon,
          (v) =>
              v == null ? Text(t('ledmsg.no_icon')) : Icon(_icons[v], size: 18),
          (v) => icon = v,
        ),
        const SizedBox(height: 6),
        chips<String>(
          _colors,
          color,
          (v) => Icon(Icons.circle, size: 18, color: _color(v)),
          (v) => color = v,
        ),
        const SizedBox(height: 6),
        chips<String>(
          const ['static', 'blink', 'rainbow'],
          effect,
          (v) => Text(t('ledmsg.effect.$v')),
          (v) => effect = v,
        ),
        const SizedBox(height: 6),
        chips<int>(
          const [5, 8, 15, 30],
          seconds,
          (v) => Text('$v s'),
          (v) => seconds = v,
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error,
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
        const SizedBox(height: 8),
        Text(t('ledmsg.preview_note'), style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
