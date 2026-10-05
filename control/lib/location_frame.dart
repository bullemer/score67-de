import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// The venue map (/location-picker) embedded inline, e.g. in the console's
/// Settings tab. The page asks for the current venue when ready and posts the
/// chosen one (or null to remove it) back.
class LocationFrame extends StatefulWidget {
  final Map<String, dynamic>? current;
  final String lang, title;

  /// Stores the venue; the frame closes itself when this completes true.
  final Future<bool> Function(Map<String, dynamic>? location) onSave;
  const LocationFrame({
    super.key,
    required this.current,
    required this.lang,
    required this.title,
    required this.onSave,
  });

  @override
  State<LocationFrame> createState() => _LocationFrameState();
}

class _LocationFrameState extends State<LocationFrame> {
  web.HTMLIFrameElement? frame;
  bool saving = false;
  late final JSFunction listener = ((web.MessageEvent event) {
    unawaited(handle(event));
  }).toJS;

  @override
  void initState() {
    super.initState();
    web.window.addEventListener('message', listener);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', listener);
    super.dispose();
  }

  Future<void> handle(web.MessageEvent event) async {
    if (event.origin != web.window.location.origin ||
        frame == null ||
        event.source != frame!.contentWindow) {
      return;
    }
    final data = event.data.dartify();
    if (data is! Map) return;
    if (data['type'] == 'score67-location-ready') {
      frame!.contentWindow!.postMessage(
        {'type': 'score67-location-init', 'location': widget.current}.jsify(),
        web.window.location.origin.toJS,
      );
    } else if (data['type'] == 'score67-location-save' && !saving) {
      saving = true;
      try {
        await widget.onSave(
          data['location'] == null
              ? null
              : Map<String, dynamic>.from(data['location'] as Map),
        );
      } finally {
        saving = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 520,
    child: HtmlElementView.fromTagName(
      tagName: 'iframe',
      onElementCreated: (element) {
        frame = element as web.HTMLIFrameElement;
        frame!.title = widget.title;
        frame!.allow = 'geolocation';
        frame!.style.border = '0';
        frame!.style.width = '100%';
        frame!.style.height = '100%';
        frame!.src = '/location-picker?lang=${widget.lang}';
      },
    ),
  );
}
