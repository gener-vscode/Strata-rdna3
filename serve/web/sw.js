// serve/web/sw.js - the worker that lets the web page be installed as an app (serve/web/manifest.webmanifest).
//
// What it does: the page and the files the page loads for itself - its styles, script, icon sprite, icons and
// font - are kept in the browser's own cache. Opening Strata again then does not wait on the PC, and when the
// server is not answering the page still opens and shows its own "Strata is not running" veil instead of the
// browser's error page.
//
// What it does not do: anything that is not one of the app's own files is not looked at here at all. Every
// API call - /v1, /status, /metrics, /health, /slots, /models, /props, /config, /settings, /mcp - and every
// POST, including a chat that streams, goes past the worker untouched. An older /metrics or a cached answer
// from the model would be a wrong number, or a wrong answer, on the screen.
//
// The strategy is network first. This server is on the same PC and answering is cheap, so the file you get is
// always the one the server has now, and the cache is only what falls back when there is no server to ask.
// A new build is therefore picked up on the next open, not after a forced reload.

// Bumped when the files below change, so an app that is already installed drops the old copies on its next
// open rather than running an old script against new styles.
const VERSION = "strata-2";

// Relative to this file, which sits in serve/web: "../" is where the page is, the rest are its own files.
const SHELL = ["../", "app.css", "tokens.css", "components.css", "app.js", "sprite.svg", "favicon.svg",
               "manifest.webmanifest", "icon-192.png", "icon-512.png", "icon-maskable-512.png",
               "../fonts/outfit-latin-wght.woff2", "../fonts/outfit-latin-ext-wght.woff2"];
const BASE = new URL("../", self.location);            // / or, with the run config's "dashboard", /ui/
const PAGE = BASE.href;
const OWN = [BASE.pathname + "web/", BASE.pathname + "fonts/"];   // the app's two file directories

self.addEventListener("install", (e) => {
  // A file that is not there (a font the build left out) must not stop the install: the page works without it.
  e.waitUntil(caches.open(VERSION)
    .then((c) => Promise.all(SHELL.map((f) => c.add(new URL(f, self.location)).catch(() => null)))));
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const r = e.request;
  if (r.method !== "GET") return;                                  // a chat, a stream, a saved setting
  const u = new URL(r.url);
  if (u.origin !== self.location.origin) return;                   // a tool server, an image URL
  if (u.pathname !== BASE.pathname && !OWN.some((p) => u.pathname.startsWith(p))) return;   // the API
  e.respondWith(fresh(r));
});

async function fresh(r) {
  const cache = await caches.open(VERSION);
  try {
    const reply = await fetch(r);
    if (reply.ok) cache.put(r, reply.clone());
    return reply;
  } catch (e) {
    // No server to ask. The file itself if it was ever seen, else the page - which then shows its own
    // "Strata is not running" veil, with the tabs and the theme switch still working.
    const kept = await cache.match(r) || (r.mode === "navigate" ? await cache.match(PAGE) : undefined);
    if (kept) return kept;
    throw e;
  }
}
