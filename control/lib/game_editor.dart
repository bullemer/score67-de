import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

typedef Api =
    Future<dynamic> Function(
      String path,
      String method,
      Map<String, dynamic>? body,
    );

/// "Bearbeiten" in My scoreboards: description, livestream link, team names
/// and optional team logos of one game.
class GameEditorDialog extends StatefulWidget {
  final Api api;
  final String Function(String) t;
  final Map<String, dynamic> board, game;

  /// Browser image picker (see logo_picker.dart); injected so this file
  /// stays testable outside the browser.
  final Future<String?> Function() pickLogo;
  const GameEditorDialog({
    required this.pickLogo,
    super.key,
    required this.api,
    required this.t,
    required this.board,
    required this.game,
  });

  @override
  State<GameEditorDialog> createState() => _GameEditorDialogState();
}

class _GameEditorDialogState extends State<GameEditorDialog> {
  late final description = TextEditingController(
    text: widget.board['description'] ?? '',
  );
  late final stream = TextEditingController(
    text: widget.board['stream_url'] ?? '',
  );
  late final names = {
    for (final team in ['home', 'away'])
      team: TextEditingController(text: widget.game[team]['name']),
  };
  late final logos = <String, String?>{
    for (final team in ['home', 'away']) team: widget.game[team]['logo'],
  };
  bool busy = false;
  String error = '';

  String t(String key) => widget.t(key);
  String get slug => widget.board['slug'];
  String get match => widget.game['match_id'];

  @override
  void dispose() {
    description.dispose();
    stream.dispose();
    for (final c in names.values) {
      c.dispose();
    }
    super.dispose();
  }

  String message(Object e) {
    final code = '$e'.startsWith('ApiError:') ? '$e'.substring(9) : 'network';
    return t('error.$code');
  }

  Future<void> logo(String team, {bool remove = false}) async {
    final data = remove ? null : await widget.pickLogo();
    if (!remove && data == null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.api(
        '/api/s/$slug/matches/$match/logo',
        'POST',
        {'team': team, 'data': data},
      );
      logos[team] = result[team]['logo'];
    } catch (e) {
      error = message(e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final text = description.text.trim(), link = stream.text.trim();
      await widget.api('/api/s/$slug/description', 'PUT', {
        'description': text.isEmpty ? null : text,
      });
      await widget.api('/api/s/$slug/stream', 'PUT', {
        'stream_url': link.isEmpty ? null : link,
      });
      final changed = {
        for (final team in ['home', 'away'])
          if (names[team]!.text.trim().isNotEmpty &&
              names[team]!.text.trim() != widget.game[team]['name'])
            team: {'name': names[team]!.text.trim()},
      };
      if (changed.isNotEmpty) {
        // Logo uploads change the revision, so read the current one first.
        final current = await widget.api(
          '/api/s/$slug/matches/$match/control-state',
          'GET',
          null,
        );
        await widget.api('/api/s/$slug/matches/$match/commands', 'POST', {
          'command_id': const Uuid().v4(),
          'expected_revision': current['revision'],
          'action': 'settings',
          'data': changed,
        });
      }
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      error = message(e);
    }
    if (mounted) setState(() => busy = false);
  }

  Widget teamRow(String team) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xff0b1018),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xff344154)),
          ),
          child: logos[team] == null
              ? const Icon(Icons.shield_outlined, color: Colors.white38)
              : Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.network(logos[team]!, fit: BoxFit.contain),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: names[team],
            maxLength: 60,
            decoration: InputDecoration(
              labelText: t(team),
              counterText: '',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        IconButton(
          tooltip: t('logo.choose'),
          onPressed: busy ? null : () => logo(team),
          icon: const Icon(Icons.add_photo_alternate_outlined),
        ),
        if (logos[team] != null)
          IconButton(
            tooltip: t('logo.remove'),
            onPressed: busy ? null : () => logo(team, remove: true),
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    alignment: Alignment.topCenter,
    insetPadding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    title: Text(t('game.edit')),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('logo.hint'), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            teamRow('home'),
            teamRow('away'),
            TextField(
              controller: description,
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: t('description'),
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
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: const TextStyle(color: Colors.orange),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: Text(t('cancel')),
      ),
      FilledButton(onPressed: busy ? null : save, child: Text(t('save'))),
    ],
  );
}
