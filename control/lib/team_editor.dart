import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Inline roster editor for the console's Team tab: shirt number, optional
/// name and whether the player is on the court/pitch. Saving sends the squad
/// first, then the lineup; checked players appear in the left columns.
class TeamEditor extends StatefulWidget {
  final Map<String, dynamic> state;
  final String Function(String) t;
  final bool enabled;
  final Future<bool> Function(
    String team,
    List<Map<String, dynamic>> players,
    List<String> onCourt,
  )
  onSave;
  const TeamEditor({
    super.key,
    required this.state,
    required this.t,
    required this.enabled,
    required this.onSave,
  });

  @override
  State<TeamEditor> createState() => _TeamEditorState();
}

class _Row {
  final String id;
  final TextEditingController number, name;
  final FocusNode focus = FocusNode();
  final GlobalKey key = GlobalKey();
  bool onCourt;
  _Row(Map<String, dynamic> p, {this.onCourt = false})
    : id = p['id'] ?? const Uuid().v4(),
      number = TextEditingController(text: p['number'] ?? ''),
      name = TextEditingController(text: p['name'] ?? '');
  bool get blank => number.text.trim().isEmpty && name.text.trim().isEmpty;
  void dispose() {
    number.dispose();
    name.dispose();
    focus.dispose();
  }
}

class _Draft {
  final List<_Row> rows;
  bool dirty = false;
  String error = '';
  String signature;
  _Draft(this.rows, this.signature);
}

class _TeamEditorState extends State<TeamEditor> {
  String team = 'home';
  bool saving = false, pasteOpen = false;
  final drafts = <String, _Draft>{};
  final paste = TextEditingController();

  String t(String key) => widget.t(key);
  bool get basketball => widget.state['sport'] == 'basketball';
  int get limit =>
      (widget.state['lineup_size'] as int?) ?? (basketball ? 5 : 11);

  String signatureOf(String team) =>
      '${widget.state[team]['squad']}|${widget.state[team]['on_court']}';

  _Draft fresh(String team) {
    final onCourt = {
      ...(widget.state[team]['on_court'] as List? ?? []).cast<String>(),
    };
    final squad = [
      for (final p in widget.state[team]['squad'] as List? ?? [])
        Map<String, dynamic>.from(p),
    ];
    squad.sort(
      (a, b) => (int.tryParse(a['number'] ?? '') ?? 999).compareTo(
        int.tryParse(b['number'] ?? '') ?? 999,
      ),
    );
    return _Draft([
      for (final p in squad) _Row(p, onCourt: onCourt.contains(p['id'])),
      _Row({}),
    ], signatureOf(team));
  }

  /// Unsaved edits win; otherwise follow changes from other devices.
  _Draft draft(String team) {
    final current = drafts[team];
    if (current != null &&
        (current.dirty || current.signature == signatureOf(team))) {
      return current;
    }
    for (final row in current?.rows ?? <_Row>[]) {
      row.dispose();
    }
    return drafts[team] = fresh(team);
  }

  @override
  void dispose() {
    for (final d in drafts.values) {
      for (final row in d.rows) {
        row.dispose();
      }
    }
    paste.dispose();
    super.dispose();
  }

