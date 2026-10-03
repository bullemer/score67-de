/// European date and time in every language: "Sa., 03.10.2026 · 19:57"
/// (day.month.year, 24-hour clock, week starting Monday).
library;

const _weekdays = {
  'de': ['Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.', 'So.'],
  'en': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
};

String _two(int value) => value.toString().padLeft(2, '0');

String europeanDate(DateTime value) =>
    '${_two(value.day)}.${_two(value.month)}.${value.year}';

String europeanTime(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}';

String europeanDateTime(DateTime value, String lang) =>
    '${(_weekdays[lang] ?? _weekdays['en']!)[value.weekday - 1]} '
    '${europeanDate(value)} · ${europeanTime(value)}';
