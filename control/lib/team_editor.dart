import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Inline roster editor for the console's Team tab: shirt number, optional
/// name and whether the player is on the court/pitch. Entries save themselves
/// shortly after typing (squad first, then the lineup), a shirt number can only
/// exist once per team, and rows are ordered by number when a row is left.
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

  /// Saved teams; left out where they do not apply (tennis, tests).
  final Future<dynamic> Function(String, String, Map<String, dynamic>?)? api;
  final Future<bool> Function(String team, Map<String, dynamic> saved)? onApply;

  /// Opens the upright full-page editor (from the landscape console).
  final VoidCallback? onPortrait;

  /// Lets the app save what was typed before the page itself goes away.
  final TeamEditorFlush? flush;
  const TeamEditor({
    super.key,
    required this.state,
    required this.t,
    required this.enabled,
    required this.onSave,
    this.api,
    this.onApply,
    this.onPortrait,
    this.flush,
  });

  @override
  State<TeamEditor> createState() => _TeamEditorState();
}

/// Open editors register here; leaving the page (a link, a reload, the phone
/// closing the tab) hands their unsaved players to the app first.
class TeamEditorFlush {
  final _editors = <VoidCallback>{};
  void call() {
    for (final editor in _editors.toList()) {
      editor();
    }
  }
}

class _Row {
  final String id;
  final TextEditingController number, name;
  final FocusNode focus = FocusNode();
  final GlobalKey key = GlobalKey();

  /// Next on the phone keyboard moves between text fields only: landing on
  /// the remove button closed the keyboard and lost the typed number.
  final FocusNode tickFocus = FocusNode(skipTraversal: true);
  final FocusNode removeFocus = FocusNode(skipTraversal: true);
  bool onCourt;

  /// Focus is somewhere in this row.
  bool active = false;

  /// What the server has for this row; a refused duplicate falls back to it.
  bool saved;
  String savedNumber;

  /// When the number was last typed: among equal numbers the oldest stays.
  int edited = 0;
  _Row(Map<String, dynamic> p, {this.onCourt = false})
    : id = p['id'] ?? const Uuid().v4(),
      number = TextEditingController(text: p['number'] ?? ''),
      name = TextEditingController(text: p['name'] ?? ''),
      saved = p['id'] != null,
      savedNumber = p['number'] ?? '';
  bool get blank => number.text.trim().isEmpty && name.text.trim().isEmpty;
  String get normalized {
    final value = int.tryParse(number.text.trim());
    return value == null ? '' : '$value';
  }

  void dispose() {
    number.dispose();
    name.dispose();
    focus.dispose();
    tickFocus.dispose();
    removeFocus.dispose();
  }
}

class _Draft {
  final String team;
  final List<_Row> rows;
  bool dirty = false;
  int version = 0;
  String error = '';
  String signature;
  _Draft(this.team, this.rows, this.signature);
}

