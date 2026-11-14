import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {chatAge} from '../backend/score67/static/chat-time.mjs';
const words = JSON.parse(readFileSync(new URL('../shared/i18n/en.json', import.meta.url)));
const t = key => words[key];
test('relative chat timestamps update across seconds, minutes, hours and days', () => {
  for (const [age, expected] of [[-1000, 'Just now'], [0, 'Just now'], [4000, '4 sec ago'],
    [59999, '59 sec ago'], [60000, '1 min ago'], [3600000, '1 hr ago'],
    [86400000, '1 day ago'], [172800000, '2 days ago']]) {
    assert.equal(chatAge(10000, 10000 + age, t), expected);
  }
});
test('relative chat times use German translations too', () => {
  const de = JSON.parse(readFileSync(new URL('../shared/i18n/de.json', import.meta.url)));
  assert.equal(chatAge(0, 4000, key => de[key]), 'vor 4 Sek.');
  assert.equal(chatAge(0, 172800000, key => de[key]), 'vor 2 Tagen');
});
