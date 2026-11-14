import 'dart:async';
import 'package:flutter/material.dart';

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
  final name = TextEditingController();
  final message = TextEditingController();
  final scroll = ScrollController();
  List<dynamic> messages = [];
  Timer? timer;
  bool sending = false, polling = false;
  int version = 0;
  String error = '';
  String get path => '/api/s/${widget.slug}/chat';

  @override
  void initState() {
    super.initState();
    name.text = widget.t('control');
    refresh();
    timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (TickerMode.of(context)) refresh();
    });
  }

  void receive(dynamic data) {
    final atBottom = !scroll.hasClients || scroll.position.extentAfter < 60;
    setState(() {
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
    if (remove == null &&
        (name.text.trim().isEmpty || message.text.trim().isEmpty)) {
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
        remove == null
            ? {'name': name.text.trim(), 'text': message.text.trim()}
            : null,
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
    name.dispose();
    message.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? Center(child: Text(widget.t('chat.empty')))
              : ListView.builder(
                  controller: scroll,
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final row = messages[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '${row['name']}${row['controller'] == true ? ' · ${widget.t('control')}' : ''}',
                      ),
                      subtitle: Text(row['text'] as String),
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
            SizedBox(
              width: 110,
              child: TextField(
                controller: name,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: widget.t('chat.name'),
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
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
