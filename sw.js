const CACHE_NAME = "medvisit-remote-cache-v2";
const APP_SHELL = [
  "./",
  "./index.html",
  "./medecin.html",
  "./app-db-remote.js",
  "./supabase-config.js",
  "./manifest.json",
  "icons/icon-192.png",
  "icons/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((c) => c.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Réseau en priorité (l'app évolue souvent) : le cache ne sert que de
// secours hors-ligne, jamais de version affichée par défaut quand une
// connexion est disponible — sinon une mise à jour de l'app peut rester
// invisible indéfiniment pour un appareil déjà visité.
self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return; // ne pas intercepter Supabase/CDN
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response && response.status === 200) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
