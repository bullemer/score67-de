import 'dart:async';
import 'package:flutter/material.dart';
import 'dates.dart';
import 'watching_now.dart';

String chatAge(int createdAt, int now, String Function(String) t) {
  final seconds = ((now - createdAt) ~/ 1000).clamp(0, 2147483647);
  if (seconds == 0) return t('chat.age.now');
  final (key, count) = seconds < 60
      ? ('seconds', seconds)
      : seconds < 3600
      ? ('minutes', seconds ~/ 60)
      : seconds < 86400
      ? ('hours', seconds ~/ 3600)
      : (seconds < 172800 ? 'day' : 'days', seconds ~/ 86400);
  return t('chat.age.$key').replaceAll('{n}', '$count');
}

class GameChat extends StatefulWidget {
  const GameChat({
    super.key,
    required this.slug,
    required this.api,
    required this.t,
  });
  final String slug;
  final Future<dynamic> Function(String, String, Map<String, dynamic>?) api;
  final String Function(String) t;
  @override
  State<GameChat> createState() => _GameChatState();
}

class _GameChatState extends State<GameChat> {
  final message = TextEditingController();
  final scroll = ScrollController();
  List<dynamic> messages = [];
  Timer? timer;
  final sinceResponse = Stopwatch();
  int? serverAt;
  int ticks = 0;
  int get now => serverAt == null
      ? DateTime.now().millisecondsSinceEpoch
      : serverAt! + sinceResponse.elapsedMilliseconds;
  bool sending = false, polling = false;
  int version = 0;
  String error = '';
  String get path => '/api/s/${widget.slug}/chat';

  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!TickerMode.of(context)) return;
      setState(() {});
      if (++ticks % 3 == 0) refresh();
    });
  }

  void receive(dynamic data) {
    final atBottom = !scroll.hasClients || scroll.position.extentAfter < 60;
    setState(() {
      serverAt =
          data['server_now'] as int? ?? DateTime.now().millisecondsSinceEpoch;
      sinceResponse
        ..reset()
        ..start();
      messages = data['messages'] as List;
      error = '';
    });
    if (atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> refresh() async {
    if (polling || sending) return;
    polling = true;
    final current = version;
    try {
      final data = await widget.api(path, 'GET', null);
      if (mounted && current == version) receive(data);
    } catch (_) {
      if (mounted && current == version) {
        setState(() => error = widget.t('chat.error'));
      }
    } finally {
      polling = false;
    }
  }

  Future<void> write({String? remove}) async {
    if (sending) return;
    if (remove == null && message.text.trim().isEmpty) {
      return;
    }
    version++;
    setState(() {
      sending = true;
      error = '';
    });
    try {
      final data = await widget.api(
        remove == null ? path : '$path/$remove',
        remove == null ? 'POST' : 'DELETE',
        remove == null ? {'text': message.text.trim()} : null,
      );
      if (!mounted) return;
      if (remove == null) message.clear();
      receive(data);
    } catch (_) {
      if (mounted) setState(() => error = widget.t('chat.send_error'));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    message.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      children: [
        WatchingNow(
          key: ValueKey(widget.slug),
          slug: widget.slug,
          api: (path) => widget.api(path, 'GET', null),
          label: widget.t('watching.now'),
        ),
        Expanded(
          child: messages.isEmpty
              ? Center(child: Text(widget.t('chat.empty')))
              : ListView.builder(
                  controller: scroll,
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final row = messages[index];
                    final created = DateTime.fromMillisecondsSinceEpoch(
                      row['created_at'] as int,
                    );
                    return ListTile(
                      dense: true,
                      title: Text(row['text'] as String),
                      subtitle: Tooltip(
                        message:
                            '${europeanDate(created)} ${europeanTime(created)}',
                        child: Text(
                          '${chatAge(row['created_at'] as int, now, widget.t)}${row['controller'] == true ? ' · ${widget.t('control')}' : ''}',
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: widget.t('chat.delete'),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: sending
                            ? null
                            : () => write(remove: row['id'] as String),
                      ),
                    );
                  },
                ),
        ),
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(color: Colors.orange)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: message,
                maxLength: 500,
                minLines: 1,
                maxLines: 3,
                enabled: !sending,
                decoration: InputDecoration(
                  labelText: widget.t('chat.message'),
                  counterText: '',
                ),
              ),
            ),
            IconButton(
              tooltip: widget.t('chat.send'),
              icon: const Icon(Icons.send),
              onPressed: sending ? null : () => write(),
            ),
          ],
        ),
      ],
    ),
  );
}
