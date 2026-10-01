import 'package:flutter/material.dart';

/// Inline foul controls keep the main clock accessible while recording a foul.
class PersonalFouls extends StatefulWidget {
  final List<dynamic> players;
  final int unassigned;
  final bool enabled;
  final String Function(String) t;
  final Future<bool> Function(Map<String, dynamic>) add;
  final void Function(String?) remove;
  const PersonalFouls({
    super.key,
    required this.players,
    required this.unassigned,
    required this.enabled,
    required this.t,
    required this.add,
    required this.remove,
  });
  @override
  State<PersonalFouls> createState() => _PersonalFoulsState();
}

class _PersonalFoulsState extends State<PersonalFouls> {
  final number = TextEditingController();
  String error = '';
  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }

  Future<void> addNumber() async {
    if (!RegExp(r'^[0-9]{1,3}$').hasMatch(number.text.trim())) {
      setState(() => error = widget.t('foul.number_error'));
      return;
    }
    final success = await widget.add({'player_number': number.text.trim()});
    if (mounted && success) {
      setState(() {
        number.clear();
        error = '';
      });
    }
  }

  String label(dynamic player) => [
    if ((player['number'] ?? '').isNotEmpty) '#${player['number']}',
    if ((player['name'] ?? '').isNotEmpty) player['name'],
  ].join(' ');

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(widget.t('personal_fouls'), textAlign: TextAlign.center),
      if (widget.players.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final player in widget.players) ...[
                const Divider(),
                Text(
                  [
                    if ((player['number'] ?? '').isNotEmpty)
                      '#${player['number']}',
                    if ((player['name'] ?? '').isNotEmpty) player['name'],
                  ].join(' '),
                  textAlign: TextAlign.center,
                ),
                Text(
                  '${player['fouls']} ${widget.t('fouls')}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: player['fouls'] >= 5
                        ? const Color(0xffff8b8b)
                        : player['fouls'] == 4
                        ? const Color(0xfffacc15)
                        : null,
                  ),
                ),
                if (player['fouls'] >= 4)
                  Text(
                    widget.t(player['fouls'] >= 5 ? 'foul.five' : 'foul.four'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip:
                          '− ${widget.t('personal_foul')} · ${label(player)}',
                      icon: const Icon(Icons.remove),
                      onPressed: widget.enabled && player['fouls'] > 0
                          ? () => widget.remove(player['id'])
                          : null,
                    ),
                    IconButton(
                      tooltip:
                          '+ ${widget.t('personal_foul')} · ${label(player)}',
                      icon: const Icon(Icons.add),
                      onPressed: widget.enabled
                          ? () => widget.add({'player_id': player['id']})
                          : null,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      const Divider(),
      TextField(
        controller: number,
        maxLength: 3,
        keyboardType: TextInputType.number,
        enabled: widget.enabled,
        decoration: InputDecoration(
          labelText: widget.t('player.number'),
          counterText: '',
          border: const OutlineInputBorder(),
        ),
        onSubmitted: widget.enabled ? (_) => addNumber() : null,
      ),
      TextButton(
        onPressed: widget.enabled ? addNumber : null,
        child: Text(widget.t('foul.add_number')),
      ),
      if (error.isNotEmpty)
        Text(error, style: const TextStyle(color: Colors.orange)),
      Text(
        '${widget.t('foul.unknown')}: ${widget.unassigned}',
        textAlign: TextAlign.center,
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: '− ${widget.t('foul.unknown')}',
            icon: const Icon(Icons.remove),
            onPressed: widget.enabled && widget.unassigned > 0
                ? () => widget.remove(null)
                : null,
          ),
          IconButton(
            tooltip: '+ ${widget.t('foul.unknown')}',
            icon: const Icon(Icons.add),
            onPressed: widget.enabled ? () => widget.add({}) : null,
          ),
        ],
      ),
    ],
  );
}
