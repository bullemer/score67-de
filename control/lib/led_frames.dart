import 'package:flutter/material.dart';

/// One locally configured Bluetooth LED display (max. two per phone).
class LedConfig {
  String name, content, driver;

  /// How often the time changes on the panel: 'second', 'minute' or 'none'.
  /// Many Bluetooth LED panels redraw slowly, so minutes are the default.
  String clockMode;
  int width, height;
  LedConfig({
    this.name = 'LED',
    this.width = 64,
    this.height = 32,
    this.content = 'all',
    this.driver = 'text',
    this.clockMode = 'minute',
  });

  /// Characters per line and lines for a 5×7 font (6×8 px per character).
  int get columns => (width ~/ 6).clamp(2, 60);
  int get rows => (height ~/ 8).clamp(1, 8);

  Map<String, dynamic> toJson() => {
    'name': name,
    'width': width,
    'height': height,
    'content': content,
    'driver': driver,
    'clock': clockMode,
  };
  factory LedConfig.fromJson(Map<String, dynamic> json) => LedConfig(
    name: json['name'] ?? 'LED',
    width: (json['width'] as int? ?? 64).clamp(8, 1024),
    height: (json['height'] as int? ?? 32).clamp(8, 512),
    content: json['content'] ?? 'all',
    driver: json['driver'] ?? 'text',
    clockMode: json['clock'] ?? 'minute',
  );
}

/// First candidate that fits; the last one is never cut, because a
/// truncated score (87:10 for 87:102) would be wrong rather than short.
String _fit(List<String> candidates, int columns) => candidates.firstWhere(
  (c) => c.length <= columns,
  orElse: () => candidates.last,
);

/// True when some line is wider than the panel can show.
bool ledOverflows(LedConfig config, List<String> lines) =>
    lines.any((line) => line.length > config.columns);

/// The time as the panel shows it: 05:31 → 5' in minute mode.
String panelClock(LedConfig config, String clock) {
  switch (config.clockMode) {
    case 'none':
      return '';
    case 'minute':
      final match = RegExp(r'^(\d+):\d\d$').firstMatch(clock);
      return match == null ? clock : "${int.parse(match[1]!)}'";
    default:
      return clock;
  }
}

/// The lines an LED display of this size shows (also used for the preview).
List<String> ledLines(
  LedConfig config,
  Map<String, dynamic> state,
  String clock,
  String period,
) {
  final home = state['home'] ?? {}, away = state['away'] ?? {};
  final hs = '${home['score'] ?? 0}', as = '${away['score'] ?? 0}';
  final columns = config.columns;
  clock = panelClock(config, clock);
  final score = _fit([
    '${home['short'] ?? ''} $hs:$as ${away['short'] ?? ''}',
    '${home['short'] ?? ''} $hs-$as',
    '$hs:$as',
  ], columns);
  final time = _fit([
    if (period.isNotEmpty) '$period $clock'.trim(),
    clock.isEmpty ? period : clock,
  ], columns);
  switch (config.content) {
    case 'score':
      return [score];
    case 'clock':
      return [time];
    default:
      if (config.rows >= 2) return [score, time];
      return [
        _fit(['$hs:$as $clock', '$hs:$as'], columns),
      ];
  }
}

/// The bytes sent to the display, terminated by a newline.
String ledFrame(
  LedConfig config,
  Map<String, dynamic> state,
  String clock,
  String period,
) {
  if (config.driver == 'data') {
    // Machine-readable line for custom firmware (e.g. ESP32 + LED matrix).
    final home = state['home'] ?? {}, away = state['away'] ?? {};
    final fields = [
      'S67',
      home['short'] ?? '',
      home['score'] ?? 0,
      away['score'] ?? 0,
      away['short'] ?? '',
      panelClock(config, clock),
      period,
      state['phase'] ?? '',
      home['counters']?['team_fouls'] ?? home['counters']?['fouls'] ?? 0,
      away['counters']?['team_fouls'] ?? away['counters']?['fouls'] ?? 0,
    ];
    return '${fields.join(';')}\n';
  }
  return '${ledLines(config, state, clock, period).join('\n')}\n';
}

/// Approximate look of the LED display at its configured resolution.
class LedPreview extends StatelessWidget {
  final LedConfig config;
  final List<String> lines;
  const LedPreview({super.key, required this.config, required this.lines});

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: config.width / config.height,
    child: Container(
      color: Colors.black,
      padding: const EdgeInsets.all(4),
      child: FittedBox(
        child: SizedBox(
          width: config.columns * 6.0,
          height: config.rows * 8.0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final line in lines.take(config.rows))
                Text(
                  line,
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 7.5,
                    height: 1.05,
                    color: Color(0xffffb020),
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
