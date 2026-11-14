export function returnUrl(value, origin, release) {
  const url = new URL(value || '/', origin);
  if (url.origin !== origin || url.pathname === '/update') returnUrlError();
  url.searchParams.set('release', release);
  return url.href;
}
function returnUrlError() { throw new Error('invalid_return'); }

export async function installLatest(env, destination) {
  // Confirm connectivity before touching any cached files.
  const response = await env.fetch('/api/release', {cache: 'no-store', signal: AbortSignal.timeout(10000)});
  if (!response.ok) throw new Error('release_unavailable');
  const release = await response.json();
  let target;
  try { target = returnUrl(destination, env.location.origin, release.release); }
  catch { target = returnUrl('/', env.location.origin, release.release); }
  if (env.navigator.serviceWorker) {
    const registrations = await env.navigator.serviceWorker.getRegistrations();
    for (const registration of registrations) {
      const worker = registration.active || registration.waiting || registration.installing;
      if (worker && new URL(worker.scriptURL).origin === env.location.origin &&
          new URL(worker.scriptURL).pathname === '/app/flutter_service_worker.js') {
        await registration.unregister();
      }
    }
  }
  if (env.caches) {
    for (const name of ['flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest']) {
      await env.caches.delete(name);
    }
  }
  // Cookies and localStorage (credentials, queued scores, preferences) are kept.
  env.location.replace(target);
}

if (typeof document !== 'undefined' && document.getElementById('update-retry')) {
  const retry = document.getElementById('update-retry');
  async function update() {
    retry.hidden = true;
    document.getElementById('update-error').hidden = true;
    document.getElementById('update-loading').hidden = false;
    try { await installLatest(window, new URLSearchParams(location.search).get('return')); }
    catch {
      document.getElementById('update-loading').hidden = true;
      document.getElementById('update-error').hidden = false;
      retry.hidden = false;
    }
  }
  retry.onclick = update;
  update();
}
