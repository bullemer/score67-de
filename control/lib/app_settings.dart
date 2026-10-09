import 'package:flutter/material.dart';

import 'account.dart';
import 'display_api.dart';
import 'displays.dart';

/// The app's own settings as one page (route /settings): LED panels, language,
/// defaults for new games, e-mail link. Game settings live in the console.
class AppSettingsPage extends StatefulWidget {
  final Api api;
  final String Function(String) t;
  final String lang;
  final int periods, minutes, basketballPeriods, basketballMinutes;
  final void Function(String) onLanguage;
  final Future<bool> Function(int p, int m, int bp, int bm) onDefaults;
  const AppSettingsPage({
    super.key,
    required this.api,
    required this.t,
    required this.lang,
    required this.periods,
    required this.minutes,
    required this.basketballPeriods,
    required this.basketballMinutes,
    required this.onLanguage,
    required this.onDefaults,
  });

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  late final periods = TextEditingController(text: '${widget.periods}');
  late final minutes = TextEditingController(text: '${widget.minutes}');
  late final bPeriods = TextEditingController(
    text: '${widget.basketballPeriods}',
  );
  late final bMinutes = TextEditingController(
    text: '${widget.basketballMinutes}',
  );
  bool saving = false;

  String t(String key) => widget.t(key);

  @override
  void dispose() {
    for (final c in [periods, minutes, bPeriods, bMinutes]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget card(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xff151e2a),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );

  Widget presets(
    List<List<int>> formats,
    TextEditingController count,
    TextEditingController length,
  ) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final format in formats)
        ChoiceChip(
          label: Text('${format[0]} × ${format[1]}'),
          selected:
              count.text == '${format[0]}' && length.text == '${format[1]}',
          onSelected: (_) => setState(() {
            count.text = '${format[0]}';
            length.text = '${format[1]}';
          }),
        ),
    ],
  );

  Widget field(String label, TextEditingController controller) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Future<void> save() async {
    final p = int.tryParse(periods.text),
        m = int.tryParse(minutes.text),
        bp = int.tryParse(bPeriods.text),
        bm = int.tryParse(bMinutes.text);
    bool valid(int? count, int? length) =>
        count != null &&
        count >= 1 &&
        count <= 12 &&
        length != null &&
        length >= 1 &&
        length <= 120;
    if (!valid(p, m) || !valid(bp, bm)) return;
    setState(() => saving = true);
    await widget.onDefaults(p!, m!, bp!, bm!);
    if (mounted) setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      card(t('display.title'), [
        DisplaysDialog(api: widget.api, t: widget.t, inline: true),
      ]),
      card(t('language'), [
        Wrap(
          spacing: 8,
          children: [
            for (final entry in {'de': 'Deutsch', 'en': 'English'}.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: widget.lang == entry.key,
                onSelected: (_) {
                  if (widget.lang != entry.key) widget.onLanguage(entry.key);
                },
              ),
          ],
        ),
      ]),
      card(t('app.defaults'), [
        Text(
          t('football'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        presets(
          const [
            [2, 45],
            [2, 40],
            [2, 35],
            [2, 30],
            [2, 20],
            [1, 10],
          ],
          periods,
          minutes,
        ),
        field(t('period_count'), periods),
        field(t('period_length'), minutes),
        const SizedBox(height: 12),
        Text(
          t('basketball'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        presets(
          const [
            [4, 10],
            [4, 12],
            [8, 5],
            [2, 20],
          ],
          bPeriods,
          bMinutes,
        ),
        field(t('period_count'), bPeriods),
        field(t('period_length'), bMinutes),
        const SizedBox(height: 6),
        Text(t('app.local'), style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        FilledButton(onPressed: saving ? null : save, child: Text(t('save'))),
      ]),
      card(t('owner.title'), [
        AccountPanel(
          api: widget.api,
          t: widget.t,
          language: widget.lang,
          intro: true,
        ),
      ]),
    ],
  );
}