  /// Scroll the edited row to the top once the phone keyboard has opened.
  void reveal(_Row row) =>
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        final target = row.key.currentContext;
        if (target != null && target.mounted) {
          Scrollable.ensureVisible(
            target,
            alignment: 0,
            duration: const Duration(milliseconds: 150),
          );
        }
      });

  void changed(_Draft d) {
    d.dirty = true;
    d.error = '';
    // Keep one empty row at the end for fast entry.
    if (!d.rows.last.blank && d.rows.length < 40) d.rows.add(_Row({}));
    setState(() {});
  }

  void importPaste(_Draft d) {
    final numbers = d.rows
        .map((r) => int.tryParse(r.number.text.trim()))
        .whereType<int>()
        .toSet();
    final parsed = <_Row>[];
    for (final line in paste.text.split(RegExp(r'[\r\n]+'))) {
      if (line.trim().isEmpty) continue;
      final match = RegExp(
        r'^#?([0-9]{1,3})(?:[\t ,;]+(.*))?$',
      ).firstMatch(line.trim());
      if (match == null || (match.group(2) ?? '').length > 60) {
        setState(() => d.error = t('squad.paste_error'));
        return;
      }
      final number = int.parse(match.group(1)!);
      if (!numbers.add(number)) {
        setState(() => d.error = t('error.duplicate_player'));
        return;
      }
      parsed.add(
        _Row({'number': '$number', 'name': (match.group(2) ?? '').trim()}),
      );
    }
    if (parsed.isEmpty) return;
    d.rows.removeWhere((r) => r.blank);
    d.rows.addAll(parsed);
    paste.clear();
    pasteOpen = false;
    changed(d);
  }

  Future<void> save(_Draft d) async {
    final numbers = <String>{};
    final players = <Map<String, dynamic>>[];
    final onCourt = <String>[];
    for (final row in d.rows) {
      var number = row.number.text.trim();
      final name = row.name.text.trim();
      if (number.isEmpty && name.isEmpty) continue;
      String? problem;
      if (basketball && number.isEmpty) {
        problem = 'error.player_number_required';
      } else if ((number.isNotEmpty &&
              !RegExp(r'^[0-9]{1,3}$').hasMatch(number)) ||
          name.length > 60) {
        problem = 'error.invalid_squad';
      } else if (number.isNotEmpty) {
        number = int.parse(number).toString();
        if (!numbers.add(number)) problem = 'error.duplicate_player';
      }
      if (problem != null) {
        setState(() => d.error = t(problem!));
        return;
      }
      players.add({'id': row.id, 'number': number, 'name': name});
      if (row.onCourt) onCourt.add(row.id);
    }
    setState(() => saving = true);
    final ok = await widget.onSave(team, players, onCourt);
    if (!mounted) return;
    setState(() {
      saving = false;
      if (ok) {
        d.dirty = false;
        drafts.remove(team);
        for (final row in d.rows) {
          row.dispose();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = draft(team);
    final checked = d.rows.where((r) => r.onCourt && !r.blank).length;
    const dense = InputDecoration(
      isDense: true,
      counterText: '',
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Row(
            children: [
              for (final side in ['home', 'away'])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(
                      '${widget.state[side]['short']}${drafts[side]?.dirty == true ? ' •' : ''}',
                    ),
                    selected: team == side,
                    onSelected: (_) => setState(() => team = side),
                  ),
                ),
              Expanded(
                child: Text(
                  '${t('team.on_court')} $checked/$limit',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 13,
                    color: checked > limit ? Colors.orange : Colors.white70,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
                onPressed: widget.enabled && d.dirty && !saving
                    ? () => save(d)
                    : null,
                child: Text(t('save')),
              ),
            ],
          ),
        ),
        if (d.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(d.error, style: const TextStyle(color: Colors.orange)),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final row in d.rows)
                Padding(
                  key: row.key,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Tooltip(
                        message: t('team.on_court'),
                        child: Checkbox(
                          value: row.onCourt,
                          onChanged:
                              row.blank || (!row.onCourt && checked >= limit)
                              ? null
                              : (value) {
                                  row.onCourt = value ?? false;
                                  changed(d);
                                },
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: TextField(
                          controller: row.number,
                          focusNode: row.focus,
                          maxLength: 3,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          decoration: dense.copyWith(
                            hintText: t('player.number'),
                          ),
                          onChanged: (_) => changed(d),
                          onTap: () => reveal(row),
                          onSubmitted: (_) {
                            final next = d.rows.indexOf(row) + 1;
                            if (next < d.rows.length) {
                              d.rows[next].focus.requestFocus();
                              reveal(d.rows[next]);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: row.name,
                          maxLength: 60,
                          textInputAction: TextInputAction.next,
                          decoration: dense.copyWith(
                            hintText: t('player.name'),
                          ),
                          onTap: () => reveal(row),
                          onChanged: (_) => changed(d),
                        ),
                      ),
                      IconButton(
                        tooltip: t('player.remove'),
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: row.blank && row == d.rows.last
                            ? null
                            : () {
                                d.rows.remove(row);
                                if (d.rows.isEmpty) d.rows.add(_Row({}));
                                changed(d);
                              },
                      ),
                    ],
                  ),
                ),
              TextButton(
                onPressed: () => setState(() => pasteOpen = !pasteOpen),
                child: Text(t('squad.paste')),
              ),
              if (pasteOpen) ...[
                TextField(
                  controller: paste,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: '7 Alex\n12 Sam\n23',
                    border: const OutlineInputBorder(),
                  ),
                ),
                TextButton(
                  onPressed: () => importPaste(d),
                  child: Text(t('squad.import')),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
