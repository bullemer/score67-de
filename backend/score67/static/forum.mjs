import {startSite} from './site.mjs';
import {europeanDate, europeanTime} from './common.mjs';

const thread = Number(document.body.dataset.thread) || null;
const $ = selector => document.querySelector(selector);
const write = $('#write'), verify = $('#verify');
let t = {}, lang = 'de', me = {mail_enabled: false, email: null}, data = null, pending = null;

try { write.elements.name.value = localStorage.getItem('score67-forum-name') || ''; } catch { /* optional */ }

const when = ms => { const d = new Date(ms); return `${europeanDate(d, lang)} · ${europeanTime(d)}`; };
function node(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;   // user text is never parsed as HTML
  return el;
}
function status(text, error = false) {
  $('#status').textContent = text || '';
  $('#status').classList.toggle('error', error);
}

function threadCard(p) {
  const card = node('a', 'forum-post forum-thread');
  card.href = `/forum/${p.id}?lang=${lang}`;
  card.append(node('h2', '', p.title), node('p', 'forum-body', p.body.length >= 240 ? `${p.body}…` : p.body));
  const replies = p.replies === 1 ? t['forum.reply_one'] : (t['forum.replies'] || '{n}').replace('{n}', p.replies);
  card.append(node('p', 'forum-meta', `${p.author} · ${when(p.published_at)} · ${replies} · ${t['forum.last'] || ''} ${when(p.last_at)}`));
  return card;
}
function postCard(p, first) {
  const card = node('article', first ? 'forum-post forum-first' : 'forum-post');
  card.append(node('p', 'forum-meta', `${p.author} · ${when(p.published_at)}`), node('p', 'forum-body', p.body));
  return card;
}

function render() {
  if (!data) return;
  const list = $('#posts');
  $('#crumb').hidden = !thread;
  $('#intro').hidden = !!thread;
  $('#title-row').hidden = !!thread;
  if (thread) {
    $('#heading').textContent = data.thread.title;
    document.title = `${data.thread.title} · Forum · Score67`;
    list.replaceChildren(postCard(data.thread, true), ...data.replies.map(p => postCard(p, false)));
  } else {
    $('#heading').textContent = t['forum.title'];
    list.replaceChildren(...(data.threads.length ? data.threads.map(threadCard) : [node('p', 'forum-note', t['forum.empty'])]));
  }
  $('#compose-title').textContent = t[thread ? 'forum.reply' : 'forum.new_thread'];
  $('#email-row').hidden = !!me.email;
  $('#signed-in').hidden = !me.email;
  $('#signed-in').textContent = me.email ? (t['forum.signed_in'] || '').replace('{email}', me.email) : '';
  const off = !me.email && !me.mail_enabled;
  $('#mail-off').hidden = !off;
  write.querySelector('button').disabled = off;
}

async function load() {
  const [content, who] = await Promise.all([
    fetch(thread ? `/api/forum/${thread}` : '/api/forum', {cache: 'no-store'}),
    fetch('/api/forum/me', {cache: 'no-store'}),
  ]);
  if (who.ok) me = await who.json();
  if (!content.ok) {
    status(t['forum.error.gone'], true);
    $('#compose').hidden = true;
    return;
  }
  data = await content.json();
  render();
}

const errors = {
  email_invalid: 'forum.error.email', forum_incomplete: 'forum.error.incomplete', forum_rate_limited: 'forum.error.rate',
  mail_disabled: 'forum.mail_off', mail_failed: 'forum.error.mail', thread_not_found: 'forum.error.gone',
  code_invalid: 'forum.error.code', code_expired: 'forum.error.expired', code_locked: 'forum.error.locked',
  post_not_found: 'forum.error.expired',
};
async function post(url, body) {
  const response = await fetch(url, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    const code = typeof result.error === 'string' && result.error !== 'invalid_request' ? result.error : (response.status === 422 ? 'forum_incomplete' : '');
    throw new Error(t[errors[code]] || t['forum.error.generic'] || 'Error');
  }
  return result;
}

function published(result) {
  write.reset();
  try { write.elements.name.value = localStorage.getItem('score67-forum-name') || ''; } catch { /* optional */ }
  verify.hidden = true;
  write.hidden = false;
  if (!thread) {
    location.href = `/forum/${result.thread_id}?lang=${lang}`;
    return;
  }
  status(t['forum.published']);
  load();
}

write.onsubmit = async event => {
  event.preventDefault();
  const f = write.elements;
  try { localStorage.setItem('score67-forum-name', f.name.value.trim()); } catch { /* optional */ }
  const body = {body: f.body.value, name: f.name.value, language: lang, website: f.website.value};
  if (thread) body.thread_id = thread; else body.title = f.title.value;
  if (!me.email) body.email = f.email.value;
  write.querySelector('button').disabled = true;
  status(t['forum.sending']);
  try {
    const result = await post('/api/forum/posts', body);
    if (result.published) { published(result); return; }
    pending = result.post_id;
    $('#verify-note').textContent = (t['forum.code_sent'] || '').replace('{email}', f.email.value.trim());
    write.hidden = true;
    verify.hidden = false;
    verify.code.focus();
    status('');
  } catch (error) {
    status(error.message, true);
  } finally {
    write.querySelector('button').disabled = false;
  }
};

verify.onsubmit = async event => {
  event.preventDefault();
  try {
    const result = await post(`/api/forum/posts/${pending}/verify`, {code: verify.code.value.trim()});
    me.email = me.email || 'ok';
    published(result);
  } catch (error) {
    status(error.message, true);
    if (error.message === t['forum.error.expired'] || error.message === t['forum.error.locked']) {
      verify.hidden = true;
      write.hidden = false;
    }
  }
};

startSite((words, language) => {
  t = words;
  lang = language;
  if (data) render(); else load();
});
