import 'package:flutter/material.dart';

typedef FixtureApi =
    Future<dynamic> Function(
      String path,
      String method,
      Map<String, dynamic>? body,
    );

/// Optional first step when preparing a game: paste the link of the game page
/// on fussball.de or basketball-bund.net and take over teams, kickoff, venue,
/// league and game number (POST /api/fixtures/lookup).
class FixtureImport extends StatefulWidget {
  final FixtureApi api;
  final String Function(String) t;
  final void Function(Map<String, dynamic>) onLoaded;
  final bool enabled;
  const FixtureImport({
    super.key,
    required this.api,
    required this.t,
    required this.onLoaded,
    this.enabled = true,
  });

  @override
  State<FixtureImport> createState() => _FixtureImportState();
}

class _FixtureImportState extends State<FixtureImport> {
  final link = TextEditingController();
  Map<String, dynamic>? loaded;
  bool busy = false;
  String error = '';

  String t(String key) => widget.t(key);

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final url = link.text.trim();
    if (url.isEmpty || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = Map<String, dynamic>.from(
        await widget.api('/api/fixtures/lookup', 'POST', {'url': url}),
      );
      loaded = result;
      widget.onLoaded(result);
    } catch (e) {
      final code = e.toString();
      error = t(
        code.contains('fixture_url')
            ? 'fixture.error.url'
            : code.contains('fixture_not_found')
            ? 'fixture.error.not_found'
            : code.contains('rate_limited')
            ? 'fixture.error.rate_limited'
            : 'fixture.error.unavailable',
      );
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final f = loaded;
    final kickoff = f?['kickoff'] as int?;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('fixture.title'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              t('fixture.hint'),
              style: const TextStyle(fontSize: 14, color: Color(0xffb5c2d4)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: link,
              enabled: widget.enabled && !busy,
              keyboardType: TextInputType.url,
              onSubmitted: (_) => load(),
              decoration: InputDecoration(
                labelText: t('fixture.link'),
                hintText: 'https://www.fussball.de/spiel/…',
                border: const OutlineInputBorder(),
                suffixIcon: busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: t('fixture.load'),
                        icon: const Icon(Icons.download),
                        onPressed: widget.enabled ? load : null,
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: widget.enabled && !busy ? load : null,
                child: Text(t('fixture.load')),
              ),
            ),
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: Colors.orange)),
            if (f != null) ...[
              const SizedBox(height: 8),
              Text(
                '✓ ${f['home']['name']} – ${f['away']['name']}',
                style: const TextStyle(color: Color(0xffb6f36e)),
              ),
              FixtureFacts(fixture: f, t: t, link: false, date: true),
              if (f['cancelled'] == true)
                Text(
                  t('fixture.cancelled'),
                  style: const TextStyle(color: Colors.orange),
                ),
              if (kickoff == null)
                Text(
                  t('fixture.no_time'),
                  style: const TextStyle(color: Colors.orange),
                )
              else if (kickoff <= DateTime.now().millisecondsSinceEpoch)
                Text(
                  t('fixture.past'),
                  style: const TextStyle(color: Colors.orange),
                ),
              Text(
                t('fixture.check'),
                style: const TextStyle(fontSize: 13, color: Color(0xff8d9bb0)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// League, game number, kickoff and venue of an imported game, plus a link
/// back to the source page (controller and My scoreboards). [open] opens the
/// link in a new tab (injected: this file stays testable outside the browser).
class FixtureFacts extends StatelessWidget {
  final Map fixture;
  final String Function(String) t;
  final bool link, date;
  final void Function(String)? open;
  final double fontSize;
  const FixtureFacts({
    super.key,
    required this.fixture,
    required this.t,
    this.link = true,
    this.date = false,
    this.open,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final f = fixture;
    String text(String key) => (f[key] ?? '').toString();
    final venue = (f['venue'] ?? {}) as Map;
    final league = [
      text('league'),
      text('matchday'),
    ].where((x) => x.isNotEmpty).join(' · ');
    final lines = [
      if (league.isNotEmpty) league,
      if (text('group').isNotEmpty && !league.contains(text('group')))
        text('group'),
      if (text('game_number').isNotEmpty)
        '${t('fixture.number')} ${text('game_number')}',
      if (date && text('date').isNotEmpty)
        '${text('date')} ${text('time')}'.trim(),
      if ((venue['address'] ?? '').toString().isNotEmpty)
        '📍 ${venue['address']}',
    ];
    final style = TextStyle(fontSize: fontSize, color: const Color(0xffb5c2d4));
    final url = text('url');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines) Text(line, style: style),
        if (link && open != null && url.startsWith('https://'))
          InkWell(
            onTap: () => open!(url),
            child: Text(
              '↗ ${text('source')}',
              style: TextStyle(
                fontSize: fontSize,
                color: const Color(0xff7cc4ff),
                decoration: TextDecoration.underline,
              ),
            ),
          ),
      ],
    );
  }
}
