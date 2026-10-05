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
