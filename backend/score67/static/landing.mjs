import {preferredLanguage, saveLanguage, translations} from './common.mjs';
let lang = preferredLanguage();
async function render() {
  const t = await translations(lang);
  document.documentElement.lang = lang;
  document.querySelectorAll('[data-i18n]').forEach(el => el.textContent = t[el.dataset.i18n]);
  document.querySelector('[data-i18n="create"]').href = `/new?lang=${lang}`;
  document.querySelector('[data-i18n="dashboard"]').href = `/dashboard?lang=${lang}`;
  document.querySelector('#language').textContent = lang === 'de' ? 'EN' : 'DE';
}
document.querySelector('#language').onclick = () => { lang = lang === 'de' ? 'en' : 'de'; saveLanguage(lang); render(); };
render();
