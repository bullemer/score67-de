// Shared by the landing, About, Features and Forum pages: translations,
// language switch, navigation and links that keep the chosen language.
import {preferredLanguage, saveLanguage, translations} from './common.mjs';

export function startSite(onRender) {
  let lang = preferredLanguage();
  async function render() {
    const t = await translations(lang);
    document.documentElement.lang = lang;
    document.querySelectorAll('[data-i18n]').forEach(el => {
      const text = t[el.dataset.i18n];
      if (text != null) el.textContent = text;
    });
    document.querySelectorAll('[data-link]').forEach(el => { el.href = `${el.dataset.link}?lang=${lang}`; });
    document.querySelectorAll('.site-nav [data-nav]').forEach(a => {
      a.href = `/${a.dataset.nav}?lang=${lang}`;
      if (location.pathname.startsWith(`/${a.dataset.nav}`)) a.setAttribute('aria-current', 'page');
    });
    document.querySelector('#language').textContent = lang === 'de' ? 'EN' : 'DE';
    onRender?.(t, lang);
  }
  document.querySelector('#language').onclick = () => {
    lang = lang === 'de' ? 'en' : 'de';
    saveLanguage(lang);
    render();
  };
  return render();
}

if (!document.body.classList.contains('forum-page')) startSite();
