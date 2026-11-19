import 'package:flutter/material.dart';

/// Team Editor (☰ menu): the saved teams of this browser or account, edited
/// in landscape without dialogs. Left the list, right the selected team:
/// name, short name, colour and players. Saved teams are loaded into a game
/// from the Team tab.
class SavedTeamsPage extends StatefulWidget {
  final String Function(String) t;
  final Future<dynamic> Function(
    String path,
    String method,
    Map<String, dynamic>? body,
  )
  api;
  final String sport;
  final VoidCallback onClose;
  const SavedTeamsPage({
    super.key,
    required this.t,
    required this.api,
    required this.sport,
    required this.onClose,
  });

  @override
  State<SavedTeamsPage> createState() => _SavedTeamsPageState();
}

class _PlayerRow {
  final number = TextEditingController(), name = TextEditingController();
  _PlayerRow([String number = '', String name = '']) {
    this.number.text = number;
    this.name.text = name;
  }
  bool get blank => number.text.trim().isEmpty && name.text.trim().isEmpty;
  void dispose() {
    number.dispose();
    name.dispose();
  }
}

class _SavedTeamsPageState extends State<SavedTeamsPage> {
  static const colors = [
    '#c8102e',
    '#1d4ed8',
    '#16a34a',
    '#facc15',
    '#f97316',
    '#7c3aed',
    '#111827',
    '#ffffff',
  ];
  List<Map<String, dynamic>> teams = [];
  bool loading = true, busy = false, deleteArmed = false, dirty = false;

  /// The team in the editor: its id, '' for a new one, null for none.
  String? selected;
  String color = colors.first, note = '';
  final name = TextEditingController(), short = TextEditingController();
  final rows = <_PlayerRow>[];

