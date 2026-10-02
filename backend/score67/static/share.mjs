import {preferredLanguage, translations} from './common.mjs';
const el = id => document.getElementById(id);
function spectatorUrl() {
  const url = new URL(`/s/${encodeURIComponent(document.body.dataset.slug)}`, location.origin);
  const match = new URLSearchParams(location.search).get('match');
  if (match) url.searchParams.set('match', match);
  url.searchParams.set('lang', document.documentElement.lang || preferredLanguage());
  return url.href;
}
function overlayUrl() {
  return new URL(`/s/${encodeURIComponent(document.body.dataset.slug)}/overlay`, location.origin).href;
}
async function labels() {
  // Icon buttons: translated tooltip and screen-reader label.
  const words = await translations(document.documentElement.lang || preferredLanguage());
  document.querySelectorAll('[data-label]').forEach(node => {
    node.title = words[node.dataset.label] || '';
    node.setAttribute('aria-label', node.title);
  });
}
function links() {
  const url = spectatorUrl();
  const lang = document.documentElement.lang || preferredLanguage();
  el('take-control').href = `/s/${encodeURIComponent(document.body.dataset.slug)}/control?lang=${lang}`;
  labels();
  el('share-whatsapp').href = `https://wa.me/?text=${encodeURIComponent(url)}`;
  el('share-facebook').href = `https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(url)}`;
}
links();
new MutationObserver(links).observe(document.documentElement, {attributes:true, attributeFilter:['lang']});
el('share-copy').onclick = async () => {
  try {
    await navigator.clipboard.writeText(spectatorUrl());
    const words = await translations(document.documentElement.lang);
    el('share-status').textContent = words.copied;
  }
  catch { el('share-status').textContent = spectatorUrl(); }
};
if (navigator.share) {
  el('share-native').hidden = false;
  el('share-native').onclick = async () => {
    try { await navigator.share({title:'Score67', url:spectatorUrl()}); }
    catch (error) { if (error.name !== 'AbortError') el('share-status').textContent = spectatorUrl(); }
  };
}
// Click copies the OBS browser-source link; long-press/middle-click still opens it.
el('share-obs').onclick = async event => {
  event.preventDefault();
  try {
    await navigator.clipboard.writeText(overlayUrl());
    const words = await translations(document.documentElement.lang);
    el('share-status').textContent = `${words['share.obs_copied']}: ${overlayUrl()}`;
  } catch { el('share-status').textContent = overlayUrl(); }
};
