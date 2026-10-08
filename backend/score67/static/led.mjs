// LED preview: draws a game exactly as a Score67 LED panel (64 × 32 pixels)
// would, from the compact feed (docs/DISPLAY-API.md). Layout and bitmap
// fonts here are the reference for the ESP32 firmware (docs/DISPLAY-FIRMWARE.md):
//   top    y 1–5    home / guest short names (3×5), possession arrow, red cards
//   middle y 8–21   score in 10×14 digits (8×14 from 100 points), colon
//   bottom y 24–30  clock in 5×7 digits; period (left) and team fouls (right) in 3×5
export const WIDTH = 64, HEIGHT = 32;

// 3×5 font: five rows of three bits (MSB = left).
const SMALL = {
  '0': [7, 5, 5, 5, 7], '1': [2, 6, 2, 2, 7], '2': [7, 1, 7, 4, 7], '3': [7, 1, 7, 1, 7], '4': [5, 5, 7, 1, 1],
  '5': [7, 4, 7, 1, 7], '6': [7, 4, 7, 5, 7], '7': [7, 1, 2, 2, 2], '8': [7, 5, 7, 5, 7], '9': [7, 5, 7, 1, 7],
  A: [2, 5, 7, 5, 5], B: [6, 5, 6, 5, 6], C: [3, 4, 4, 4, 3], D: [6, 5, 5, 5, 6], E: [7, 4, 6, 4, 7],
  F: [7, 4, 6, 4, 4], G: [3, 4, 5, 5, 3], H: [5, 5, 7, 5, 5], I: [7, 2, 2, 2, 7], J: [1, 1, 1, 5, 2],
  K: [5, 5, 6, 5, 5], L: [4, 4, 4, 4, 7], M: [5, 7, 7, 5, 5], N: [6, 5, 5, 5, 5], O: [2, 5, 5, 5, 2],
  P: [6, 5, 6, 4, 4], Q: [2, 5, 5, 6, 3], R: [6, 5, 6, 5, 5], S: [3, 4, 2, 1, 6], T: [7, 2, 2, 2, 2],
  U: [5, 5, 5, 5, 7], V: [5, 5, 5, 5, 2], W: [5, 5, 7, 7, 5], X: [5, 5, 2, 5, 5], Y: [5, 5, 2, 2, 2],
  Z: [7, 1, 2, 4, 7], '/': [1, 1, 2, 4, 4], ':': [0, 2, 0, 2, 0], '-': [0, 0, 7, 0, 0], '.': [0, 0, 0, 0, 2],
  '<': [1, 2, 4, 2, 1], '>': [4, 2, 1, 2, 4], '+': [0, 2, 7, 2, 0], ' ': [0, 0, 0, 0, 0],
  '!': [2, 2, 2, 0, 2], '?': [6, 1, 2, 0, 2], ',': [0, 0, 0, 2, 4], "'": [2, 2, 0, 0, 0], '=': [0, 7, 0, 7, 0],
  '#': [5, 7, 5, 7, 5], '(': [1, 2, 2, 2, 1], ')': [4, 2, 2, 2, 4], '*': [5, 2, 7, 2, 5],
};
// 5×7 digits (clock), and 4×7 digits for the narrow score font; doubled for the score.
const CLOCK = {
  '0': [14, 17, 19, 21, 25, 17, 14], '1': [4, 12, 4, 4, 4, 4, 14], '2': [14, 17, 1, 2, 4, 8, 31],
  '3': [31, 2, 4, 2, 1, 17, 14], '4': [2, 6, 10, 18, 31, 2, 2], '5': [31, 16, 30, 1, 1, 17, 14],
  '6': [6, 8, 16, 30, 17, 17, 14], '7': [31, 1, 2, 4, 8, 8, 8], '8': [14, 17, 17, 14, 17, 17, 14],
  '9': [14, 17, 17, 15, 1, 2, 12],
};
const NARROW = {
  '0': [6, 9, 9, 9, 9, 9, 6], '1': [2, 6, 2, 2, 2, 2, 7], '2': [6, 9, 1, 2, 4, 8, 15], '3': [15, 1, 2, 1, 1, 9, 6],
  '4': [2, 6, 10, 10, 15, 2, 2], '5': [15, 8, 14, 1, 1, 9, 6], '6': [6, 8, 8, 14, 9, 9, 6], '7': [15, 1, 2, 2, 4, 4, 4],
  '8': [6, 9, 9, 6, 9, 9, 6], '9': [6, 9, 9, 7, 1, 1, 6],
};
// 12×12 message icons; letters are colours (ICON_COLORS), '.' is off.
const ICONS = {
  heart: [
    '............', '..rr....rr..', '.rrrr..rrrr.', 'rrwrrrrrrrrr', 'rwrrrrrrrrrr', 'rrrrrrrrrrrr',
    '.rrrrrrrrrr.', '..rrrrrrrr..', '...rrrrrr...', '....rrrr....', '.....rr.....', '............'],
  star: [
    '.....yy.....', '.....yy.....', '....yyyy....', '....yyyy....', 'yyyyyyyyyyyy', '.yyyyyyyyyy.',
    '..yyyyyyyy..', '...yyyyyy...', '..yyyyyyyy..', '..yyy..yyy..', '.yyy....yyy.', '.yy......yy.'],
  basketball: [
    '....oono....', '..onoonoon..', '.onooonooon.', '.onooonooon.', 'oonooonooono', 'nnnnnnnnnnnn',
    'oonooonooono', 'oonooonooono', '.onooonooon.', '.onooonooon.', '..onoonoon..', '....oono....'],
  football: [
    '....wddw....', '..wwwddwww..', '.wwwwwwwwww.', '.wwwwwwwwww.', 'wwwwwddwwwww', 'dwwwddddwwwd',
    'dwwwddddwwwd', 'wwwwwddwwwww', '.wwwwwwwwww.', '.wwwwwwwwww.', '..ddwwwwdd..', '....wwww....'],
  trophy: [
    '.yyyyyyyyyy.', 'y.yyyyyyyy.y', 'y.yyyyyyyy.y', 'y.yyyyyyyy.y', '.yyyyyyyyyy.', '...yyyyyy...',
    '....yyyy....', '.....yy.....', '.....yy.....', '....yyyy....', '...oooooo...', '...oooooo...'],
  flame: [
    '.....r......', '....rr......', '....rrr.....', '...rrrr..r..', '...rrorr.rr.', '..rrroorrrr.',
    '.rrrooorrrr.', '.rroooyoorr.', '.rrooyyyorr.', '.rooyyyyoor.', '..roowyyor..', '...rrooor...'],
};
// n and d are dim: seams and patches stay visible without holes in the shape.
const ICON_COLORS = {r: '#ef4444', o: '#f97316', y: '#facc15', w: '#ffffff', g: '#22c55e', b: '#3b82f6', n: '#5a1e06', d: '#555b66'};
const COLORS = {score: '#ffa31a', running: '#34d399', stopped: '#facc15', text: '#e5e7eb', dim: '#9ca3af', red: '#ef4444'};

