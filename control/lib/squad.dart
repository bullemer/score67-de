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
  final TextEditingController number, name;
  _PlayerRow(Map<String, dynamic> p)
    : id = p['id'] ?? const Uuid().v4(),
      number = TextEditingController(text: p['number'] ?? ''),
      name = TextEditingController(text: p['name'] ?? '');
  void dispose() {
    number.dispose();
    name.dispose();
  }
}

class _SquadDialogState extends State<SquadDialog> {
  late final List<_PlayerRow> rows;
  final List<_PlayerRow> removed = [];
  String error = '';
  String t(String key) => widget.t(key);
  @override
  void initState() {
    super.initState();
    rows = widget.players
        .map((p) => _PlayerRow(Map<String, dynamic>.from(p)))
        .toList();
  }

  @override
  void dispose() {
    for (final row in [...rows, ...removed]) {
      row.dispose();
    }
    super.dispose();
  }

  void save() {
    final numbers = <String>{};
    final players = <Map<String, dynamic>>[];
    for (final row in rows) {
      var number = row.number.text.trim();
      final name = row.name.text.trim();
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
      height: MediaQuery.sizeOf(context).height * .55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t(widget.requireNumber ? 'basketball.squad_note' : 'squad.note'),
          ),
          const SizedBox(height: 12),
          if (error.isNotEmpty)
            Text(error, style: const TextStyle(color: Colors.orange)),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return Padding(
                  key: ValueKey(row.id),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 64,
                        child: TextField(
                          controller: row.number,
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
                          removed.add(rows.removeAt(index));
                        }),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          OutlinedButton(
            onPressed: rows.length >= 40
                ? null
                : () => setState(() => rows.add(_PlayerRow({}))),
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
