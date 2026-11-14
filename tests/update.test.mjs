import test from 'node:test';
import assert from 'node:assert/strict';
import {returnUrl, installLatest} from '../backend/score67/static/update.mjs';

test('update preserves the game, language and fragment but rejects external returns', () => {
  assert.equal(returnUrl('/s/game/control?lang=en#team', 'https://score67.de', 'abc'),
    'https://score67.de/s/game/control?lang=en&release=abc#team');
  assert.throws(() => returnUrl('//evil.example', 'https://score67.de', 'abc'));
  assert.throws(() => returnUrl('/update', 'https://score67.de', 'abc'));
});

test('update removes only Flutter caches and worker, then returns to the controller', async () => {
  const removed = [], workers = [], visits = [];
  const env = {
    fetch: async () => ({ok: true, json: async () => ({release: 'abc'})}),
    navigator: {serviceWorker: {getRegistrations: async () => [
      {active: {scriptURL: 'https://score67.de/app/flutter_service_worker.js'}, unregister: async () => workers.push('flutter')},
      {active: {scriptURL: 'https://score67.de/other/worker.js'}, unregister: async () => workers.push('other')},
    ]}},
    caches: {delete: async name => removed.push(name)},
    location: {origin: 'https://score67.de', replace: url => visits.push(url)},
  };
  await installLatest(env, '/s/game/control');
  assert.deepEqual(workers, ['flutter']);
  assert.deepEqual(removed, ['flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest']);
  assert.deepEqual(visits, ['https://score67.de/s/game/control?release=abc']);
  env.fetch = async () => { throw new Error('offline'); };
  await assert.rejects(installLatest(env, '/'));
  assert.equal(removed.length, 3);
  assert.equal(visits.length, 1);
});
