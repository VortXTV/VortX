import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";

// Execute the actual entry-point state, reload helper and receiving listeners. Transport, route
// rendering and browser startup are injected boundaries; no account or network is used here.
const source = readFileSync(new URL("../main.ts", import.meta.url), "utf8");
function sourcePart(start, end) {
  const offset = source.indexOf(start);
  const limit = source.indexOf(end, offset);
  assert.ok(offset >= 0 && limit > offset, "production extraction markers remain exact");
  assert.equal(source.indexOf(start, offset + start.length), -1, "production start marker remains unique");
  return source.slice(offset, limit);
}
const production = stripTypeScriptTypes([
  sourcePart("let addons: Addon[] = [];", "const APP_SHELL ="),
  sourcePart("async function reloadAddonsAndRender(", "/** Wire the search box:"),
  sourcePart('  window.addEventListener("vortx:addons-changed",', "  // Validate the token"),
].join("\n"), { mode: "strip" });

class ProfileSyncEvent extends Event {
  constructor(fromSync) {
    super("vortx:profile-changed");
    this.detail = { fromSync };
  }
}

function environment() {
  let profile = "A", playerOpen = false, parseCalls = 0, application;
  const requests = [], renders = [], listeners = new Map();
  const window = { addEventListener(type, listener) {
    assert.equal(listeners.has(type), false, `duplicate receiver: ${type}`);
    listeners.set(type, listener);
  } };
  function loadInstalledAddons() {
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    requests.push({ profile, promise, resolve });
    return promise;
  }
  const bindings = {
    window, CustomEvent: ProfileSyncEvent, loadInstalledAddons,
    isPlayerOpen: () => playerOpen,
    parseRoute: () => { parseCalls++; return { name: "home" }; },
    renderRoute: async (route) => { renders.push({ route, addons: application.readAddons() }); },
    renderLibrary: () => assert.fail("unrelated watchlist receiver must not run"),
    mainHost: () => assert.fail("unrelated watchlist receiver must not run"),
  };
  application = Function(...Object.keys(bindings), production +
    "\nreturn { readAddons: () => addons, generation: () => addonReloadGeneration };"
  )(...Object.values(bindings));
  function dispatch(event) {
    const listener = listeners.get(event.type);
    assert.equal(typeof listener, "function", `production receiver is registered: ${event.type}`);
    listener(event);
  }
  return {
    requests, renders, application,
    setProfile: (value) => { profile = value; },
    setPlayerOpen: (value) => { playerOpen = value; },
    parseCalls: () => parseCalls,
    profileChanged: (fromSync) => dispatch(typeof fromSync === "boolean"
      ? new ProfileSyncEvent(fromSync) : new Event("vortx:profile-changed")),
    addonsChanged: () => dispatch(new Event("vortx:addons-changed")),
    async finishLoad(index, addons) {
      const request = requests[index];
      assert.ok(request, `requested load ${index} exists`);
      request.resolve(addons);
      await request.promise;
      await Promise.resolve(); // let the real helper publish and complete its awaited render
    },
  };
}
const catalog = (id) => [{ transportUrl: `https://${id}.example.invalid/manifest.json`, manifest: { id } }];

test("a local profile change reloads that profile's add-ons before rendering", async () => {
  const env = environment(), a = catalog("a"), b = catalog("b");
  env.addonsChanged();
  await env.finishLoad(0, a);
  assert.equal(env.renders[0].addons, a);
  env.setProfile("B");
  env.profileChanged(); // setActiveProfile emits a plain Event, not a fromSync CustomEvent
  assert.equal(env.requests.length, 2, "profile selection requests fresh installed add-ons");
  assert.equal(env.requests[1].profile, "B");
  assert.equal(env.renders.length, 1, "old profile catalogs are not re-rendered while B loads");
  assert.equal(env.application.readAddons(), a);
  await env.finishLoad(1, b);
  assert.equal(env.application.readAddons(), b);
  assert.deepEqual(env.renders, [
    { route: { name: "home" }, addons: a },
    { route: { name: "home" }, addons: b },
  ]);
});

test("a slow A reload cannot overwrite or render after a newer B profile reload", async () => {
  const env = environment(), a = catalog("a"), b = catalog("b");
  env.profileChanged();
  env.setProfile("B");
  env.profileChanged();
  assert.deepEqual(env.requests.map((request) => request.profile), ["A", "B"]);
  assert.equal(env.application.generation(), 2);
  await env.finishLoad(1, b);
  assert.deepEqual(env.renders, [{ route: { name: "home" }, addons: b }]);
  await env.finishLoad(0, a);
  assert.equal(env.application.readAddons(), b);
  assert.deepEqual(env.renders, [{ route: { name: "home" }, addons: b }]);
});

test("only a live-sync profile notification during playback takes the early return", async () => {
  const env = environment(), b = catalog("b"), c = catalog("c");
  env.setPlayerOpen(true);
  env.profileChanged(true);
  assert.equal(env.requests.length, 0);
  assert.equal(env.application.generation(), 0);
  assert.equal(env.parseCalls(), 0);
  assert.equal(env.renders.length, 0);
  env.setProfile("B");
  env.profileChanged();
  assert.equal(env.requests.length, 1, "a local notification is not swallowed during playback");
  await env.finishLoad(0, b);
  assert.equal(env.renders[0].addons, b);
  env.setPlayerOpen(false);
  env.setProfile("C");
  env.profileChanged(true);
  assert.equal(env.requests.length, 2, "idle sync notifications still reload the new profile");
  await env.finishLoad(1, c);
  assert.equal(env.renders[1].addons, c);
});

test("add-ons notifications refresh the cache but preserve an open player", async () => {
  const env = environment(), a = catalog("a"), b = catalog("b");
  env.setPlayerOpen(true);
  env.addonsChanged();
  assert.equal(env.requests.length, 1);
  await env.finishLoad(0, a);
  assert.equal(env.application.readAddons(), a, "background sync still refreshes installed add-ons");
  assert.equal(env.parseCalls(), 0);
  assert.equal(env.renders.length, 0, "preservePlayback=true prevents the route from closing playback");
  env.setPlayerOpen(false);
  env.addonsChanged();
  await env.finishLoad(1, b);
  assert.equal(env.application.readAddons(), b);
  assert.deepEqual(env.renders, [{ route: { name: "home" }, addons: b }]);
});

test("an add-ons reload checks playback when it completes, not when it starts", async () => {
  const env = environment(), a = catalog("a");
  env.setPlayerOpen(true);
  env.addonsChanged();
  assert.equal(env.requests.length, 1);
  assert.equal(env.renders.length, 0);
  env.setPlayerOpen(false);
  await env.finishLoad(0, a);
  assert.deepEqual(env.renders, [{ route: { name: "home" }, addons: a }]);
});
