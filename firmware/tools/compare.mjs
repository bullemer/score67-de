// Compares the firmware renderer (host build) with the browser preview, pixel
// for pixel, over a set of feeds. Run: pio run -e native && node tools/compare.mjs
import {render} from '../../backend/score67/static/led.mjs';
import {execFileSync} from 'node:child_process';
import {writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const program = join(root, '.pio/build/native/program');
const dir = mkdtempSync(join(tmpdir(), 'score67-cmp-'));
const home = {short: 'BRA', score: 41, color: '#1d4ed8', fouls: 3}, guest = {short: 'TSV', score: 38, color: '#c8102e', fouls: 5};
const game = extra => ({v: 1, seq: 1, server_now: 1, mode: 'game', name: 'Halle', brightness: 60, identify: false,
  sport: 'basketball', phase: 'period_running', period: 'Q3', home, guest, possession: 'home',
  clock: {visible: true, running: true, direction: 'down', ms: 125000, at: 1}, ...extra});
const cases = {
  pairing: [{mode: 'pairing', code: '472913', name: 'Anzeigetafel', brightness: 60, identify: false}, 0],
  idle: [{mode: 'idle', name: 'x', brightness: 60, identify: false}, 0],
  idle_with_code: [{mode: 'idle', name: 'x', brightness: 60, identify: false, code: '001234'}, 0],
  basketball_running: [game(), 3000],
  under_minute_tenths: [game({clock: {visible: true, running: true, direction: 'down', ms: 59000, at: 1}}), 1234],
  stopped_clock: [game({clock: {visible: true, running: false, direction: 'down', ms: 300000}, possession: 'away'}), 9000],
  three_digits: [game({home: {...home, score: 102}, guest: {...guest, score: 99}}), 0],
  football_cards: [game({sport: 'football', period: 'H2', possession: null, home: {short: 'HSV', score: 2, color: '#0a1a6b', red_cards: 2}, guest: {short: 'FCB', score: 1, color: '#dc052d', red_cards: 1}, clock: {visible: true, running: true, direction: 'up', ms: 2700000}}), 65000],
  finished_de: [game({phase: 'finished', clock: {visible: false}}), 0],
  finished_en: [game({phase: 'finished', clock: {visible: false}, lang: 'en'}), 0],
  dark_colour_umlaut: [game({home: {short: 'KÖL', score: 7, color: '#111111'}, guest: {short: 'ÄÜX', score: 0, color: '#000000'}}), 0],
  identify_on: [game({identify: true}), 100],
  identify_off: [game({identify: true}), 500],
  msg_icon_text: [game({msg: {id: 'a', kind: 'text', text: 'DANKE!', icon: 'heart', effect: 'static', color: '#ffa31a', ms: 9000}}), 1500],
  msg_two_lines: [game({msg: {kind: 'text', text: 'LETS GO BRA!', effect: 'static', color: '#22c55e', ms: 9000}}), 10],
  msg_scroll: [game({msg: {kind: 'text', text: 'WILLKOMMEN IN DER HALLE', effect: 'static', color: '#ffffff', ms: 9000}}), 2345],
  msg_scroll_icon: [game({msg: {kind: 'text', text: 'HALLO AN ALLE', icon: 'star', effect: 'static', color: '#ffffff', ms: 9000}}), 777],
  msg_rainbow: [game({msg: {kind: 'text', text: 'DEFENSE', effect: 'rainbow', color: '#ffa31a', ms: 9000}}), 4321],
  msg_blink_on: [game({msg: {kind: 'text', text: 'GO', effect: 'blink', color: '#ffa31a', ms: 9000}}), 100],
  msg_blink_off: [game({msg: {kind: 'text', text: 'GO', effect: 'blink', color: '#ffa31a', ms: 9000}}), 600],
  msg_icon_only: [game({msg: {kind: 'text', text: '', icon: 'trophy', effect: 'static', color: '#ffa31a', ms: 9000}}), 0],
  msg_expired: [game({msg: {kind: 'text', text: 'GONE', effect: 'static', color: '#ffa31a', ms: 1000}}), 1500],
  msg_periods: [game({msg: {kind: 'periods', periods: [[18, 12], [9, 15], [14, 11], [0, 0]], home, guest, ms: 9000}}), 0],
  msg_periods_many: [game({msg: {kind: 'periods', periods: Array.from({length: 10}, (_, i) => [i * 2, 20 - i]), home, guest, ms: 9000}}), 0],
  msg_lead: [game({msg: {kind: 'lead', lead: Array.from({length: 62}, (_, i) => Math.round(8 * Math.sin(i / 9) - i / 10)), home, guest, ms: 9000}}), 0],
};
let failed = 0;
for (const [name, [feed, sinceMs]] of Object.entries(cases)) {
  const file = join(dir, `${name}.json`);
  writeFileSync(file, JSON.stringify(feed));
  const expected = render(feed, sinceMs, {lang: feed.lang || 'de'}).pixels;
  const actual = JSON.parse(execFileSync(program, [file, String(sinceMs)]).toString());
  const diffs = [];
  for (let i = 0; i < expected.length; i++) if ((expected[i] || null) !== (actual[i] || null)) diffs.push(`(${i % 64},${Math.floor(i / 64)}) js=${expected[i]} fw=${actual[i]}`);
  if (diffs.length) { failed++; console.log(`FAIL ${name}: ${diffs.length} pixels differ, e.g. ${diffs.slice(0, 4).join('; ')}`); }
  else console.log(`ok   ${name}`);
}
console.log(failed ? `${failed} case(s) differ` : 'all cases identical');
process.exit(failed ? 1 : 0);
