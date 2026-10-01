import test from 'node:test';
import assert from 'node:assert/strict';
import {clockText, periodLabel, DelayedStates} from '../backend/score67/static/common.mjs';
const state = () => ({period: 1, period_count: 2, period_length_min: 45,
  clock: {enabled:true, direction:'up', running:true, elapsed_ms:0, started_at:1000}});
test('clock uses elapsed timestamps, compensates delay, and shows added time', () => {
  const s = state();
  assert.equal(clockText(s, 2701000), '45:00');
  assert.equal(clockText(s, 2791000), '45+2');
  assert.equal(clockText(s, 64000 - 3000), '01:00');
  s.period = 2;
  assert.equal(clockText(s, 1000), '45:00');
  s.clock.enabled = false;
  assert.equal(clockText(s, 1000), '');
});
test('countdown clamps to zero and stopped clocks do not move', () => {
  const s = state(); s.clock.direction = 'down';
  assert.equal(clockText(s, 99999999), '00:00');
  s.clock.running = false; s.clock.elapsed_ms = 60000;
  assert.equal(clockText(s, 99999999), '44:00');
});
test('period labels handle minigames and arbitrary formats', () => {
  const s = state();
  assert.equal(periodLabel(s,{half:'H{n}'}), 'H1');
  s.period_count = 1; assert.equal(periodLabel(s,{}), '');
  s.period_count = 8; s.period = 3; assert.equal(periodLabel(s,{}), '3/8');
});
test('delay queues every revision and ignores duplicates and old responses', () => {
  const q = new DelayedStates();
  q.push({match_id:'a',revision:0,server_now:100},3000);
  q.push({match_id:'a',revision:1,server_now:200},3200);
  q.push({match_id:'a',revision:1,server_now:300},3300);
  q.push({match_id:'a',revision:0,server_now:100},3400);
  assert.equal(q.take(2999), null);
  assert.equal(q.take(3000).revision, 0);
  assert.equal(q.take(3200).revision, 1);
  assert.equal(q.take(9999), null);
});

test('basketball countdown keeps full seconds and uses five-minute repeat overtime', () => {
  const s = {...state(), sport:'basketball', period:4, period_count:4, period_length_min:10, overtime_length_min:5};
  s.clock.direction = 'down';
  assert.equal(clockText(s, 1000), '10:00');
  assert.equal(clockText(s, 1001), '10:00');
  assert.equal(clockText(s, 2000), '09:59');
  assert.equal(clockText(s, 601001), '00:00');
  s.period = 5;
  assert.equal(clockText(s, 1000), '05:00');
  assert.equal(periodLabel(s,{}), 'OT1');
  s.period = 6;
  assert.equal(periodLabel(s,{}), 'OT2');
});
