import 'dart:async';
import 'package:flutter/material.dart';

/// Navigation outside the app navigator stays available on nested pages too.
class ActiveGames extends StatefulWidget {
  const ActiveGames({
    super.key,
    required this.api,
    required this.label,
    required this.navigate,
    required this.child,
  });
  final Future<dynamic> Function(String) api;
  final String label;
  final void Function(String) navigate;
  final Widget child;

  @override
  State<ActiveGames> createState() => _ActiveGamesState();
}

class _ActiveGamesState extends State<ActiveGames> with WidgetsBindingObserver {
  List<dynamic> games = [];
  Timer? timer;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final data = await widget.api('/api/active-games');
      if (mounted) setState(() => games = data['games'] as List);
    } catch (_) {
      // A temporary connection failure should not remove the shortcut.
    } finally {
      loading = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (games.isNotEmpty)
        Material(
          color: const Color(0xff142515),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final game in games)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: TextButton(
                        onPressed: () =>
                            widget.navigate('/s/${game['slug']}/control'),
                        child: Text(
                          '${widget.label}: ${game['home']} – ${game['away']}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      Expanded(child: widget.child),
    ],
  );
}
