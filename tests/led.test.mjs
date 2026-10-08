import test from 'node:test';
import assert from 'node:assert/strict';
import {render, wrap, WIDTH} from '../backend/score67/static/led.mjs';

const game = msg => ({v: 1, mode: 'game', home: {short: 'BRA', score: 41, color: '#1d4ed8'},
  guest: {short: 'TSV', score: 38, color: '#c8102e'}, clock: {visible: false}, msg});
const lit = frame => frame.pixels.filter(Boolean).length;

test('message text wraps into two big lines of eight, longer words scroll', () => {
  assert.deepEqual(wrap('LETS GO BRA!'), ['LETS GO', 'BRA!']);
  assert.deepEqual(wrap('DEFENSE'), ['DEFENSE']);
  assert.equal(wrap('WILLKOMMENSGRUSS'), null);
  assert.equal(wrap('HALLO AN ALLE FANS HIER').length, 4);
});

test('a message replaces the score while it lasts, then the score returns', () => {
  const feed = game({kind: 'text', text: 'DANKE!', icon: 'heart', ms: 5000, color: '#ffa31a'});
  const during = render(feed, 1000), after = render(feed, 5001), score = render(game(null), 1000);
  assert.notDeepEqual(during.pixels, score.pixels);
  assert.deepEqual(after.pixels, score.pixels);
  assert.equal(during.pixels[2 * WIDTH + 28], '#ef4444');   // the heart, top middle
});

test('blink hides every other half second; scrolling text moves', () => {
  const blink = game({kind: 'text', text: 'GO', effect: 'blink', ms: 9000});
  assert.ok(lit(render(blink, 100)) > 0);
  assert.equal(lit(render(blink, 600)), 0);
  const scroll = game({kind: 'text', text: 'WILLKOMMEN IN DER HALLE', ms: 9000});
  assert.notDeepEqual(render(scroll, 500).pixels, render(scroll, 1500).pixels);
});

test('charts: period bars and the lead curve in team colours', () => {
  const periods = render(game({kind: 'periods', periods: [[18, 12], [0, 0]], ms: 9000,
    home: {short: 'BRA', color: '#1d4ed8'}, guest: {short: 'TSV', color: '#c8102e'}}), 0);
  assert.ok(periods.pixels.includes('#1d4ed8') && periods.pixels.includes('#c8102e'));
  const lead = render(game({kind: 'lead', lead: [0, 3, -2], ms: 9000,
    home: {short: 'BRA', color: '#1d4ed8'}, guest: {short: 'TSV', color: '#c8102e'}}), 0);
  assert.equal(lead.pixels[18 * WIDTH + 2], '#1d4ed8');    // home ahead: above the line
  assert.equal(lead.pixels[20 * WIDTH + 3], '#c8102e');    // guest ahead: below
});