const rgb = hex => {
  const n = parseInt((hex || '#ffffff').slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
// LEDs cannot show dark colours: team colours too dark to read become white.
function readable(hex) {
  // An LED shows any saturated colour; only near-black (all channels low) disappears.
  const [r, g, b] = rgb(hex);
  return Math.max(r, g, b) < 90 ? '#ffffff' : hex;
}

export class Frame {
  constructor() { this.pixels = new Array(WIDTH * HEIGHT).fill(null); }
  set(x, y, color) { if (x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT) this.pixels[y * WIDTH + x] = color; }
  glyph(rows, width, x, y, color, scale = 1) {
    rows.forEach((bits, row) => {
      for (let col = 0; col < width; col++) {
        if (bits & (1 << (width - 1 - col))) {
          for (let dy = 0; dy < scale; dy++) for (let dx = 0; dx < scale; dx++) this.set(x + col * scale + dx, y + row * scale + dy, color);
        }
      }
    });
  }
  // 3×5 text; returns the width drawn.
  text(value, x, y, color) {
    let cx = x;
    for (const ch of String(value).toUpperCase().replaceAll('Ä', 'A').replaceAll('Ö', 'O').replaceAll('Ü', 'U')) {
      this.glyph(SMALL[ch] || SMALL[' '], 3, cx, y, color);
      cx += 4;
    }
    return Math.max(0, cx - x - 1);
  }
  // 3×5 text doubled (6×10, 8 px per character); colour may be a function of the index.
  big(value, x, y, color) {
    [...String(value)].forEach((ch, i) => {
      this.glyph(SMALL[ch] || SMALL[' '], 3, x + i * 8, y, typeof color === 'function' ? color(i) : color, 2);
    });
  }
  // A multi-colour icon (rows of letters, '.' = off), optionally scaled.
  icon(name, x, y, scale = 1) {
    (ICONS[name] || []).forEach((row, ry) => [...row].forEach((ch, rx) => {
      const color = ICON_COLORS[ch];
      if (!color) return;
      for (let dy = 0; dy < scale; dy++) for (let dx = 0; dx < scale; dx++) this.set(x + rx * scale + dx, y + ry * scale + dy, color);
    }));
  }
}

export const textWidth = value => Math.max(0, String(value).length * 4 - 1);

function clockText(ms, down) {
  if (down && ms < 60000) return `${Math.floor(ms / 1000)}.${Math.floor((ms % 1000) / 100)}`;
  const seconds = Math.floor(ms / 1000);
  return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}

function drawClock(frame, value, y, color) {
  // 5×7 digits, 1 px apart; colon and dot are 1 px wide.
  const width = [...value].reduce((w, ch) => w + (/\d/.test(ch) ? 6 : 2), -1);
  let x = Math.round((WIDTH - width) / 2);
  for (const ch of value) {
    if (/\d/.test(ch)) { frame.glyph(CLOCK[ch], 5, x, y, color); x += 6; }
    else if (ch === ':') { frame.set(x, y + 2, color); frame.set(x, y + 4, color); x += 2; }
    else { frame.set(x, y + 6, color); x += 2; }
  }
}

function drawScore(frame, value, rightEdge, leftStart, narrow) {
  const digits = String(value), w = narrow ? 8 : 10, gap = narrow ? 1 : 2, font = narrow ? NARROW : CLOCK;
  const width = digits.length * w + (digits.length - 1) * gap;
  let x = rightEdge !== null ? rightEdge - width + 1 : leftStart;
  for (const ch of digits) { frame.glyph(font[ch], narrow ? 4 : 5, x, 8, COLORS.score, 2); x += w + gap; }
}

/** The panel image for a compact-feed message at local time `now` (ms since it arrived). */
export function render(feed, sinceMs = 0, {lang = 'de'} = {}) {
  const frame = new Frame();
  if (!feed) return frame;
  if (feed.mode === 'pairing') {
    frame.text('CODE', Math.round((WIDTH - textWidth('CODE')) / 2), 4, COLORS.dim);
    frame.text(feed.code || '', Math.round((WIDTH - textWidth(feed.code || '')) / 2), 16, COLORS.text);
    return frame;
  }
  if (feed.mode === 'game' && feed.msg && sinceMs < (feed.msg.ms ?? 0)) {
    renderMessage(frame, feed.msg, sinceMs);
    return frame;
  }
  if (feed.mode !== 'game') {
    frame.text('SCORE67', Math.round((WIDTH - textWidth('SCORE67')) / 2), 13, COLORS.dim);
    return frame;
  }
  const home = feed.home || {}, guest = feed.guest || {};
  // Top: short names, red cards (football), possession arrow (basketball).
  const homeColor = readable(home.color), guestColor = readable(guest.color);
  const hw = frame.text(home.short || '', 1, 1, homeColor);
  const guestShort = guest.short || '';
  const gx = WIDTH - 1 - textWidth(guestShort);
  frame.text(guestShort, gx, 1, guestColor);
  for (let i = 0; i < Math.min(home.red_cards || 0, 3); i++) frame.glyph([1, 1, 1], 1, 2 + hw + i * 2, 2, COLORS.red);
  for (let i = 0; i < Math.min(guest.red_cards || 0, 3); i++) frame.glyph([1, 1, 1], 1, gx - 3 - i * 2, 2, COLORS.red);
  if (feed.possession === 'home') frame.text('<', 30, 1, COLORS.text);
  if (feed.possession === 'away') frame.text('>', 31, 1, COLORS.text);
  // Middle: the score, colon at x 31–32.
  const narrow = (home.score || 0) >= 100 || (guest.score || 0) >= 100;
  drawScore(frame, home.score || 0, narrow ? 29 : 28, null, narrow);
  drawScore(frame, guest.score || 0, null, narrow ? 34 : 35, narrow);
  for (const y of [11, 12, 17, 18]) { frame.set(31, y, COLORS.score); frame.set(32, y, COLORS.score); }
  // Bottom: clock, period, team fouls.
  const clock = feed.clock || {};
  if (clock.visible) {
    let ms = clock.ms;
    if (clock.running) ms = clock.direction === 'down' ? Math.max(0, ms - sinceMs) : ms + sinceMs;
    drawClock(frame, clockText(ms, clock.direction === 'down'), 24, clock.running ? COLORS.running : COLORS.stopped);
  } else if (feed.phase === 'finished') {
    const word = lang === 'de' ? 'ENDE' : 'FINAL';
    frame.text(word, Math.round((WIDTH - textWidth(word)) / 2), 25, COLORS.stopped);
  }
  if (feed.period && feed.phase !== 'finished') frame.text(feed.period, 1, 26, COLORS.dim);
  if (home.fouls != null && guest.fouls != null) {
    const fouls = `${home.fouls}-${guest.fouls}`;
    frame.text(fouls, WIDTH - 1 - textWidth(fouls), 26, COLORS.dim);
  }
  if (feed.identify && Math.floor(sinceMs / 400) % 2 === 0) {
    for (let x = 0; x < WIDTH; x++) { frame.set(x, 0, COLORS.text); frame.set(x, HEIGHT - 1, COLORS.text); }
    for (let y = 0; y < HEIGHT; y++) { frame.set(0, y, COLORS.text); frame.set(WIDTH - 1, y, COLORS.text); }
  }
  return frame;
}

const SCROLL_PX_PER_S = 24, BIG_CHARS = Math.floor((WIDTH + 2) / 8);   // 8 on 64 px

/** Words into lines of at most `max` characters; null when a word is longer. */
export function wrap(text, max = BIG_CHARS) {
  const lines = [];
  for (const word of String(text).split(' ').filter(Boolean)) {
    if (word.length > max) return null;
    const last = lines.length ? lines[lines.length - 1] : null;
    if (last !== null && last.length + 1 + word.length <= max) lines[lines.length - 1] = `${last} ${word}`;
    else lines.push(word);
  }
  return lines;
}

const hue = h => {
  const f = n => { const k = (n + h / 60) % 6; return Math.round(255 * (1 - Math.max(0, Math.min(k, 4 - k, 1)))); };
  return `#${[f(5), f(3), f(1)].map(v => v.toString(16).padStart(2, '0')).join('')}`;
};

/** A message (feed.msg) instead of the score: text with icon, or a small chart. */
function renderMessage(frame, msg, sinceMs) {
  if (msg.kind === 'periods') return drawPeriods(frame, msg);
  if (msg.kind === 'lead') return drawLead(frame, msg);
  if (msg.effect === 'blink' && Math.floor(sinceMs / 500) % 2 === 1) return;
  const color = msg.effect === 'rainbow' ? i => hue((sinceMs / 8 + i * 45) % 360) : (msg.color || COLORS.score);
  const text = msg.text || '';
  if (!text) { frame.icon(msg.icon, 20, 4, 2); return; }
  const lines = wrap(text);
  const scroll = (y) => {
    const width = text.length * 8 - 2, period = width + WIDTH;
    frame.big(text, WIDTH - Math.floor(sinceMs * SCROLL_PX_PER_S / 1000) % period, y, color);
  };
  if (msg.icon) {
    frame.icon(msg.icon, 26, 1);
    if (lines && lines.length === 1) frame.big(lines[0], Math.round((WIDTH - (lines[0].length * 8 - 2)) / 2), 19, color);
    else scroll(19);
    return;
  }
  if (lines && lines.length <= 2) {
    const top = lines.length === 1 ? 11 : 4;
    lines.forEach((line, i) => frame.big(line, Math.round((WIDTH - (line.length * 8 - 2)) / 2), top + i * 14, color));
  } else scroll(11);
}

function chartHeader(frame, msg) {
  const home = msg.home || {}, guest = msg.guest || {};
  frame.text(home.short || '', 1, 1, readable(home.color));
  frame.text(guest.short || '', WIDTH - 1 - textWidth(guest.short || ''), 1, readable(guest.color));
}

/** Points per period: a pair of bars per period (home left, guest right), number below. */
function drawPeriods(frame, msg) {
  chartHeader(frame, msg);
  const periods = (msg.periods || []).slice(-8);
  if (!periods.length) return;
  const top = 8, bottom = 24, slot = Math.floor(WIDTH / periods.length);
  const max = Math.max(1, ...periods.flat());
  const home = readable(msg.home?.color), guest = readable(msg.guest?.color);
  const width = Math.max(1, Math.min(3, Math.floor((slot - 2) / 2)));
  periods.forEach(([h, g], i) => {
    const x = i * slot + Math.floor((slot - 2 * width - 1) / 2);
    for (const [value, bx, color] of [[h, x, home], [g, x + width + 1, guest]]) {
      const height = value ? Math.max(1, Math.round((bottom - top) * value / max)) : 0;
      for (let y = bottom - height; y < bottom; y++) for (let dx = 0; dx < width; dx++) frame.set(bx + dx, y, color);
    }
    const label = String(i + 1);
    frame.text(label, i * slot + Math.floor((slot - textWidth(label)) / 2), 26, COLORS.dim);
  });
}

/** The lead over the game: columns up (home ahead) or down (guest ahead) from a middle line. */
function drawLead(frame, msg) {
  chartHeader(frame, msg);
  const lead = msg.lead || [];
  const axis = 19, reach = 11;
  const max = Math.max(1, ...lead.map(Math.abs));
  const home = readable(msg.home?.color), guest = readable(msg.guest?.color);
  for (let x = 0; x < WIDTH; x++) frame.set(x, axis, COLORS.dim);
  lead.forEach((value, i) => {
    const x = 1 + i, height = Math.round(reach * Math.abs(value) / max);
    for (let d = 1; d <= height; d++) frame.set(x, value > 0 ? axis - d : axis + d, value > 0 ? home : guest);
  });
}

/** Draws a frame as round LEDs (unlit ones dark grey) onto a canvas. */
export function paint(canvas, frame, {brightness = 100, offline = false} = {}) {
  const ratio = window.devicePixelRatio || 1;
  const cssWidth = canvas.clientWidth || 640;
  const pitch = cssWidth / WIDTH;
  canvas.width = Math.round(cssWidth * ratio);
  canvas.height = Math.round(pitch * HEIGHT * ratio);
  const ctx = canvas.getContext('2d');
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.fillStyle = '#07090c';
  ctx.fillRect(0, 0, cssWidth, pitch * HEIGHT);
  const radius = pitch * 0.38, level = Math.max(0.25, brightness / 100);
  for (let y = 0; y < HEIGHT; y++) {
    for (let x = 0; x < WIDTH; x++) {
      const color = frame.pixels[y * WIDTH + x];
      ctx.beginPath();
      ctx.arc((x + 0.5) * pitch, (y + 0.5) * pitch, radius, 0, Math.PI * 2);
      if (color) {
        const [r, g, b] = rgb(color);
        ctx.fillStyle = `rgb(${Math.round(r * level)},${Math.round(g * level)},${Math.round(b * level)})`;
        ctx.shadowColor = color; ctx.shadowBlur = pitch * 0.6 * level;
      } else {
        ctx.fillStyle = '#1b1f26'; ctx.shadowBlur = 0;
      }
      ctx.fill();
    }
  }
  ctx.shadowBlur = 0;
  if (offline) { ctx.fillStyle = COLORS.red; ctx.beginPath(); ctx.arc((WIDTH - 1.5) * pitch, 1.5 * pitch, radius, 0, Math.PI * 2); ctx.fill(); }
}

/** A demo game for pages without a live game (build guide). */
export function demoFeed(startedAt) {
  const t = (performance.now() - startedAt) / 1000;
  const step = Math.floor(t / 4);
  const home = 34 + [0, 2, 2, 3, 5, 5, 7, 8][step % 8] + 8 * Math.floor(step / 8);
  const guest = 32 + [0, 0, 3, 3, 3, 5, 5, 7][step % 8] + 7 * Math.floor(step / 8);
  return {
    v: 1, mode: 'game', sport: 'basketball', phase: 'period_running', period: 'Q3', brightness: 100,
    home: {short: 'HOM', score: home, color: '#ffffff', fouls: 2 + (step % 3)},
    guest: {short: 'GUE', score: guest, color: '#ffffff', fouls: 1 + (step % 4)},
    possession: step % 2 ? 'home' : 'away',
    clock: {visible: true, running: true, direction: 'down', ms: Math.max(0, 600000 - Math.round(t * 1000) % 600000)},
  };
}

// Pages: <canvas data-led-demo> animates the demo game; <canvas data-led-slug="…"> follows a live game.
async function start() {
  const lang = document.documentElement.lang === 'en' ? 'en' : 'de';
  for (const canvas of document.querySelectorAll('canvas[data-led-demo]')) {
    const started = performance.now();
    const frameLoop = () => { paint(canvas, render(demoFeed(started), 0, {lang})); setTimeout(frameLoop, 100); };
    frameLoop();
  }
  for (const canvas of document.querySelectorAll('canvas[data-led-slug]')) {
    const slug = canvas.dataset.ledSlug, key = new URLSearchParams(location.search).get('k');
    let feed = null, received = 0, offline = false, lastSeq = 0;
    const poll = async () => {
      try {
        const response = await fetch(`/api/s/${encodeURIComponent(slug)}/led${key ? `?k=${encodeURIComponent(key)}` : ''}`, {cache: 'no-store'});
        if (!response.ok) throw new Error(String(response.status));
        const data = await response.json();
        if (data.seq >= lastSeq) { feed = data; received = performance.now(); lastSeq = data.seq; }
        offline = false;
      } catch { offline = true; }
    };
    await poll();
    setInterval(poll, 2000);
    const frameLoop = () => {
      paint(canvas, render(feed, performance.now() - received, {lang}), {offline});
      setTimeout(frameLoop, 100);
    };
    frameLoop();
  }
}
if (typeof document !== 'undefined') start();
