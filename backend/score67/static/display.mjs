import {translations, preferredLanguage, saveLanguage, clockText, periodLabel, eventTime, DelayedStates} from './common.mjs';
const overlay = document.body.classList.contains('overlay');
const params = new URLSearchParams(location.search);
const slug = document.body.dataset.slug;
const historyMatch = !overlay && params.get('match');
// The overlay key lets OBS keep showing a private board.
const key = params.get('k');
const keyQuery = key ? `?k=${encodeURIComponent(key)}` : '';
const endpoint = (historyMatch ? `/api/s/${slug}/matches/${encodeURIComponent(historyMatch)}/state` : `/api/s/${slug}/state`) + keyQuery;
const el = id => document.getElementById(id);
const queue = new DelayedStates();
let state, lang = preferredLanguage(), words = {}, socket, reconnect = 500;
let serverAt = Date.now(), receivedAt = performance.now(), online = false, pollBusy = false, lastReceived = -1;
let languageVersion = 0, logSignature = '';
// Spectator page: simple (score only) or extended (scorers / player points).
let tickerView = 'simple';
try { tickerView = localStorage.getItem('score67-ticker-view') || 'simple'; } catch { /* optional */ }
function applyView() {
  if (overlay) return;
  const extended = tickerView === 'extended';
  document.body.classList.toggle('extended', extended);
  el('details').hidden = !extended;
  el('view-simple').setAttribute('aria-selected', String(!extended));
  el('view-extended').setAttribute('aria-selected', String(extended));
}
if (!overlay) {
  for (const mode of ['simple', 'extended']) {
    el(`view-${mode}`).onclick = () => {
      tickerView = mode;
      try { localStorage.setItem('score67-ticker-view', mode); } catch { /* optional */ }
      logSignature = '';
      applyView();
    };
  }
  applyView();
}
function node(tag, text, className) {
  const n = document.createElement(tag);
  if (text != null) n.textContent = text;
  if (className) n.className = className;
  return n;
}
function playerLabel(player) {
  return player ? [player.number ? `#${player.number}` : '', player.name].filter(Boolean).join(' ') : '';
}
function renderDetails() {
  const active = (state.events || []).filter(e => !e.cancelled && !e.corrected);
  const basketball = state.sport === 'basketball';
  el('scorers').hidden = basketball;
  el('stats').hidden = !basketball;
  if (!basketball) {
    // Football: goals in chronological order with the running score.
    const goals = active.filter(e => e.type === 'score' || e.type === 'score_adjust');
    const running = {home: 0, away: 0};
    el('scorers-empty').hidden = goals.length > 0;
    el('scorer-list').replaceChildren(...goals.map(e => {
      running[e.team] += e.points;
      const row = node('li');
      row.style.borderColor = state[e.team].color;
      const who = e.type === 'score_adjust'
        ? `${words.score_adjust} ${e.points > 0 ? '+' : ''}${e.points}`
        : playerLabel(e.player) || words['ticker.team_goal'];
      row.append(node('span', eventTime(e, state, words), 'scorer-minute'),
        node('span', `${who}${e.detail === 'penalty' ? ` (${words['console.penalty_short']})` : ''}`, 'scorer-name'),
        node('span', state[e.team].short, 'scorer-team'),
        node('strong', `${running.home}:${running.away}`, 'scorer-score'));
      return row;
    }));
    return;
  }
  // Basketball: points per player (all squad players) and team points without a player.
  const tables = ['home', 'away'].map(team => {
    const rows = new Map();
    for (const p of state[team].squad || []) rows.set(p.id, {player: p, pts: 0});
    let teamPoints = 0;
    for (const e of active) {
      if (e.team !== team || !['score', 'score_adjust'].includes(e.type)) continue;
      if (e.type === 'score' && e.player) {
        if (!rows.has(e.player.id)) rows.set(e.player.id, {player: e.player, pts: 0});
        rows.get(e.player.id).pts += e.points;
      } else teamPoints += e.points;
    }
    const sorted = [...rows.values()].sort((a, b) => b.pts - a.pts || (Number(a.player.number) || 999) - (Number(b.player.number) || 999));
    const box = node('div', null, 'team-stats');
    box.style.borderColor = state[team].color;
    box.append(node('h3', state[team].name));
    const table = node('table');
    for (const {player, pts} of sorted) {
      const tr = node('tr', null, pts ? '' : 'zero');
      tr.append(node('td', player.number ? `#${player.number}` : '', 'num'), node('td', player.name || ''), node('td', String(pts), 'pts'));
      table.append(tr);
    }
    if (teamPoints || !sorted.length) {
      const tr = node('tr', null, 'team-row');
      tr.append(node('td', '', 'num'), node('td', words['ticker.team_points']), node('td', String(teamPoints), 'pts'));
      table.append(tr);
    }
    const total = node('tr', null, 'total');
    total.append(node('td', '', 'num'), node('td', words['stats.total_short']), node('td', String(state[team].score), 'pts'));
    table.append(total);
    box.append(table);
    return box;
  });
  el('stats-body').replaceChildren(...tables);
  const periods = state.home.period_scores || [];
  const head = node('tr');
  head.append(node('th', ''));
  periods.forEach((_, i) => head.append(node('th', i >= state.period_count ? `OT${i - state.period_count + 1}` : state.period_count === 4 ? `Q${i + 1}` : `${i + 1}`)));
  const lines = ['home', 'away'].map(team => {
    const tr = node('tr');
    tr.append(node('th', state[team].short));
    (state[team].period_scores || []).forEach(v => tr.append(node('td', String(v))));
    return tr;
  });
  el('periods').replaceChildren(head, ...lines);
}
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
    if (!overlay) { el('match-events').hidden = true; el('event-list').replaceChildren(); el('details').hidden = true; logSignature = ''; }
    if (el('connection')) el('connection').textContent = words.no_match;
    return;
  }
  const venue = state.location;
  el('venue').hidden = !venue;
  el('venue-link').textContent = venue ? `${overlay ? '' : '📍 '}${venue.label || `${venue.lat.toFixed(5)}, ${venue.lng.toFixed(5)}`}` : '';
  if (venue) {
    el('venue-link').href = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${venue.lat},${venue.lng}`)}`;
    el('venue-link').title = words['location.open'];
  } else el('venue-link').removeAttribute('href');
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
    const fouls = el(`${team}-fouls`);
    fouls.hidden = state.sport !== 'basketball' || !state.team_fouls_enabled;
    fouls.textContent = `${words.team_fouls}: ${state[team].counters?.team_fouls || 0}`;
    for (const color of ['red', 'yellow']) {
    const count = state[team].counters?.[`${color}_cards`] || 0;
    const cards = el(`${team}-${color === 'red' ? 'cards' : 'yellow'}`);
    cards.hidden = count === 0;
    cards.setAttribute('aria-label', `${state[team].name}: ${count} ${words[`${color}_cards`]}`);
    if (cards.dataset.count !== String(count)) {
      cards.dataset.count = String(count);
      const icons = Array.from({length: Math.min(count, 5)}, () => {
        const icon = document.createElement('i');
        icon.className = `${color}-card`;
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
    }
    document.querySelector(`.team.${team}`).style.borderColor = state[team].color;
  }
  if (!overlay && logSignature !== `${state.match_id}:${state.revision}:${lang}`) {
    logSignature = `${state.match_id}:${state.revision}:${lang}`;
    const entries = (state.events || []).filter(e => ['score','score_adjust','red_card','yellow_card','score_correction','red_card_correction','yellow_card_correction','team_foul','team_foul_correction','timeout','timeout_correction'].includes(e.type)).slice(-30).reverse();
    el('match-events').hidden = entries.length === 0;
    el('event-list').replaceChildren(...entries.map(event => {
      const row = document.createElement('li');
      const player = event.player;
      const who = player ? [player.number ? `#${player.number}` : '', player.name].filter(Boolean).join(' ') : '';
      const minute = eventTime(event, state, words);
      const signed = `${event.points > 0 ? '+' : ''}${event.points}`;
      const label = event.type === 'score_adjust' ? `${words.score_adjust} ${signed}`
        : state.sport === 'basketball' && event.type.startsWith('score') ? signed : words[event.type];
      row.textContent = [minute, label, state[event.team].name, who, event.cancelled ? words.cancelled : event.corrected ? words['event.corrected'] : ''].filter(Boolean).join(' · ');
      if (event.cancelled || event.corrected) row.className = 'cancelled';
      return row;
    }));
    if (tickerView === 'extended') renderDetails();
  }
  el('clock').textContent = clockText(state, serverAt + performance.now() - receivedAt - delayFor(state));
  el('period').textContent = periodLabel(state, words);
  el('phase').textContent = words[state.phase === 'break' && state.period_count === 2 ? 'halftime' : state.sport === 'basketball' && state.phase === 'pre_game' ? 'basketball.ready' : state.phase] || '';
  if (el('connection')) el('connection').textContent = words[online ? 'connected' : 'offline'];
  if (!overlay) {
    el('menu-description').hidden = !state.description;
    el('menu-description').textContent = state.description || '';
    el('stream-link').hidden = !state.stream_url;
    if (state.stream_url) el('stream-link').href = state.stream_url;
    document.body.classList.toggle('offline', !online);
    // Long scores (100+) get a smaller size so both always fit.
    el('scoreboard').dataset.digits = String(Math.max(String(state.home.score).length, String(state.away.score).length));
  }
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
      if (!overlay) { el('match-events').hidden = true; el('event-list').replaceChildren(); el('details').hidden = true; logSignature = ''; }
      if (el('connection')) el('connection').textContent = words['error.match_deleted'];
      return;
    }
    if (response.status === 403) { location.reload(); return; }  // Made private: show the notice.
    if (!response.ok) throw new Error('state');
    receive(await response.json(), (performance.now() - start) / 2);
  } catch { online = false; } finally { pollBusy = false; }
}
function connect() {
  socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws/s/${slug}${keyQuery}`);
  socket.onopen = () => { reconnect = 500; online = true; };
  socket.onmessage = event => { try { receive(JSON.parse(event.data)); } catch { /* Keep last valid state. */ } };
  socket.onclose = () => { online = false; setTimeout(connect, reconnect); reconnect = Math.min(5000, reconnect * 2); };
  socket.onerror = () => socket.close();
}
await poll(); if (!historyMatch) connect();
setInterval(() => { if (historyMatch || socket?.readyState !== WebSocket.OPEN) poll(); }, 2000);
setInterval(poll, 15000);
