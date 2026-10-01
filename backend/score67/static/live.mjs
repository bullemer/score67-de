import {preferredLanguage, saveLanguage, translations, clockText, periodLabel} from './common.mjs';
const el = id => document.getElementById(id);
let lang = preferredLanguage(), words = {}, games = [], loaded = false, online = true, busy = false;
let serverAt = Date.now(), receivedAt = performance.now(), languageVersion = 0;
function textNode(tag, value, className) {
  const node = document.createElement(tag);
  node.textContent = value;
  if (className) node.className = className;
  return node;
}
function render() {
  el('status').textContent = words[!loaded && online ? 'connecting' : online ? 'live.updating' : 'live.offline'];
  el('empty').hidden = !loaded || games.length !== 0;
  const cards = games.map(game => {
    const card = document.createElement('a');
    card.className = 'live-game';
    card.href = `/s/${encodeURIComponent(game.scoreboard)}?lang=${lang}`;
    const meta = document.createElement('div'); meta.className = 'live-meta';
    meta.append(textNode('span', words[game.phase === 'break' ? 'break' : 'live.now']));
    const clock = textNode('span', '', 'live-clock'); clock.dataset.match = game.match_id; meta.append(clock);
    card.append(meta);
    for (const side of ['home', 'away']) {
      const team = game[side];
      const row = document.createElement('div'); row.className = 'live-team'; row.style.borderColor = team.color;
      row.append(textNode('span', team.name, 'live-name'), textNode('strong', team.score, 'live-score'));
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
    if (game.location) card.append(textNode('p', game.location.label || `${game.location.lat.toFixed(5)}, ${game.location.lng.toFixed(5)}`, 'live-venue'));
    card.append(textNode('span', `${words['live.open']} →`, 'live-open'));
    return card;
  });
  // Retain keyboard focus across automatic refreshes.
  const focused = document.activeElement?.closest('.live-game')?.getAttribute('href');
  el('games').replaceChildren(...cards);
  if (focused) cards.find(card => card.getAttribute('href') === focused)?.focus({preventScroll:true});
  tick();
}
function tick() {
  const now = serverAt + performance.now() - receivedAt;
  document.querySelectorAll('.live-clock').forEach(node => {
    const game = games.find(g => g.match_id === node.dataset.match);
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
    games = data.games; serverAt = data.server_now + (performance.now() - start) / 2;
    receivedAt = performance.now(); loaded = true; online = true;
  } catch { online = false; }
  finally { busy = false; render(); }
}
el('language').onclick = () => { const next = lang === 'de' ? 'en' : 'de'; saveLanguage(next); setLanguage(next); };
await setLanguage(lang);
await poll();
setInterval(poll, 5000);
setInterval(tick, 250);
