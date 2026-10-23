import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
    const candidate = new URL(specifier + ".ts", context.parentURL);
    if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
  }
  return next(specifier, context);
} });
const values = new Map();
globalThis.localStorage = { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), removeItem: (key) => values.delete(key) };
const nodes = new Map(), intervals = new Map(), timeouts = new Map(); let timer = 0;
const node = () => ({ innerHTML: "", hidden: false, classList: { add() {}, remove() {} }, addEventListener() {}, closest: () => ({ classList: { add() {} } }) });
globalThis.document = { hidden: false, getElementById: (id) => nodes.get(id) ?? null, documentElement: { dataset: {}, style: { setProperty() {}, removeProperty() {} } } };
globalThis.window = new EventTarget();
Object.assign(window, { matchMedia: () => ({ matches: false }), setInterval: (fn) => { const id = ++timer; intervals.set(id, fn); return id; }, clearInterval: (id) => intervals.delete(id), setTimeout: (fn) => { const id = ++timer; timeouts.set(id, fn); return id; }, clearTimeout: (id) => timeouts.delete(id) });
const look = { accentID: "vortx", background: "warm", textScale: 1, audioLang: "", subtitleLang: "", subtitlesMode: "always" };
values.set("vortx.web.profiles.v1", JSON.stringify([{ id: "owner", name: "Owner", avatar: "🦊", look }, { id: "viewer", name: "Viewer", avatar: "🐼", look }]));
const store = await import("./store.ts");
const { setActiveProfile } = await import("./profiles.ts");
const { loadBoard, mountFeatured, disposeFeatured } = await import("../views/board.ts");
const { renderDiscoverShell, loadDiscover } = await import("../views/discover.ts");
const media = (name) => ({ id: "tt1", type: "movie", name, poster: "https://img.test/poster.jpg" });
const addon = { transportUrl: "https://catalog.test/manifest.json", manifest: { id: "catalog", name: "Catalog", version: "1", resources: ["catalog"], catalogs: [{ type: "movie", id: "top" }] } };
const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r; }); return { promise, resolve }; };
const native = (scope, binding = "slot", restricted = false) => ({ scope, profiles: [{ id: "owner", binding, pending: false, locked: restricted, kids: false }] });

test("recent searches retain the legacy owner key and isolate overlay, native account and binding scopes", () => {
  values.set("vortx.web.recent.v1", JSON.stringify(["legacy owner"]));
  assert.deepEqual(store.recentSearches(), ["legacy owner"]);
  setActiveProfile("viewer");
  assert.deepEqual(store.recentSearches(), []);
  store.addRecentSearch("viewer query");
  setActiveProfile("owner");
  assert.deepEqual(store.recentSearches(), ["legacy owner"]);
  store.setNativeAccountProjection(native("account.a")); store.addRecentSearch("account a");
  store.setNativeAccountProjection(native("account.b")); assert.deepEqual(store.recentSearches(), []); store.addRecentSearch("account b");
  store.setNativeAccountProjection(native("account.a")); assert.deepEqual(store.recentSearches(), ["account a"]);
  store.setNativeAccountProjection(native("account.a", "other")); assert.deepEqual(store.recentSearches(), []);
  store.setNativeAccountProjection(native("account.a", "slot", true)); const before = JSON.stringify([...values]);
  assert.deepEqual(store.recentSearches(), []); store.addRecentSearch("restricted"); assert.equal(JSON.stringify([...values]), before);
  store.blockNativeAccountProjection("account.a"); assert.deepEqual(store.recentSearches(), []); store.addRecentSearch("blocked"); assert.equal(JSON.stringify([...values]), before);
  store.setNativeAccountProjection(null); assert.deepEqual(store.recentSearches(), ["legacy owner"]);
});

test("a disposed board cannot paint a replacement board or seed its hero", async () => {
  nodes.clear(); const oldBody = node(), newBody = node(), hero = node(); nodes.set("rail-body-0", oldBody); nodes.set("featured", hero);
  const read = deferred(); globalThis.fetch = () => read.promise;
  const pending = loadBoard([addon]);
  disposeFeatured(); nodes.set("rail-body-0", newBody);
  read.resolve(new Response(JSON.stringify({ metas: [media("old account")] }), { status: 200 }));
  await pending;
  assert.equal(newBody.innerHTML, ""); assert.equal(hero.innerHTML, ""); assert.equal(intervals.size, 0);
});

test("a newer board load owns reused rail nodes even when the older request completes last", async () => {
  nodes.clear(); const body = node(); nodes.set("rail-body-0", body); const first = deferred(); let reads = 0;
  globalThis.fetch = async () => { reads++; return reads === 1 ? first.promise : new Response(JSON.stringify({ metas: [media("new board")] }), { status: 200 }); };
  const old = loadBoard([addon]); await loadBoard([addon]);
  first.resolve(new Response(JSON.stringify({ metas: [media("old board")] }), { status: 200 })); await old;
  assert.match(body.innerHTML, /new board/); assert.doesNotMatch(body.innerHTML, /old board/);
});

test("disposing the hero clears the fade and a queued stale callback cannot repaint a replacement hero", () => {
  disposeFeatured(); nodes.clear(); const original = node(); nodes.set("featured", original);
  mountFeatured([media("first"), media("second")]); [...intervals.values()][0]();
  const staleFade = [...timeouts.values()][0]; assert.equal(typeof staleFade, "function");
  disposeFeatured(); assert.equal(timeouts.size, 0); assert.equal(intervals.size, 0);
  const replacement = node(); nodes.set("featured", replacement);
  assert.doesNotThrow(staleFade); assert.equal(replacement.innerHTML, "");
  mountFeatured([media("new first"), media("new second")]);
  staleFade(); assert.match(replacement.innerHTML, /new first/); assert.doesNotMatch(replacement.innerHTML, /second/);
  disposeFeatured();
});

test("a departed Discover load cannot mount its old hero into a new Home surface", async () => {
  nodes.clear(); const grid = node(), host = node(); nodes.set("discover-grid", grid);
  renderDiscoverShell(host, [addon], "movie");
  const read = deferred(); globalThis.fetch = () => read.promise;
  const pending = loadDiscover([addon], "movie"); nodes.delete("discover-grid"); const hero = node(); nodes.set("featured", hero);
  read.resolve(new Response(JSON.stringify({ metas: [media("departed catalog")] }), { status: 200 })); await pending;
  assert.equal(hero.innerHTML, ""); assert.equal(intervals.size, 0);
});
