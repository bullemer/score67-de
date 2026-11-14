import {preferredLanguage, translations} from './common.mjs';

const bar = document.createElement('nav');
bar.className = 'active-games';
bar.hidden = true;
document.body.prepend(bar);
new ResizeObserver(() => {
  document.documentElement.style.setProperty('--active-games-height', `${bar.getBoundingClientRect().height}px`);
}).observe(bar);
let loading = false;
async function refresh() {
  if (loading || document.hidden) return;
  loading = true;
  try {
    const response = await fetch('/api/active-games', {cache: 'no-store'});
    if (!response.ok) return;
    const {games} = await response.json();
    const lang = preferredLanguage();
    const words = await translations(lang);
    bar.setAttribute('aria-label', words['resume.controller']);
    bar.replaceChildren(...games.map(game => {
      const link = document.createElement('a');
      link.href = `/s/${encodeURIComponent(game.slug)}/control?lang=${lang}`;
      link.textContent = `${words['resume.controller']}: ${game.home} – ${game.away}`;
      return link;
    }));
    bar.hidden = games.length === 0;
    const quickstart = document.querySelector('#quickstart-toggle');
    if (quickstart) {
      if (games.length) {
        quickstart.disabled = true;
        quickstart.dataset.activeBoardBlocked = 'true';
      } else if (quickstart.dataset.activeBoardBlocked) {
        quickstart.disabled = false;
        delete quickstart.dataset.activeBoardBlocked;
      }
      quickstart.title = games.length ? words['error.active_scoreboard_exists'] : '';
      const status = document.querySelector('#quickstart-status');
      if (games.length) {
        status.textContent = words['error.active_scoreboard_exists'];
        status.hidden = false;
      } else if (status.textContent === words['error.active_scoreboard_exists']) {
        status.hidden = true;
      }
    }
  } catch { /* Keep navigation usable during a temporary connection failure. */ }
  finally { loading = false; }
}
refresh();
setInterval(refresh, 5000);
window.addEventListener('pageshow', refresh);
window.addEventListener('focus', refresh);
document.addEventListener('visibilitychange', refresh);
