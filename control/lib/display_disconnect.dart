import 'package:flutter/material.dart';

import 'display_api.dart';

/// Confirm the exact connection the operator saw; the server checks it again
/// atomically before disconnecting, including a rematch on the same scoreboard.
Future<void> disconnectDisplay(
  BuildContext context,
  Api api,
  String Function(String) t,
  Map<String, dynamic> display,
) async {
  if (display['board'] == null) return;
  final board = display['board'];
  final match = display['match_id'];
  final label = display['match_label'] ?? display['board_description'] ?? board;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t('ledlink.disconnect_title')),
      content: Text(
        t('ledlink.disconnect_confirm')
            .replaceAll('{name}', '${display['name']}')
            .replaceAll('{match}', '$label'),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: Text(t('cancel')),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.link_off),
          label: Text(t('ledlink.disconnect')),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  await api('/api/displays/${display['id']}/disconnect', 'POST', {
    'expected_board': board,
    'expected_match': match,
  });
}
