/* Service worker: makes the tracker installable and lets it open offline.
   Bump VERSION whenever you change a file below so phones pick up the update. */
const VERSION = "v2";
const CACHE = "party-tracker-" + VERSION;
const SHELL = [
  "./", "index.html", "config.js", "manifest.webmanifest", "vendor/supabase.js",
  "icons/icon-192.png", "icons/icon-512.png", "icons/apple-touch-icon.png"
];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k.startsWith("party-tracker-") && k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// App files: network first so updates show up right away, cache when offline.
// Supabase data and sign-in never go through the cache: the page keeps its
// own offline copy of the stats, and auth must always be live.
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin) return;
  e.respondWith(
    fetch(e.request)
      .then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
        return res;
      })
      .catch(() => caches.match(e.request).then(hit => hit || caches.match("index.html")))
  );
});
