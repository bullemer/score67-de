export async function translations(lang) {
  const response = await fetch(`/i18n/${lang === 'de' ? 'de' : 'en'}.json`);
  if (!response.ok) throw new Error('translations');
  return response.json();
}
export function preferredLanguage() {
  const explicit = new URLSearchParams(location.search).get('lang');
  let saved;
  try { saved = localStorage.getItem('score67-language'); } catch { /* OBS can disable storage. */ }
  // The server renders the URL's language (?lang=, German by default); only a
  // choice the visitor made overrides it, not the browser locale (crawlers
  // render in English and would otherwise index English text on German URLs).
  const server = typeof document !== 'undefined' ? document.documentElement.dataset.serverLang : undefined;
  const lang = explicit || saved || server || navigator.language.slice(0, 2);
  return lang === 'de' ? 'de' : 'en';
}
export function saveLanguage(lang) {
  try { localStorage.setItem('score67-language', lang); } catch { /* Optional preference. */ }
}
export function periodLabel(s, t) {
  if (s.sport === 'tennis') return s.period ? `${t['tennis.set'] || 'Set'} ${s.period}` : '';
  if (s.phase === 'shootout') return t['shootout.short'] || 'pens';
  if (s.shootout && s.phase === 'finished') return '';
  if (s.sport === 'basketball' && s.period > s.period_count) return `OT${s.period - s.period_count}`;
  if (s.period > s.period_count) return (t.extra_time || 'ET {n}').replace('{n}', s.period - s.period_count);
  if (!s.period || s.period_count === 1) return '';
  if (s.period_count === 2) return t.half.replace('{n}', s.period);
  if (s.period_count === 4) return t.quarter.replace('{n}', s.period);
  return `${s.period}/${s.period_count}`;
}
/** Shootout score of a game that went to penalties ("4:3"), else ''. */
export function shootoutScore(s) {
  const score = s.shootout?.score;
  return score ? `${score[0]}:${score[1]}` : '';
}
/** Football minute at which a period starts: extra time follows regular time
 * (2 × 45 + 2 × 15: the halves of extra time start at 90:00 and 105:00). */
export function periodStartMs(s, period, regularMin = s.period_length_min, extraMin = s.overtime_length_min || 15) {
  const regular = Math.min(Math.max(0, period - 1), s.period_count) * regularMin;
  return (regular + Math.max(0, period - 1 - s.period_count) * extraMin) * 60000;
}
export function clockText(s, now) {
  if (s.phase === 'shootout') return shootoutScore(s);
  if (s.shootout && s.phase === 'finished') return '';  // the shootout result shows instead
  if (!s.clock.enabled) return '';
  const c = s.clock;
  const elapsed = c.elapsed_ms + (c.running ? Math.max(0, now - c.started_at) : 0);
  const length = (s.period > s.period_count ? s.overtime_length_min || 5 : s.period_length_min) * 60000;
  if (c.direction === 'down') return mmss(Math.ceil(Math.max(0, length - elapsed) / 1000) * 1000);
  const start = periodStartMs(s, s.period);
  if (elapsed > length) return `${Math.round((start + length) / 60000)}+${Math.ceil((elapsed - length) / 60000)}`;
  return mmss(start + elapsed);
}
function mmss(ms) {
  const seconds = Math.floor(ms / 1000);
  return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
}

export class DelayedStates {
  constructor() { this.queue = []; this.signature = ''; this.lastReceived = -1; this.match = null; this.revision = -1; }
  push(state, due) {
    if (state.server_now < this.lastReceived) return;
    if (state.match_id === this.match && state.revision < this.revision) return;
    this.lastReceived = state.server_now;
    this.match = state.match_id; this.revision = state.revision;
    const signature = `${state.match_id}:${state.revision}`;
    if (signature === this.signature) return;
    this.signature = signature;
    this.queue.push({ state, due });
  }
  take(now) {
    let latest = null;
    // Preserve revision order even when the configured delay changes.
    while (this.queue.length && this.queue[0].due <= now) latest = this.queue.shift().state;
    return latest;
  }
}

export function eventTime(event, state, words) {
  if (event.type?.startsWith('shootout')) return words['shootout.short'] || 'pens';
  if (event.clock_ms == null || !event.period) return periodLabel({...state, phase: null, period: event.period}, words);
  if (state.sport === 'basketball') {
    const length = event.period_duration_ms ?? event.period_length_min * 60000;
    return `${periodLabel({...state, period: event.period}, words)} ${mmss(Math.ceil(Math.max(0, length - event.clock_ms) / 1000) * 1000)}`.trim();
  }
  const extra = event.period > event.period_count ? (event.period_duration_ms ?? 0) / 60000 : state.overtime_length_min;
  const start = periodStartMs({period_count: event.period_count ?? state.period_count}, event.period, event.period_length_min, extra);
  return `${Math.floor((start + event.clock_ms) / 60000) + 1}′`;
}

// European date/time in every language: "Sa., 03.10.2026 · 19:57", 24-hour clock.
const pad = value => String(value).padStart(2, '0');
export function europeanDate(when, lang, {weekday = false, year = true} = {}) {
  const day = `${pad(when.getDate())}.${pad(when.getMonth() + 1)}.${year ? when.getFullYear() : ''}`;
  if (!weekday) return day;
  const name = new Intl.DateTimeFormat(lang === 'en' ? 'en-GB' : 'de-DE', {weekday: 'short'}).format(when);
  return `${name} ${day}`;
}
export function europeanTime(when) {
  return `${pad(when.getHours())}:${pad(when.getMinutes())}`;
}

// Build time in the viewer's own time zone instead of UTC.
export function localizeVersionFooter() {
  document.querySelectorAll('.version-footer[data-built]').forEach(node => {
    const built = new Date(node.dataset.built);
    if (Number.isNaN(built.getTime())) return;
    const zone = new Intl.DateTimeFormat('de-DE', {timeZoneName: 'short'}).formatToParts(built).find(part => part.type === 'timeZoneName')?.value;
    node.textContent = `v${node.dataset.version} · ${europeanDate(built)} ${europeanTime(built)}${zone ? ` ${zone}` : ''}`;
  });
}
if (typeof document !== 'undefined') localizeVersionFooter();
