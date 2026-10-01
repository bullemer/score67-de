import {translations, preferredLanguage, saveLanguage, clockText, periodLabel, DelayedStates} from './common.mjs';
const overlay = document.body.classList.contains('overlay');
const params = new URLSearchParams(location.search);
const slug = document.body.dataset.slug;
const historyMatch = !overlay && params.get('match');
const endpoint = historyMatch ? `/api/s/${slug}/matches/${encodeURIComponent(historyMatch)}/state` : `/api/s/${slug}/state`;
const el = id => document.getElementById(id);
const queue = new DelayedStates();
let state, lang = preferredLanguage(), words = {}, socket, reconnect = 500;
let serverAt = Date.now(), receivedAt = performance.now(), online = false, pollBusy = false, lastReceived = -1;
let languageVersion = 0;
if (overlay && params.get('preview') === '1') document.body.classList.add('preview');
function delayFor(s) {
  const raw = params.has('delay') ? Number(params.get('delay')) : s.overlay.delay_ms;
  return overlay && Number.isFinite(raw) ? Math.max(0, Math.min(raw, 30000)) : 0;
}
async function setLanguage(next) {
  const version = ++languageVersion;
  const translated = await translations(next);
  if (version !== languageVersion) return;
  lang = next; words = translated;
  document.documentElement.lang = lang;
  document.querySelectorAll('[data-i18n]').forEach(e => e.textContent = words[e.dataset.i18n]);
  if (el('language')) el('language').textContent = lang === 'de' ? 'EN' : 'DE';
}
await setLanguage(lang);
if (el('language')) el('language').onclick = () => { const next = lang === 'de' ? 'en' : 'de'; saveLanguage(next); setLanguage(next); };
function receive(s, latency = 0) {
  if (s.server_now < lastReceived) return;
  lastReceived = s.server_now;
  serverAt = s.server_now + latency; receivedAt = performance.now(); online = true;
  queue.push(s, performance.now() + delayFor(s));
}
function render() {
  const next = queue.take(performance.now());
  if (next) {
    state = next;
    if (overlay && !params.has('lang') && state.language !== lang) setLanguage(state.language);
  }
  if (!state) return;
  if (!state.match_id) {
    el('scoreboard').hidden = true;
    if (el('connection')) el('connection').textContent = words.no_match;
    return;
  }
  const o = state.overlay;
  let view = o.view;
  if (view !== 'hidden' && o.auto_big && ['break', 'finished'].includes(state.phase)) view = 'score_big';
  if (params.get('view') === 'small') view = 'scoreboard';
  if (params.get('view') === 'big') view = 'score_big';
  if (!overlay) view = 'score_big';
  const small = view === 'scoreboard';
  const right = params.has('pos') ? params.get('pos') === 'tr' : o.position === 'top_right';
  el('scoreboard').hidden = view === 'hidden';
  el('scoreboard').className = `scoreboard ${small ? 'small' : 'big'} ${right ? 'right' : ''}`;
  for (const team of ['home', 'away']) {
    el(`${team}-name`).textContent = state[team][small ? 'short' : 'name'];
    el(`${team}-score`).textContent = state[team].score;
    const count = state[team].counters?.red_cards || 0;
    const cards = el(`${team}-cards`);
    cards.hidden = count === 0;
    cards.setAttribute('aria-label', `${state[team].name}: ${count} ${words.red_cards}`);
    if (cards.dataset.count !== String(count)) {
      cards.dataset.count = String(count);
      const icons = Array.from({length: Math.min(count, 5)}, () => {
        const icon = document.createElement('i');
        icon.className = 'red-card';
        icon.setAttribute('aria-hidden', 'true');
        return icon;
      });
      if (count > 5) {
        const extra = document.createElement('b');
        extra.textContent = `+${count - 5}`;
        icons.push(extra);
      }
      cards.replaceChildren(...icons);
    }
    document.querySelector(`.team.${team}`).style.borderColor = state[team].color;
  }
  el('clock').textContent = clockText(state, serverAt + performance.now() - receivedAt - delayFor(state));
  el('period').textContent = periodLabel(state, words);
  el('phase').textContent = words[state.phase === 'break' && state.period_count === 2 ? 'halftime' : state.phase] || '';
  if (el('connection')) el('connection').textContent = words[online ? 'connected' : 'offline'];
}
setInterval(render, 100);
async function poll() {
  if (pollBusy) return;
  pollBusy = true;
  const start = performance.now();
  try {
    const response = await fetch(endpoint, {cache:'no-store', signal:AbortSignal.timeout(5000)});
    if (response.status === 410) {
      state = null;
      queue.queue = [];
      el('scoreboard').hidden = true;
      if (el('connection')) el('connection').textContent = words['error.match_deleted'];
      return;
    }
    if (!response.ok) throw new Error('state');
    receive(await response.json(), (performance.now() - start) / 2);
  } catch { online = false; } finally { pollBusy = false; }
}
function connect() {
  socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws/s/${slug}`);
  socket.onopen = () => { reconnect = 500; online = true; };
  socket.onmessage = event => { try { receive(JSON.parse(event.data)); } catch { /* Keep last valid state. */ } };
  socket.onclose = () => { online = false; setTimeout(connect, reconnect); reconnect = Math.min(5000, reconnect * 2); };
  socket.onerror = () => socket.close();
}
await poll(); if (!historyMatch) connect();
setInterval(() => { if (historyMatch || socket?.readyState !== WebSocket.OPEN) poll(); }, 2000);
setInterval(poll, 15000);
