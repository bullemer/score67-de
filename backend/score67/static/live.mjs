import {preferredLanguage, saveLanguage, translations, clockText, periodLabel, europeanDate, europeanTime} from './common.mjs';
const el = id => document.getElementById(id);
let lang = preferredLanguage(), words = {}, games = [], upcoming = [], finished = [], loaded = false, online = true, busy = false;
let tab = location.hash === '#upcoming' ? 'upcoming' : 'live';
let serverAt = Date.now(), receivedAt = performance.now(), languageVersion = 0;
function textNode(tag, value, className) {
  const node = document.createElement(tag);
  node.textContent = value;
  if (className) node.className = className;
  return node;
}
// Cards are clickable panels (not links) so the livestream can be its own link.
function cardShell(href, extraClass = '') {
  const card = document.createElement('article');
  card.className = `live-game ${extraClass}`.trim();
  card.dataset.href = href;
  card.tabIndex = 0;
  card.setAttribute('role', 'link');
  card.onclick = event => { if (!event.target.closest('a')) location.href = href; };
  card.onkeydown = event => { if (event.key === 'Enter' && event.target === card) location.href = href; };
  return card;
}
function extras(card, game) {
  if (game.description) card.append(textNode('p', game.description, 'live-description'));
  if (game.creator) card.append(textNode('p', (words['creator.by'] || '{name}').replace('{name}', game.creator), 'live-creator'));
  if (game.location) card.append(textNode('p', `📍 ${game.location.label || `${game.location.lat.toFixed(5)}, ${game.location.lng.toFixed(5)}`}`, 'live-venue'));
  const actions = document.createElement('div'); actions.className = 'live-actions';
  const open = textNode('a', `${words['live.open']} →`, 'live-open'); open.href = card.dataset.href;
  actions.append(open);
  if (game.stream_url) {
    const stream = textNode('a', `▶ ${words['stream.watch']}`, 'live-stream');
    stream.href = game.stream_url; stream.target = '_blank'; stream.rel = 'noopener noreferrer';
    actions.append(stream);
  }
  card.append(actions);
}
function upcomingCard(game) {
  const card = cardShell(`/s/${encodeURIComponent(game.scoreboard)}?${game.active ? '' : `match=${encodeURIComponent(game.match_id)}&`}lang=${lang}`, 'upcoming');
  const when = new Date(game.scheduled_at);
  const day = europeanDate(when, lang, {weekday: true, year: false});
  const time = europeanTime(when);
  const meta = document.createElement('div'); meta.className = 'live-meta';
  meta.append(textNode('span', `${words[game.sport || 'football']} · ${game.sport === 'tennis' ? words[`tennis.best_of_${game.tennis?.best_of || game.period_count}`] : `${game.period_count} × ${game.period_length_min} min`}`), textNode('span', `${day} · ${time}`, 'live-when'));
  card.append(meta);
  for (const side of ['home', 'away']) {
    const row = document.createElement('div'); row.className = 'live-team'; row.style.borderColor = game[side].color;
    const name = textNode('span', game[side].name, 'live-name');
    if (game[side].logo) { const img = document.createElement('img'); img.src = game[side].logo; img.alt = ''; img.className = 'live-logo'; name.prepend(img); }
    row.append(name);
    card.append(row);
  }
  extras(card, game);
  return card;
}
// Ended games stay listed for a few hours with the final score.
function finishedCard(game) {
  const card = cardShell(`/s/${encodeURIComponent(game.scoreboard)}?${game.active ? '' : `match=${encodeURIComponent(game.match_id)}&`}lang=${lang}`, 'finished');
  const meta = document.createElement('div'); meta.className = 'live-meta';
  const ended = new Date(game.ended_at);
  meta.append(textNode('span', `${words[game.sport || 'football']} · ${words['live.final']}`, 'live-final'),
    textNode('span', (words['live.ended_at'] || '{time}').replace('{time}', europeanTime(ended))));
  card.append(meta);
  for (const side of ['home', 'away']) {
    const team = game[side];
    const row = document.createElement('div'); row.className = 'live-team'; row.style.borderColor = team.color;
    const name = textNode('span', team.name, 'live-name');
    if (team.logo) { const img = document.createElement('img'); img.src = team.logo; img.alt = ''; img.className = 'live-logo'; name.prepend(img); }
    row.append(name, textNode('strong', team.score, 'live-score'));
    card.append(row);
  }
  if (game.automatic) card.append(textNode('p', words['live.auto_ended'], 'live-auto'));
  extras(card, game);
  return card;
}
function render() {
  el('status').textContent = words[!loaded && online ? 'connecting' : online ? 'live.updating' : 'live.offline'];
  el('tab-live').textContent = `${words['live.tab_live'] || 'Live'} (${games.length})`;
  el('tab-upcoming').textContent = `${words['live.tab_upcoming'] || 'Upcoming'} (${upcoming.length})`;
  el('tab-live').setAttribute('aria-selected', tab === 'live');
  el('tab-upcoming').setAttribute('aria-selected', tab === 'upcoming');
  el('intro').textContent = words[tab === 'live' ? 'live.description' : 'live.upcoming_description'] || '';
  el('games').hidden = tab !== 'live';
  el('upcoming').hidden = tab !== 'upcoming';
  el('empty').hidden = tab !== 'live' || !loaded || games.length !== 0;
  el('finished-section').hidden = tab !== 'live' || finished.length === 0;
  el('finished').replaceChildren(...finished.map(finishedCard));
  el('empty-upcoming').hidden = tab !== 'upcoming' || !loaded || upcoming.length !== 0;
  el('upcoming').replaceChildren(...upcoming.map(upcomingCard));
  const cards = games.map(game => {
    const card = cardShell(`/s/${encodeURIComponent(game.scoreboard)}?lang=${lang}`);
    const meta = document.createElement('div'); meta.className = 'live-meta';
    meta.append(textNode('span', `${words[game.sport || 'football']} · ${words[game.phase === 'break' ? 'break' : 'live.now']}`));
    const clock = textNode('span', '', 'live-clock'); clock.dataset.match = game.match_id; meta.append(clock);
    card.append(meta);
    for (const side of ['home', 'away']) {
      const team = game[side];
      const row = document.createElement('div'); row.className = 'live-team'; row.style.borderColor = team.color;
      const name = textNode('span', team.name, 'live-name');
      if (team.logo) { const img = document.createElement('img'); img.src = team.logo; img.alt = ''; img.className = 'live-logo'; name.prepend(img); }
      row.append(name, textNode('strong', team.score, 'live-score'));
      for (const color of ['red','yellow']) {
      const count = team.counters?.[`${color}_cards`] || 0;
      if (count) {
        const reds = document.createElement('div'); reds.className = 'live-cards'; reds.setAttribute('role', 'img');
        reds.setAttribute('aria-label', `${count} ${words[`${color}_cards`]}`);
        for (let i = 0; i < Math.min(count, 5); i++) {
          const icon = document.createElement('i'); icon.className = `${color}-card`; icon.setAttribute('aria-hidden', 'true'); reds.append(icon);
        }
        if (count > 5) reds.append(textNode('b', `+${count - 5}`));
        row.append(reds);
      }
      }
      card.append(row);
    }
    extras(card, game);
    return card;
  });
  // Retain keyboard focus across automatic refreshes.
  const focused = document.activeElement?.closest('.live-game')?.dataset.href;
  el('games').replaceChildren(...cards);
  if (focused) cards.find(card => card.dataset.href === focused)?.focus({preventScroll:true});
  tick();
}
function tick() {
  const now = serverAt + performance.now() - receivedAt;
  document.querySelectorAll('.live-clock').forEach(node => {
    const game = games.find(g => g.match_id === node.dataset.match);
    if (!game) return;
    node.textContent = [periodLabel(game, words), clockText(game, now)].filter(Boolean).join(' · ');
  });
}
async function setLanguage(next) {
  const version = ++languageVersion;
  try {
    const translated = await translations(next);
    if (version !== languageVersion) return;
    lang = next; words = translated;
    document.documentElement.lang = lang;
    document.title = `${words['live.title']} · Score67`;
    document.querySelectorAll('[data-i18n]').forEach(node => node.textContent = words[node.dataset.i18n]);
    el('language').textContent = lang === 'de' ? 'EN' : 'DE';
    el('dashboard-link').href = `/dashboard?lang=${lang}`;
    render();
  } catch { el('status').textContent = 'Verbindung fehlgeschlagen / Connection failed'; }
}
async function poll() {
  if (busy) return;
  busy = true;
  const start = performance.now();
  try {
    const response = await fetch('/api/live', {cache:'no-store', signal:AbortSignal.timeout(5000)});
    if (!response.ok) throw new Error('live');
    const data = await response.json();
    games = data.games; upcoming = data.upcoming || []; finished = data.finished || []; serverAt = data.server_now + (performance.now() - start) / 2;
    receivedAt = performance.now(); loaded = true; online = true;
  } catch { online = false; }
  finally { busy = false; render(); }
}
for (const name of ['live', 'upcoming']) {
  el(`tab-${name}`).onclick = () => {
    tab = name;
    history.replaceState(null, '', name === 'upcoming' ? '#upcoming' : location.pathname + location.search);
    render();
  };
}
el('language').onclick = () => { const next = lang === 'de' ? 'en' : 'de'; saveLanguage(next); setLanguage(next); };
await setLanguage(lang);
await poll();
setInterval(poll, 5000);
setInterval(tick, 250);
