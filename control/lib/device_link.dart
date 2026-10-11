import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef DeviceApi =
    Future<dynamic> Function(String, String, Map<String, dynamic>?);

/// The code inside a connect link (…/dashboard#connect=CODE) or a pasted code.
String? connectCode(String input) {
  final text = input.trim();
  final at = text.indexOf('connect=');
  final code = (at >= 0 ? text.substring(at + 8) : text).split('&').first;
  return RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(code) ? code : null;
}

/// "Meine Scoreboards" lives on the server per browser. This card makes the
/// list portable without email: a link connects another browser (both then
/// show the same boards) and, kept as a backup, brings the list back after
/// the browser data was cleared.
class DeviceLinkCard extends StatefulWidget {
  final DeviceApi api;
  final String Function(String) t;

  /// The page origin, e.g. https://score67.de.
  final String origin;

  /// Number of browsers sharing this list (from /api/dashboard).
  final int browsers;

  /// Called after another list was joined, with the number of boards.
  final void Function(int boards) onJoined;

  /// Opens the system share sheet; null or false falls back to copying.
  final Future<bool> Function(String url)? share;
  const DeviceLinkCard({
    super.key,
    required this.api,
    required this.t,
    required this.origin,
    required this.browsers,
    required this.onJoined,
    this.share,
  });
  @override
  State<DeviceLinkCard> createState() => _DeviceLinkCardState();
}

class _DeviceLinkCardState extends State<DeviceLinkCard> {
  final paste = TextEditingController();
  String? link;
  bool busy = false, pasting = false;
  String error = '';
  String t(String key) => widget.t(key);

  @override
  void dispose() {
    paste.dispose();
    super.dispose();
  }

  Future<void> createLink() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.api('/api/device/link', 'POST', {});
      link = '${widget.origin}/dashboard#connect=${result['code']}';
    } catch (_) {
      error = t('device.error');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> copy() async {
    await Clipboard.setData(ClipboardData(text: link!));
    if (mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(t('copied'))));
    }
  }

  Future<void> shareLink() async {
    if (widget.share == null || !await widget.share!(link!)) await copy();
  }

  Future<void> join() async {
    final code = connectCode(paste.text);
    if (code == null) {
      setState(() => error = t('device.link_invalid'));
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.api('/api/device/join', 'POST', {
        'code': code,
      });
      paste.clear();
      pasting = false;
      widget.onJoined(result['boards'] as int);
    } catch (_) {
      error = t('device.link_invalid');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xff151e2a),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('device.title'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          t('device.note'),
          style: const TextStyle(color: Color(0xffb5c2d4)),
        ),
        if (widget.browsers > 1) ...[
          const SizedBox(height: 6),
          Text(
            t('device.connected').replaceAll('{n}', '${widget.browsers}'),
            style: const TextStyle(color: Color(0xff8fd19e)),
          ),
        ],
        const SizedBox(height: 10),
        if (link == null)
          OutlinedButton(
            onPressed: busy ? null : createLink,
            child: Text(t('device.create')),
          )
        else ...[
          SelectableText(link!, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            t('device.keep'),
            style: const TextStyle(color: Color(0xffb5c2d4), fontSize: 13),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: shareLink,
                child: Text(t('device.share')),
              ),
              OutlinedButton(onPressed: copy, child: Text(t('copy'))),
            ],
          ),
        ],
        if (!pasting)
          TextButton(
            onPressed: () => setState(() => pasting = true),
            child: Text(t('device.paste')),
          )
        else ...[
          const SizedBox(height: 8),
          TextField(
            controller: paste,
            decoration: InputDecoration(labelText: t('device.paste_label')),
            onSubmitted: (_) => join(),
          ),
          const SizedBox(height: 6),
          FilledButton(
            onPressed: busy ? null : join,
            child: Text(t('device.join')),
          ),
        ],
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(color: Color(0xffffb4ab))),
      ],
    ),
  );
}
