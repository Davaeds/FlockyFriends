// Flocks service worker. Same-origin GET requests only; the database and Target
// photos always go straight to the network.
// - Versioned files (photos/…?v=, cutouts/…?v=) never change, so the saved copy is used.
// - The photo and cutout lists show the saved copy at once and update in the background;
//   saved photos and cutouts that are no longer listed are then thrown away.
// - Everything else tries the network first, but uses the saved copy if the network
//   takes longer than 3 seconds (weak signal in a store), fails, or sends an error page.
// - Only real answers from this site are saved: never a store Wi-Fi sign-in page,
//   a redirect, or an error.
const CACHE = "flocks-v3";
const CORE = ["./", "index.html", "config.js", "birds.json"];
const EXTRA = ["manifest.webmanifest", "photos/index.json", "cutouts/index.json",
  "icons/apple-touch-icon.png", "icons/icon-192.png", "icons/icon-512.png", "icons/icon-maskable-512.png"];

self.addEventListener("install", (e) => {
  // If the core files can't all be fetched, the install fails and the old version (with its saved copy) stays.
  e.waitUntil(caches.open(CACHE)
    .then((c) => c.addAll(CORE.map((u) => new Request(u, { cache: "reload" })))
      .then(() => Promise.all(EXTRA.map((u) => c.add(new Request(u, { cache: "reload" })).catch(() => {})))))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

function fits(req, res) {
  const type = res.headers.get("content-type") || "", path = new URL(req.url).pathname;
  if (/\.json$/.test(path)) return /json/.test(type);
  if (/\.(webp|jpe?g|png)$/.test(path)) return /^image\//.test(type);
  if (req.mode === "navigate" || /(\/|\.html)$/.test(path)) return /text\/html/.test(type);
  return true;
}

function save(req, res) {
  if (res && res.ok && res.type === "basic" && !res.redirected && fits(req, res)) {
    const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy));
  }
  return res;
}

// Drop saved photos or cutouts whose version is no longer in the fresh list.
function prune(dir, list) {
  return caches.open(CACHE).then((c) => c.keys().then((reqs) => Promise.all(reqs.map((r) => {
    const u = new URL(r.url), m = u.pathname.match(new RegExp("/" + dir + "/([^/]+)\\.\\w+$"));
    if (!m || !u.searchParams.has("v")) return null;
    const item = list[decodeURIComponent(m[1])], v = item && typeof item === "object" ? item.v : item;
    return String(v) === u.searchParams.get("v") ? null : c.delete(r);
  }))));
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin) return;

  if (url.searchParams.has("v")) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => save(req, res))));
    return;
  }
  const index = url.pathname.match(/\/(photos|cutouts)\/index\.json$/);
  if (index) {
    const fresh = fetch(req).then((res) => {
      save(req, res);
      if (res.ok && fits(req, res)) res.clone().json().then((list) => prune(index[1], list)).catch(() => {});
      return res;
    });
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
    fresh.then((res) => {
      clearTimeout(timer);
      if (res.ok) return finish(res);
      fallback().then((hit) => finish(hit || res));   // an error page: the saved copy is better, if there is one
    }).catch(() => { clearTimeout(timer); fallback().then((hit) => { if (hit) finish(hit); else { done = true; resolve(Response.error()); } }); });
  }));
});
