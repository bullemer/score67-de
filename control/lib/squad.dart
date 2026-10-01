import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class SquadDialog extends StatefulWidget {
  final String teamName;
  final bool requireNumber;
  final List<dynamic> players;
  final String Function(String) t;
  const SquadDialog({
    super.key,
    this.requireNumber = false,
    required this.teamName,
    required this.players,
    required this.t,
  });
  @override
  State<SquadDialog> createState() => _SquadDialogState();
}

class _PlayerRow {
  final String id;
  final focus = FocusNode();
  final key = GlobalKey();
  final TextEditingController number, name;
  _PlayerRow(Map<String, dynamic> p)
    : id = p['id'] ?? const Uuid().v4(),
      number = TextEditingController(text: p['number'] ?? ''),
      name = TextEditingController(text: p['name'] ?? '');
  void dispose() {
    focus.dispose();
    number.dispose();
    name.dispose();
  }
}

class _SquadDialogState extends State<SquadDialog> {
  late final List<_PlayerRow> rows;
  final List<_PlayerRow> removed = [];
  String error = '';
  bool bulkOpen = false;
  final bulk = TextEditingController();
  String t(String key) => widget.t(key);
  @override
  void initState() {
    super.initState();
    rows = widget.players
        .map((p) => _PlayerRow(Map<String, dynamic>.from(p)))
        .toList();
    if (rows.isEmpty) rows.add(_PlayerRow({}));
  }

  @override
  void dispose() {
    for (final row in [...rows, ...removed]) {
      row.dispose();
    }
    bulk.dispose();
    super.dispose();
  }

  void focusRow(_PlayerRow row) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      row.focus.requestFocus();
      final target = row.key.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 150),
        );
      }
    });
  }

  void addRow([_PlayerRow? current]) {
    if (current != null) {
      final index = rows.indexOf(current);
      if (index < rows.length - 1) {
        focusRow(rows[index + 1]);
        return;
      }
    }
    final blank = rows
        .where(
          (r) => r.number.text.trim().isEmpty && r.name.text.trim().isEmpty,
        )
        .firstOrNull;
    if (blank != null) {
      focusRow(blank);
      return;
    }
    if (rows.length >= 40) return;
    final row = _PlayerRow({});
    setState(() => rows.add(row));
    focusRow(row);
  }

  void importPlayers() {
    final parsed = <Map<String, dynamic>>[];
    final numbers = rows
        .map((r) => int.tryParse(r.number.text.trim()))
        .whereType<int>()
        .toSet();
    for (final line in bulk.text.split(RegExp(r'[\r\n]+'))) {
      if (line.trim().isEmpty) continue;
      final match = RegExp(
        r'^#?([0-9]{1,3})(?:[\t ,;]+(.*))?$',
      ).firstMatch(line.trim());
      if (match == null || (match.group(2) ?? '').length > 60) {
        setState(() => error = t('squad.paste_error'));
        return;
      }
      final number = int.parse(match.group(1)!);
      if (!numbers.add(number)) {
        setState(() => error = t('error.duplicate_player'));
        return;
      }
      parsed.add({'number': '$number', 'name': (match.group(2) ?? '').trim()});
    }
    final used = rows
        .where(
          (r) =>
              r.number.text.trim().isNotEmpty || r.name.text.trim().isNotEmpty,
        )
        .length;
    if (used + parsed.length > 40) {
      setState(() => error = t('squad.limit'));
      return;
    }
    if (parsed.isEmpty) return;
    setState(() {
      final blanks = rows
          .where(
            (r) => r.number.text.trim().isEmpty && r.name.text.trim().isEmpty,
          )
          .toList();
      rows.removeWhere(blanks.contains);
      removed.addAll(blanks);
      rows.addAll(parsed.map(_PlayerRow.new));
      bulk.clear();
      bulkOpen = false;
      error = '';
    });
    focusRow(rows.last);
  }

  void save() {
    final numbers = <String>{};
    final players = <Map<String, dynamic>>[];
    for (final row in rows) {
      var number = row.number.text.trim();
      final name = row.name.text.trim();
      if (number.isEmpty && name.isEmpty) continue;
      if (widget.requireNumber && number.isEmpty) {
        setState(() => error = t('error.player_number_required'));
        return;
      }
      if ((number.isNotEmpty && !RegExp(r'^[0-9]{1,3}$').hasMatch(number)) ||
          name.length > 60 ||
          (number.isEmpty && name.isEmpty)) {
        setState(() => error = t('error.invalid_squad'));
        return;
      }
      if (number.isNotEmpty) {
        number = int.parse(number).toString();
        if (!numbers.add(number)) {
          setState(() => error = t('error.duplicate_player'));
          return;
        }
      }
      players.add({'id': row.id, 'number': number, 'name': name});
    }
    Navigator.pop(context, players);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${t('squad')} · ${widget.teamName}'),
    content: SizedBox(
      width: 520,
      height: math.min(
        MediaQuery.sizeOf(context).height * .55,
        150.0 + rows.length * 76 + (bulkOpen ? 180 : 0),
      ),
      child: ListView(
        children: [
          Text(
            t(widget.requireNumber ? 'basketball.squad_note' : 'squad.note'),
          ),
          Text(t('squad.quick_help')),
          TextButton(
            onPressed: () => setState(() => bulkOpen = !bulkOpen),
            child: Text(t('squad.paste')),
          ),
          if (bulkOpen) ...[
            TextField(
              controller: bulk,
              minLines: 2,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: t('squad.paste'),
                hintText: '7 Alex\n12 Sam\n23',
                border: const OutlineInputBorder(),
              ),
            ),
            TextButton(
              onPressed: importPlayers,
              child: Text(t('squad.import')),
            ),
          ],
          const SizedBox(height: 12),
          if (error.isNotEmpty)
            Text(error, style: const TextStyle(color: Colors.orange)),
          for (final row in rows)
            Padding(
              key: row.key,
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: row.number,
                      focusNode: row.focus,
                      autofocus: rows.indexOf(row) == 0,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => addRow(row),
                      maxLength: 3,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: t('player.number'),
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: row.name,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => addRow(row),
                      maxLength: 60,
                      decoration: InputDecoration(
                        labelText: t('player.name'),
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t('player.remove'),
                    onPressed: () => setState(() {
                      removed.add(row);
                      rows.remove(row);
                    }),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              ),
            ),
          OutlinedButton(
            onPressed: rows.length >= 40 ? null : addRow,
            child: Text(t('player.add')),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('cancel')),
      ),
      FilledButton(onPressed: save, child: Text(t('save'))),
    ],
  );
}
