import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'led_frames.dart';

export 'led_frames.dart';

/// Bridge to web/score67_ble.js (Web Bluetooth; Chrome on Android/desktop).
@JS('score67Ble')
external _Ble? get _ble;

extension type _Ble._(JSObject _) implements JSObject {
  external bool supported();
  external JSPromise<JSString> connect(int slot);
  external JSPromise<JSBoolean> write(int slot, String text);
  external void disconnect(int slot);
  external String status(int slot);
  external String name(int slot);
}

class Ble {
  static bool get supported {
    try {
      return _ble?.supported() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the browser's device chooser; needs a user gesture (a tap).
  static Future<String> connect(int slot) async =>
      (await _ble!.connect(slot).toDart).toDart;
  static Future<bool> write(int slot, String text) async =>
      (await _ble!.write(slot, text).toDart).toDart;
  static void disconnect(int slot) => _ble?.disconnect(slot);
  static String status(int slot) => _ble?.status(slot) ?? 'disconnected';
  static String name(int slot) => _ble?.name(slot) ?? '';
}

const _storageKey = 'score67-ble-displays';

List<LedConfig> loadLedConfigs() {
  try {
    final saved = jsonDecode(
      web.window.localStorage.getItem(_storageKey) ?? '[]',
    );
    return [
      for (final item in (saved as List).take(2))
        LedConfig.fromJson(Map<String, dynamic>.from(item)),
    ];
  } catch (_) {
    return [];
  }
}

void saveLedConfigs(List<LedConfig> configs) {
  try {
    web.window.localStorage.setItem(
      _storageKey,
      jsonEncode([for (final c in configs.take(2)) c.toJson()]),
    );
  } catch (_) {}
}

/// Settings section: up to two Bluetooth LED displays driven by this phone.
class BleDisplaysSection extends StatefulWidget {
  final String Function(String) t;
  const BleDisplaysSection({super.key, required this.t});
  @override
  State<BleDisplaysSection> createState() => _BleDisplaysSectionState();
}

class _BleDisplaysSectionState extends State<BleDisplaysSection> {
  late final List<LedConfig> configs = loadLedConfigs();
  String error = '';
  bool connecting = false;
  static const presets = [
    [32, 16],
    [64, 16],
    [64, 32],
    [96, 16],
    [128, 32],
    [128, 64],
    [192, 64],
  ];
  static const sample = {
    'phase': 'period_running',
    'home': {
      'short': 'HOM',
      'score': 12,
      'counters': {'team_fouls': 2},
    },
    'away': {
      'short': 'GUE',
      'score': 10,
      'counters': {'team_fouls': 3},
    },
  };

  String t(String key) => widget.t(key);

  void changed() {
    saveLedConfigs(configs);
    setState(() {});
  }

  Future<void> connect(int slot) async {
    setState(() {
      connecting = true;
      error = '';
    });
    try {
      final name = await Ble.connect(slot);
      if (configs[slot].name == 'LED') configs[slot].name = name;
      saveLedConfigs(configs);
    } catch (e) {
      // Cancelling the chooser is not an error worth showing.
      if (!'$e'.contains('NotFoundError')) error = t('ble.failed');
    }
    if (mounted) setState(() => connecting = false);
  }

  Widget number(String label, int value, ValueChanged<int> onChanged) =>
      SizedBox(
        width: 84,
        child: TextFormField(
          key: ValueKey('$label:$value'),
          initialValue: '$value',
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onFieldSubmitted: (text) {
            final parsed = int.tryParse(text.trim());
            if (parsed != null) onChanged(parsed);
          },
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          onChanged: (text) {
            final parsed = int.tryParse(text.trim());
            if (parsed != null && parsed >= 8) {
              onChanged(parsed);
            }
          },
        ),
      );

  Widget slot(int index) {
    final c = configs[index];
    final status = Ble.status(index);
    final connected = status == 'connected';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xff344154)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                connected
                    ? Icons.bluetooth_connected
                    : status == 'reconnecting'
                    ? Icons.bluetooth_searching
                    : Icons.bluetooth,
                color: connected
                    ? const Color(0xff22c55e)
                    : status == 'reconnecting'
                    ? Colors.orange
                    : Colors.grey,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  key: ValueKey('name:$index'),
                  initialValue: c.name,
                  maxLength: 40,
                  decoration: InputDecoration(
                    labelText: '${t('ble.display')} ${index + 1}',
                    counterText: '',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    c.name = value.trim().isEmpty ? 'LED' : value.trim();
                    saveLedConfigs(configs);
                  },
                ),
              ),
              const SizedBox(width: 8),
              connected || status == 'reconnecting'
                  ? OutlinedButton(
                      onPressed: () {
                        Ble.disconnect(index);
                        setState(() {});
                      },
                      child: Text(t('ble.disconnect')),
                    )
                  : FilledButton(
                      onPressed: Ble.supported && !connecting
                          ? () => connect(index)
                          : null,
                      child: Text(t('ble.connect')),
                    ),
            ],
          ),
          const SizedBox(height: 10),
          Text(t('ble.size')),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final p in presets)
                ChoiceChip(
                  label: Text('${p[0]}×${p[1]}'),
                  selected: c.width == p[0] && c.height == p[1],
                  onSelected: (_) {
                    c.width = p[0];
                    c.height = p[1];
                    changed();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              number(t('ble.width'), c.width, (v) {
                c.width = v.clamp(8, 1024);
                changed();
              }),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text('×'),
              ),
              number(t('ble.height'), c.height, (v) {
                c.height = v.clamp(8, 512);
                changed();
              }),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${c.columns} × ${c.rows} ${t('ble.characters')}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: c.content,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: t('ble.content'),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final value in ['all', 'score', 'clock'])
                DropdownMenuItem(
                  value: value,
                  child: Text(t('ble.content.$value')),
                ),
            ],
            onChanged: (value) {
              c.content = value ?? 'all';
              changed();
            },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: c.clockMode,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: t('ble.clock'),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final value in ['minute', 'second', 'none'])
                DropdownMenuItem(
                  value: value,
                  child: Text(t('ble.clock.$value')),
                ),
            ],
            onChanged: (value) {
              c.clockMode = value ?? 'minute';
              changed();
            },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: c.driver,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: t('ble.driver'),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final value in ['text', 'data'])
                DropdownMenuItem(
                  value: value,
                  child: Text(t('ble.driver.$value')),
                ),
            ],
            onChanged: (value) {
              c.driver = value ?? 'text';
              changed();
            },
          ),
          const SizedBox(height: 10),
          Text(t('ble.preview'), style: const TextStyle(fontSize: 12)),
          if (ledOverflows(c, ledLines(c, sample, '05:31', 'Q2')))
            Text(
              t('ble.too_small'),
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          const SizedBox(height: 4),
          Center(
            child: SizedBox(
              width: 280,
              child: LedPreview(
                config: c,
                lines: ledLines(c, sample, '05:31', 'Q2'),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Ble.disconnect(index);
                configs.removeAt(index);
                changed();
              },
              icon: const Icon(Icons.delete_outline),
              label: Text(t('display.remove')),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        t('ble.title'),
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(
        t(Ble.supported ? 'ble.intro' : 'ble.unsupported'),
        style: TextStyle(
          fontSize: 13,
          color: Ble.supported ? null : Colors.orange,
        ),
      ),
      const SizedBox(height: 10),
      if (error.isNotEmpty)
        Text(error, style: const TextStyle(color: Colors.orange)),
      for (var i = 0; i < configs.length; i++) slot(i),
      if (configs.length < 2)
        OutlinedButton.icon(
          onPressed: () {
            configs.add(LedConfig());
            changed();
          },
          icon: const Icon(Icons.add),
          label: Text(t('ble.add')),
        ),
    ],
  );
}
