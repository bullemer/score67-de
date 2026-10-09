// Shared by the landing, About, Features, guide and Forum pages: translations,
// language switch, navigation and links that keep the chosen language.
// The server renders each page in the URL's language (German, or ?lang=en);
// guide pages are written per language, so switching loads the other version
// instead of swapping texts in place (that mixed English menus with German text).
import {preferredLanguage, saveLanguage, translations} from './common.mjs';

function urlFor(lang) {
  const url = new URL(location.href);
  if (lang === 'de') url.searchParams.delete('lang'); else url.searchParams.set('lang', lang);
  return url.pathname + url.search + url.hash;
}

export function startSite(onRender) {
  const lang = preferredLanguage();
  const server = document.documentElement.dataset.serverLang;
  const explicit = new URLSearchParams(location.search).get('lang');
  // A language the visitor chose earlier wins over the default of a plain link.
  if (server && !explicit && lang !== server) {
    location.replace(urlFor(lang));
    return Promise.resolve();
  }
  async function render() {
    const t = await translations(lang);
    document.documentElement.lang = lang;
    document.querySelectorAll('[data-i18n]').forEach(el => {
      const text = t[el.dataset.i18n];
      if (text != null) el.textContent = text;
    });
    const suffix = lang === 'en' ? '?lang=en' : '';
    document.querySelectorAll('[data-link]').forEach(el => { el.href = `${el.dataset.link}${suffix}`; });
    document.querySelectorAll('.site-nav [data-nav]').forEach(a => {
      a.href = `/${a.dataset.nav}${suffix}`;
      if (location.pathname.startsWith(`/${a.dataset.nav}`)) a.setAttribute('aria-current', 'page');
    });
    document.querySelector('#language').textContent = lang === 'de' ? 'EN' : 'DE';
    onRender?.(t, lang);
  }
  document.querySelector('#language').onclick = () => {
    const next = lang === 'de' ? 'en' : 'de';
    saveLanguage(next);
    location.href = urlFor(next);
  };
  return render();
}

if (!document.body.classList.contains('forum-page')) startSite();

const quickstartToggle = document.querySelector('#quickstart-toggle');
if (quickstartToggle) {
  const choices = document.querySelector('#quickstart-sports');
  const status = document.querySelector('#quickstart-status');
  const buttons = [...choices.querySelectorAll('[data-quickstart-sport]')];
  quickstartToggle.addEventListener('click', () => {
    choices.hidden = !choices.hidden;
    quickstartToggle.setAttribute('aria-expanded', String(!choices.hidden));
  });
  const tennisToggle = document.querySelector('#quickstart-tennis-toggle');
  tennisToggle.addEventListener('click', () => {
    const panel = document.querySelector('#quickstart-tennis');
    panel.hidden = !panel.hidden;
    tennisToggle.setAttribute('aria-expanded', String(!panel.hidden));
  });
  for (const button of buttons) button.addEventListener('click', async () => {
    quickstartToggle.disabled = true;
    for (const choice of buttons) choice.disabled = true;
    const lang = preferredLanguage();
    const t = await translations(lang).catch(() => ({}));
    status.hidden = false;
    status.classList.remove('error');
    status.textContent = t['quickstart.creating'] || 'Creating scoreboard…';
    try {
      const response = await fetch('/api/scoreboards', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({sport: button.dataset.quickstartSport, language: lang,
          ...(button.dataset.quickstartSport === 'tennis' ? {
            tennis_category: document.querySelector('#quickstart-tennis-category').value,
            tennis_best_of: Number(document.querySelector('#quickstart-tennis-best-of').value),
            tennis_mode: document.querySelector('#quickstart-tennis-mode').value,
          } : {}),
        }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || 'network');
      try { localStorage.setItem(`score67-pin:${result.slug}`, result.pin); } catch { /* Browser storage is optional. */ }
      location.assign(`/s/${encodeURIComponent(result.slug)}/control?lang=${lang}`);
    } catch (error) {
      status.textContent = t[`error.${error.message}`] || t['error.network'] || 'No response from the server.';
      status.classList.add('error');
      quickstartToggle.disabled = false;
      for (const choice of buttons) choice.disabled = false;
    }
  });
}