class _TeamEditorState extends State<TeamEditor> {
  String team = 'home';
  bool saving = false, pasteOpen = false;
  final drafts = <String, _Draft>{};
  // One timer per team: both squads can be waiting to be saved.
  final autosaves = <String, Timer>{};
  List<Timer> revealTimers = [];
  int editClock = 0;
  final paste = TextEditingController();
  final teamName = TextEditingController();
  String teamsMode = '', teamsNote = '';
  List<dynamic> savedTeams = [];

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
    return _Draft(team, [
      for (final p in squad) _Row(p, onCourt: onCourt.contains(p['id'])),
      _Row({}),
    ], signatureOf(team));
  }

  /// Unsaved edits win; otherwise follow changes from other devices.
  _Draft draft(String team) {
    final current = drafts[team];
    if (current != null &&
        (current.dirty ||
            current.signature == signatureOf(team) ||
            current.rows.any((r) => r.active))) {
      return current;
    }
    for (final row in current?.rows ?? <_Row>[]) {
      row.dispose();
    }
    return drafts[team] = fresh(team);
  }

  @override
  void didUpdateWidget(TeamEditor old) {
    super.didUpdateWidget(old);
    // Back online: whatever was typed meanwhile goes out now.
    if (widget.enabled && !old.enabled) {
      for (final d in drafts.values.where((d) => d.dirty)) {
        schedule(d);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.flush?._editors.add(flushDrafts);
  }

  /// Leaving must not lose what was entered: hand every unsaved team over.
  void flushDrafts() {
    for (final d in drafts.values) {
      if (d.dirty) {
        revertDuplicates(d);
        final players = <Map<String, dynamic>>[];
        final onCourt = <String>[];
        if (collect(d, players, onCourt, hold: false) == null) {
          unawaited(widget.onSave(d.team, players, onCourt));
        }
      }
    }
  }

  @override
  void dispose() {
    widget.flush?._editors.remove(flushDrafts);
    for (final timer in autosaves.values) {
      timer.cancel();
    }
    for (final timer in revealTimers) {
      timer.cancel();
    }
    flushDrafts();
    for (final d in drafts.values) {
      for (final row in d.rows) {
        row.dispose();
      }
    }
    paste.dispose();
    teamName.dispose();
    super.dispose();
  }

  /// Scroll the edited row to the top once the phone keyboard has opened.
  void reveal(_Row row) {
    void scroll() {
      final target = row.key.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target,
          alignment: 0,
          duration: const Duration(milliseconds: 150),
        );
      }
    }

    // The keyboard takes a moment to open, longer on slower phones.
    for (final timer in revealTimers) {
      timer.cancel();
    }
    revealTimers = [
      Timer(const Duration(milliseconds: 350), scroll),
      Timer(const Duration(milliseconds: 800), scroll),
    ];
  }

  /// Fast entry: Enter/Next goes straight to the empty row at the end.
  void advance(_Draft d, _Row row) {
    final next = d.rows.last;
    if (next.blank && next != row) next.focus.requestFocus();
  }

  void changed(_Draft d) {
    d.dirty = true;
    d.version++;
    d.error = '';
    // Keep one empty row at the end for fast entry.
    if (!d.rows.last.blank && d.rows.length < 40) d.rows.add(_Row({}));
    schedule(d);
    setState(() {});
  }

  void schedule(_Draft d) {
    autosaves[d.team]?.cancel();
    autosaves[d.team] = Timer(const Duration(milliseconds: 900), () {
      if (mounted) save(d, auto: true);
    });
  }

  /// Rows repeating a number that an earlier-entered row already has.
  Set<_Row> duplicates(_Draft d) {
    final holder = <String, _Row>{};
    final repeated = <_Row>{};
    for (final row in d.rows) {
      final number = row.normalized;
      if (number.isEmpty) continue;
      final current = holder[number];
      if (current == null) {
        holder[number] = row;
      } else if (row.edited < current.edited) {
        repeated.add(current);
        holder[number] = row;
      } else {
        repeated.add(row);
      }
    }
    return repeated;
  }

  bool revertDuplicates(_Draft d) {
    final repeated = duplicates(d);
    for (final row in repeated) {
      row.number.text = row.savedNumber;
    }
    return repeated.isNotEmpty;
  }

  int rank(_Row row) => int.tryParse(row.normalized) ?? 1000;

  /// By shirt number; players without one follow, empty rows stay at the end.
  void sortRows(_Draft d) {
    final filled = d.rows.where((r) => !r.blank).toList();
    final blanks = d.rows.where((r) => r.blank).toList();
    final position = {for (final (i, r) in filled.indexed) r: i};
    filled.sort((a, b) {
      final order = rank(a).compareTo(rank(b));
      return order != 0 ? order : position[a]!.compareTo(position[b]!);
    });
    d.rows
      ..clear()
      ..addAll(filled)
      ..addAll(blanks);
  }

  void rowFocus(_Draft d, _Row row, bool focused) {
    row.active = focused;
    if (focused) reveal(row);
    if (focused || !mounted || drafts[d.team] != d) return;
    final refused = revertDuplicates(d);
    sortRows(d);
    if (d.dirty || refused) {
      changed(d);
      if (refused) d.error = t('error.duplicate_player');
      save(d, auto: true);
    } else {
      setState(() {});
    }
  }

  Future<void> toggleTeams(String mode) async {
    setState(() {
      teamsNote = '';
      teamsMode = teamsMode == mode ? '' : mode;
      if (teamsMode == 'save') teamName.text = widget.state[team]['name'] ?? '';
    });
    if (teamsMode == 'load') await loadTeams();
  }

  Future<void> loadTeams() async {
    try {
      final result = await widget.api!(
        '/api/teams?sport=${widget.state['sport']}',
        'GET',
        null,
      );
      if (mounted) setState(() => savedTeams = result['teams']);
    } catch (_) {
      if (mounted) setState(() => teamsNote = t('error.generic'));
    }
  }

  Future<void> saveTeam(_Draft d) async {
    final players = <Map<String, dynamic>>[];
    final problem = duplicates(d).isNotEmpty
        ? 'error.duplicate_player'
        : collect(d, players, <String>[], hold: false);
    final name = teamName.text.trim();
    if (problem != null || players.isEmpty || name.isEmpty) {
      setState(() => teamsNote = t(problem ?? 'teams.save_empty'));
      return;
    }
    try {
      await widget.api!('/api/teams', 'POST', {
        'sport': widget.state['sport'],
        'name': name,
        'short': widget.state[d.team]['short'],
        'color': widget.state[d.team]['color'],
        'players': [
          for (final p in players) {'number': p['number'], 'name': p['name']},
        ],
      });
      if (!mounted) return;
      setState(() {
        teamsMode = '';
        teamsNote = t('teams.saved');
      });
    } catch (_) {
      if (mounted) setState(() => teamsNote = t('error.generic'));
    }
  }

  Future<void> applyTeam(_Draft d, Map<String, dynamic> saved) async {
    FocusManager.instance.primaryFocus?.unfocus();
    autosaves[d.team]?.cancel();
    final typed = d.dirty;
    d.dirty = false; // the saved team replaces whatever was typed here
    final ok = await widget.onApply!(d.team, saved);
    if (!ok) d.dirty = typed; // refused (offline): keep what was typed
    if (mounted && ok) setState(() => teamsMode = '');
  }

  Future<void> deleteTeam(Map<String, dynamic> saved) async {
    try {
      await widget.api!('/api/teams/${saved['id']}', 'DELETE', null);
      await loadTeams();
    } catch (_) {
      if (mounted) setState(() => teamsNote = t('error.generic'));
    }
  }

  List<Widget> teamsPanel(_Draft d) => [
    Wrap(
      alignment: WrapAlignment.center,
      children: [
        TextButton(
          onPressed: () => toggleTeams('load'),
          child: Text(t('teams.load')),
        ),
        TextButton(
          onPressed: () => toggleTeams('save'),
          child: Text(t('teams.save')),
        ),
      ],
    ),
    if (teamsNote.isNotEmpty)
      Text(
        teamsNote,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70),
      ),
    if (teamsMode == 'load') ...[
      Text(
        t(savedTeams.isEmpty ? 'teams.none' : 'teams.replace_note'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: Colors.white70),
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: [
          for (final saved in savedTeams)
            InputChip(
              label: Text(
                '${saved['name']} (${(saved['players'] as List).length})',
              ),
              onPressed: widget.enabled
                  ? () => applyTeam(d, Map<String, dynamic>.from(saved))
                  : null,
              onDeleted: () => deleteTeam(Map<String, dynamic>.from(saved)),
            ),
        ],
      ),
    ],
    if (teamsMode == 'save')
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: teamName,
              maxLength: 60,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                border: const OutlineInputBorder(),
                labelText: t('teams.name'),
              ),
              onSubmitted: (_) => saveTeam(d),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => saveTeam(d), child: Text(t('save'))),
        ],
      ),
  ];

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
    sortRows(d);
    paste.clear();
    pasteOpen = false;
    changed(d);
  }

  /// Fills [players] and [onCourt], returning null when they can be sent.
  /// Otherwise the translation key of the problem, or '' for "not yet": a
  /// row still being typed in ([hold]) must not be judged or deleted.
  String? collect(
    _Draft d,
    List<Map<String, dynamic>> players,
    List<String> onCourt, {
    required bool hold,
  }) {
    final numbers = <String>{};
    final rows = [...d.rows];
    rows.sort((a, b) => rank(a).compareTo(rank(b)));
    for (final row in rows) {
      var number = row.number.text.trim();
      final name = row.name.text.trim();
      if (number.isEmpty && name.isEmpty) {
        if (hold && row.active && row.saved) return '';
        continue;
      }
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
      if (problem != null) return hold && row.active ? '' : problem;
      players.add({'id': row.id, 'number': number, 'name': name});
      if (row.onCourt) onCourt.add(row.id);
    }
    return null;
  }

  Future<void> save(_Draft d, {bool auto = false}) async {
    autosaves[d.team]?.cancel();
    if (!d.dirty || !widget.enabled) return;
    if (saving) {
      schedule(d); // the other team is on its way: this one follows
      return;
    }
    if (duplicates(d).isNotEmpty) {
      if (!auto) setState(() => d.error = t('error.duplicate_player'));
      return;
    }
    final players = <Map<String, dynamic>>[];
    final onCourt = <String>[];
    final problem = collect(d, players, onCourt, hold: auto);
    if (problem != null) {
      if (problem.isNotEmpty) setState(() => d.error = t(problem));
      return;
    }
    final version = d.version;
    final sent = [
      for (final row in d.rows)
        if (!row.blank) row,
    ];
    final numbers = [for (final row in sent) row.normalized];
    setState(() => saving = true);
    final ok = await widget.onSave(d.team, players, onCourt);
    if (!mounted) return;
    setState(() {
      saving = false;
      if (!ok) return;
      for (final (i, row) in sent.indexed) {
        row
          ..saved = true
          ..savedNumber = numbers[i];
      }
      if (d.version != version) {
        schedule(d); // typed on while this save was under way
        return;
      }
      d.dirty = false;
      d.signature = signatureOf(d.team);
      if (d.rows.any((r) => r.active) || drafts[d.team] != d) return;
      drafts.remove(d.team);
      for (final row in d.rows) {
        row.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = draft(team);
    final checked = d.rows.where((r) => r.onCourt && !r.blank).length;
    final repeated = duplicates(d);
    final message = repeated.isNotEmpty ? t('error.duplicate_player') : d.error;
    const dense = InputDecoration(
      isDense: true,
      counterText: '',
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
    const duplicateBorder = OutlineInputBorder(
      borderSide: BorderSide(color: Colors.orange, width: 2),
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
                    onSelected: (_) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() {
                        team = side;
                        teamsMode = teamsNote = '';
                      });
                    },
                  ),
                ),
              Expanded(
                // One line, shrunk if need be: in a narrow panel the label
                // used to wrap into three lines.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${t('team.on_court')} $checked/$limit',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 13,
                      color: checked > limit ? Colors.orange : Colors.white70,
                    ),
                  ),
                ),
              ),
              if (widget.onPortrait != null)
                IconButton(
                  tooltip: t('team.portrait'),
                  icon: const Icon(Icons.stay_current_portrait),
                  onPressed: widget.onPortrait,
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
        if (message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(message, style: const TextStyle(color: Colors.orange)),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final row in d.rows)
                Padding(
                  key: row.key,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Focus(
                    skipTraversal: true,
                    canRequestFocus: false,
                    onFocusChange: (focused) => rowFocus(d, row, focused),
                    child: Row(
                      children: [
                        Tooltip(
                          message: t('team.on_court'),
                          child: Checkbox(
                            focusNode: row.tickFocus,
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
                              enabledBorder: repeated.contains(row)
                                  ? duplicateBorder
                                  : null,
                              focusedBorder: repeated.contains(row)
                                  ? duplicateBorder
                                  : null,
                            ),
                            onChanged: (_) {
                              row.edited = ++editClock;
                              changed(d);
                            },
                            onTap: () => reveal(row),
                            onEditingComplete: () => advance(d, row),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            controller: row.name,
                            onEditingComplete: () => advance(d, row),
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
                          focusNode: row.removeFocus,
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
                ),
              if (widget.api != null) ...teamsPanel(d),
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
