// Flocks service worker. Same-origin GET requests only; the database and Target
// photos always go straight to the network.
// - Versioned files (photos/…?v=, cutouts/…?v=) never change, so the saved copy is used.
// - The photo and cutout lists show the saved copy at once and update in the background.
// - Everything else tries the network first, but uses the saved copy if the network
//   takes longer than 3 seconds (weak signal in a store), or fails.
const CACHE = "flocks-v3";
const SHELL = ["./", "index.html", "config.js", "birds.json", "manifest.webmanifest", "photos/index.json", "cutouts/index.json",
  "icons/apple-touch-icon.png", "icons/icon-192.png", "icons/icon-512.png", "icons/icon-maskable-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => Promise.all(SHELL.map((u) => c.add(u).catch(() => {})))).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

function save(req, res) {
  if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
  return res;
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin) return;

  if (url.searchParams.has("v")) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => save(req, res))));
    return;
  }
  if (/\/(photos|cutouts)\/index\.json$/.test(url.pathname)) {
    const fresh = fetch(req).then((res) => save(req, res));
    e.waitUntil(fresh.catch(() => {}));
    e.respondWith(caches.match(req, { ignoreSearch: true }).then((hit) => hit || fresh));
    return;
  }
  const fresh = fetch(req).then((res) => save(req, res));
  e.waitUntil(fresh.catch(() => {}));
  const fallback = () => caches.match(req, { ignoreSearch: true })
    .then((hit) => hit || (req.mode === "navigate" ? caches.match("index.html") : undefined));
  e.respondWith(new Promise((resolve) => {
    let done = false;
    const finish = (r) => { if (!done && r) { done = true; resolve(r); } };
    const timer = setTimeout(() => fallback().then(finish), 3000);
    fresh.then((res) => { clearTimeout(timer); finish(res); })
      .catch(() => { clearTimeout(timer); fallback().then((hit) => { if (hit) finish(hit); else { done = true; resolve(Response.error()); } }); });
  }));
});
