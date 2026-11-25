/* MFC Coaching — service worker : hors-ligne + notifications */
const CACHE = 'mfc-coaching-v1';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k.startsWith('mfc-coaching-') && k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

/* Réseau d'abord, copie en cache pour le hors-ligne */
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request)
      .then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); return res; })
      .catch(() => caches.match(e.request).then((r) => r || caches.match('./index.html')).then((r) => r || caches.match('./')))
  );
});

/* Notification envoyée par le serveur MFC (titre et texte chiffrés dans le message) */
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = {}; }
  e.waitUntil(self.registration.showNotification(d.title || 'MFC Coaching', {
    body: d.body || 'Ouvre l’appli pour voir ton entraînement.',
    icon: './icon-192.png',
    badge: './icon-192.png',
    tag: d.tag || 'mfc',
    data: { url: d.url || './' }
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if (c.url.startsWith(self.registration.scope) && 'focus' in c) return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
