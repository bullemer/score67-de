import {preferredLanguage, translations} from './common.mjs';
import {chatAge} from './chat-time.mjs';
const el = id => document.getElementById(id);
const panel = el('game-chat');
const endpoint = `/api/s/${encodeURIComponent(document.body.dataset.slug)}/chat`;
let words = {}, sending = false, polling = false, version = 0, signature = '';
const t = key => words[key] || key;
let serverAt = Date.now(), receivedAt = performance.now();
function updateTimes() {
  const now = serverAt + performance.now() - receivedAt;
  panel.querySelectorAll('time[data-created]').forEach(time => {
    const text = chatAge(Number(time.dataset.created), now, t);
    if (time.textContent !== text) time.textContent = text;
  });
}
async function translate() { words = await translations(preferredLanguage()); }
function show(data) {
  serverAt = data.server_now ?? Date.now();
  receivedAt = performance.now();
  updateTimes();
  const next = JSON.stringify(data.messages);
  if (next === signature) return;
  signature = next;
  const list = el('chat-messages');
  const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 60;
  list.replaceChildren(...data.messages.map(message => {
    const row = document.createElement('p');
    const meta = document.createElement('small');
    const time = document.createElement('time');
    const date = new Date(message.created_at);
    time.dataset.created = String(message.created_at);
    time.setAttribute('aria-live', 'off');
    time.dateTime = date.toISOString();
    time.title = date.toLocaleString();
    meta.append(time);
    if (message.controller) meta.append(document.createTextNode(` · ${t('control')}`));
    const body = document.createElement('span');
    body.textContent = message.text;
    row.append(body, document.createElement('br'), meta);
    return row;
  }));
  updateTimes();
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
  const text = el('chat-message').value.trim();
  if (sending || !text) return;
  sending = true; version++;
  el('chat-send').disabled = true;
  el('chat-message').disabled = true;
  try {
    await translate();
    const response = await fetch(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({text}), signal: AbortSignal.timeout(10000)});
    if (!response.ok) throw new Error();
    show(await response.json());
    el('chat-message').value = '';
    el('chat-error').textContent = '';
  } catch { el('chat-error').textContent = t('chat.send_error'); }
  finally { sending = false; el('chat-send').disabled = false; el('chat-message').disabled = false; }
});
document.querySelector('.viewer-chat-link').addEventListener('click', () => { panel.open = true; refresh(); });
panel.addEventListener('toggle', refresh);
document.addEventListener('visibilitychange', refresh);
setInterval(refresh, 3000);

setInterval(() => { if (panel.open && !document.hidden) updateTimes(); }, 1000);
