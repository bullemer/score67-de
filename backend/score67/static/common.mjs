export async function translations(lang) {
  const response = await fetch(`/i18n/${lang === 'de' ? 'de' : 'en'}.json`);
  if (!response.ok) throw new Error('translations');
  return response.json();
}
export function preferredLanguage() {
  const explicit = new URLSearchParams(location.search).get('lang');
  let saved;
  try { saved = localStorage.getItem('score67-language'); } catch { /* OBS can disable storage. */ }
  const lang = explicit || saved || navigator.language.slice(0, 2);
  return lang === 'de' ? 'de' : 'en';
}
export function saveLanguage(lang) {
  try { localStorage.setItem('score67-language', lang); } catch { /* Optional preference. */ }
}
export function periodLabel(s, t) {
  if (!s.period || s.period_count === 1) return '';
  if (s.period_count === 2) return t.half.replace('{n}', s.period);
  if (s.period_count === 4) return t.quarter.replace('{n}', s.period);
  return `${s.period}/${s.period_count}`;
}
export function clockText(s, now) {
  if (!s.clock.enabled) return '';
  const c = s.clock;
  const elapsed = c.elapsed_ms + (c.running ? Math.max(0, now - c.started_at) : 0);
  const length = s.period_length_min * 60000;
  if (c.direction === 'down') return mmss(Math.max(0, length - elapsed));
  const start = Math.max(0, s.period - 1) * length;
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
