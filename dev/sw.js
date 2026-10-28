// PCF Dev: guarda a "casca" do app para abrir rápido; os dados vêm sempre da internet
var C = 'pcfdev-v1';
var CASCA = ['./', './index.html', './manifest.webmanifest', './icone-192.png', './icone-512.png', './icone-180.png'];
self.addEventListener('install', function (e) { e.waitUntil(caches.open(C).then(function (c) { return c.addAll(CASCA); })); self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(caches.keys().then(function (ks) { return Promise.all(ks.filter(function (k) { return k !== C; }).map(function (k) { return caches.delete(k); })); })); self.clients.claim(); });
self.addEventListener('fetch', function (e) {
  var u = new URL(e.request.url);
  if (u.origin !== location.origin) return; // Firebase: sempre pela rede
  // página: rede primeiro (pega a versão nova), sem rede usa a guardada
  e.respondWith(fetch(e.request).then(function (r) { var cp = r.clone(); caches.open(C).then(function (c) { c.put(e.request, cp); }); return r; }).catch(function () { return caches.match(e.request); }));
});
