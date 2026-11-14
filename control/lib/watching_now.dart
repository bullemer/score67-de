import 'dart:async';
import 'package:flutter/material.dart';

class WatchingNow extends StatefulWidget {
  const WatchingNow({
    super.key,
    required this.slug,
    required this.api,
    required this.label,
  });
  final String slug, label;
  final Future<dynamic> Function(String) api;
  @override
  State<WatchingNow> createState() => _WatchingNowState();
}

class _WatchingNowState extends State<WatchingNow> {
  Timer? timer;
  int? count;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final data = await widget.api('/api/s/${widget.slug}/audience');
      if (mounted) setState(() => count = data['watching_now'] as int);
    } catch (_) {
      if (mounted) setState(() => count = null);
    } finally {
      loading = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xff142515),
    child: SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Text(
          widget.label.replaceAll('{n}', count?.toString() ?? '–'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Color(0xffb6f36e)),
        ),
      ),
    ),
  );
}
