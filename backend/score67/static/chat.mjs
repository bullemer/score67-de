import {preferredLanguage, translations} from './common.mjs';
const el = id => document.getElementById(id);
const panel = el('game-chat');
const endpoint = `/api/s/${encodeURIComponent(document.body.dataset.slug)}/chat`;
let words = {}, sending = false, polling = false, version = 0, signature = '';
const t = key => words[key] || key;
try { el('chat-name').value = localStorage.getItem('score67-chat-name') || ''; } catch { /* Optional. */ }
async function translate() { words = await translations(preferredLanguage()); }
function show(data) {
  const next = JSON.stringify(data.messages);
  if (next === signature) return;
  signature = next;
  const list = el('chat-messages');
  const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 60;
  list.replaceChildren(...data.messages.map(message => {
    const row = document.createElement('p');
    const name = document.createElement('strong');
    name.textContent = message.name + (message.controller ? ` · ${t('control')}` : '');
    const body = document.createElement('span');
    body.textContent = message.text;
    row.append(name, document.createElement('br'), body);
    return row;
  }));
  if (!data.messages.length) list.textContent = t('chat.empty');
  if (atBottom) list.scrollTop = list.scrollHeight;
}
async function refresh() {
  if (polling || sending || !panel.open || document.hidden) return;
  polling = true;
  const current = version;
  try {
    await translate();
    const response = await fetch(endpoint, {cache: 'no-store', signal: AbortSignal.timeout(5000)});
    if (!response.ok) throw new Error();
    const data = await response.json();
    if (current === version) { show(data); el('chat-error').textContent = ''; }
  } catch { if (current === version) el('chat-error').textContent = t('chat.error'); }
  finally { polling = false; }
}
el('chat-form').addEventListener('submit', async event => {
  event.preventDefault();
  const name = el('chat-name').value.trim(), text = el('chat-message').value.trim();
  if (sending || !name || !text) return;
  sending = true; version++;
  el('chat-send').disabled = true;
  el('chat-message').disabled = true;
  try {
    await translate();
    const response = await fetch(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name, text}), signal: AbortSignal.timeout(10000)});
    if (!response.ok) throw new Error();
    show(await response.json());
    el('chat-message').value = '';
    el('chat-error').textContent = '';
    try { localStorage.setItem('score67-chat-name', name); } catch { /* Optional. */ }
  } catch { el('chat-error').textContent = t('chat.send_error'); }
  finally { sending = false; el('chat-send').disabled = false; el('chat-message').disabled = false; }
});
document.querySelector('.viewer-chat-link').addEventListener('click', () => { panel.open = true; refresh(); });
panel.addEventListener('toggle', refresh);
document.addEventListener('visibilitychange', refresh);
setInterval(refresh, 3000);