  String t(String key) => widget.t(key);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    short.dispose();
    for (final row in rows) {
      row.dispose();
    }
    super.dispose();
  }

  String problem(Object e) {
    final text = '$e';
    return t(
      text.startsWith('ApiError:') ? 'error.${text.substring(9)}' : 'network',
    );
  }

  Future<void> load({String? select}) async {
    try {
      final result = await widget.api(
        '/api/teams?sport=${widget.sport}',
        'GET',
        null,
      );
      if (!mounted) return;
      setState(() {
        teams = [
          for (final team in result['teams'] as List)
            Map<String, dynamic>.from(team),
        ];
        loading = false;
      });
      final target = teams.where((team) => team['id'] == select).firstOrNull;
      if (target != null) open(target);
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          note = problem(e);
        });
      }
    }
  }

  void fill(String? id, String teamName, String teamShort, List players) {
    for (final row in rows) {
      row.dispose();
    }
    rows
      ..clear()
      ..addAll([
        for (final p in players)
          _PlayerRow('${p['number'] ?? ''}', '${p['name'] ?? ''}'),
        _PlayerRow(),
      ]);
    name.text = teamName;
    short.text = teamShort;
    selected = id;
    deleteArmed = false;
    dirty = false;
  }

  void open(Map<String, dynamic> team) => setState(() {
    color = '${team['color']}';
    fill('${team['id']}', '${team['name']}', '${team['short']}', [
      ...team['players'] as List,
    ]);
    note = '';
  });

  void create() => setState(() {
    color = colors.first;
    fill('', '', '', []);
    note = '';
  });

  void changed() => setState(() {
    dirty = true;
    deleteArmed = false;
    note = '';
    // One empty row at the end is always ready for the next player.
    if (rows.isEmpty || (!rows.last.blank && rows.length < 40)) {
      rows.add(_PlayerRow());
    }
  });

  Future<void> save() async {
    final teamName = name.text.trim();
    var teamShort = short.text.trim().toUpperCase();
    if (teamName.isEmpty) {
      setState(() => note = t('teams.save_empty'));
      return;
    }
    if (teamShort.isEmpty) {
      teamShort = teamName.substring(0, teamName.length.clamp(0, 3));
    }
    setState(() => busy = true);
    try {
      final saved = await widget.api('/api/teams', 'POST', {
        if ((selected ?? '').isNotEmpty) 'id': selected,
        'sport': widget.sport,
        'name': teamName,
        'short': teamShort.toUpperCase(),
        'color': color,
        'players': [
          for (final row in rows)
            if (!row.blank)
              {'number': row.number.text.trim(), 'name': row.name.text.trim()},
        ],
      });
      if (!mounted) return;
      await load(select: '${saved['id']}');
      if (mounted) setState(() => note = t('teams.saved'));
    } catch (e) {
      if (mounted) setState(() => note = problem(e));
    }
    if (mounted) setState(() => busy = false);
  }

  /// Two taps instead of a confirmation dialog.
  Future<void> remove() async {
    if (!deleteArmed) {
      setState(() => deleteArmed = true);
      return;
    }
    setState(() => busy = true);
    try {
      await widget.api('/api/teams/$selected', 'DELETE', null);
      if (!mounted) return;
      setState(() {
        selected = null;
        note = t('teams.deleted');
      });
      await load();
    } catch (e) {
      if (mounted) setState(() => note = problem(e));
    }
    if (mounted) setState(() => busy = false);
  }

  static Color hex(String value) =>
      Color(int.parse(value.replaceFirst('#', 'ff'), radix: 16));

  Widget list() => SizedBox(
    width: 220,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(6),
          child: FilledButton.icon(
            onPressed: busy ? null : create,
            icon: const Icon(Icons.add),
            label: Text(t('teams.new')),
          ),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : teams.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    t('teams.none'),
                    style: const TextStyle(color: Colors.white70),
                  ),
                )
              : ListView(
                  children: [
                    for (final team in teams)
                      ListTile(
                        dense: true,
                        selected: team['id'] == selected,
                        selectedTileColor: const Color(0xff2b3a4d),
                        leading: CircleAvatar(
                          radius: 9,
                          backgroundColor: hex('${team['color']}'),
                        ),
                        title: Text(
                          '${team['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${team['short']} · ${(team['players'] as List).length}',
                        ),
                        onTap: busy ? null : () => open(team),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );

  Widget editor() {
    const dense = InputDecoration(
      isDense: true,
      counterText: '',
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
    if (selected == null) {
      return Center(
        child: Text(
          note.isEmpty ? t('teams.pick') : note,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('team-name'),
                  controller: name,
                  maxLength: 60,
                  textInputAction: TextInputAction.next,
                  decoration: dense.copyWith(hintText: t('teams.name')),
                  onChanged: (_) => changed(),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 76,
                child: TextField(
                  key: const ValueKey('team-short'),
                  controller: short,
                  maxLength: 3,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  decoration: dense.copyWith(hintText: t('teams.short')),
                  onChanged: (_) => changed(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
                onPressed: busy || !dirty ? null : save,
                child: Text(t('save')),
              ),
              if ((selected ?? '').isNotEmpty) ...[
                const SizedBox(width: 6),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 40),
                    foregroundColor: Colors.orange,
                    backgroundColor: deleteArmed
                        ? const Color(0xff3a2a16)
                        : null,
                  ),
                  onPressed: busy ? null : remove,
                  child: deleteArmed
                      ? Text(t('teams.delete_confirm'))
                      : const Icon(Icons.delete_outline),
                ),
              ],
            ],
          ),
        ),
        // Hidden while the keyboard is up: the player rows need the room.
        Visibility(
          visible: MediaQuery.sizeOf(context).height >= 320,
          maintainState: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (final value in colors)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        color = value;
                        changed();
                      },
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: hex(value),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: value == color
                                ? const Color(0xffb6f36e)
                                : Colors.white24,
                            width: value == color ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    note,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        child: TextField(
                          controller: row.number,
                          maxLength: 3,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          decoration: dense.copyWith(
                            hintText: t('player.number'),
                          ),
                          onChanged: (_) => changed(),
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
                          onChanged: (_) => changed(),
                        ),
                      ),
                      // Next on the keyboard goes from field to field, never here.
                      ExcludeFocus(
                        child: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: row.blank
                              ? null
                              : () {
                                  rows.remove(row);
                                  // Disposed after this frame: the field is
                                  // still mounted while the row goes away.
                                  WidgetsBinding.instance.addPostFrameCallback(
                                    (_) => row.dispose(),
                                  );
                                  changed();
                                },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // With the keyboard up the title bar and the list make room for the
    // fields. Hidden, not removed: the tree keeps its shape, the field its focus.
    final typing = MediaQuery.sizeOf(context).height < 320;
    Widget calm(Widget child) =>
        Visibility(visible: !typing, maintainState: true, child: child);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        calm(
          SizedBox(
            height: 44,
            child: Row(
              children: [
                IconButton(
                  tooltip: t('back'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onClose,
                ),
                Text(
                  t('teams.editor'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              calm(list()),
              calm(const VerticalDivider(width: 1)),
              Expanded(child: editor()),
            ],
          ),
        ),
      ],
    );
  }
}
