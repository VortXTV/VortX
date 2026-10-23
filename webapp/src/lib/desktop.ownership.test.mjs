import test, { after, afterEach, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";

// Actual desktop lane and actual close/source-switch functions. Only shell, transport and DOM sinks
// are fixtures. No native process, server, media playback, provider or account is contacted.
const previousTauri = globalThis.__TAURI__;
const previousFetch = globalThis.fetch;
const calls = [];
const creates = [];
const gates = [];
const requests = [];
const stops = [];
let prepare = async () => ({ ok: true });
let nativePlay = async () => null;
globalThis.fetch = async (url, options) => {
  creates.push([url, options]);
  return prepare(url, options);
};
globalThis.__TAURI__ = {
  core: {
    invoke: async (command, args) => {
      calls.push([command, args]);
      if (command === "server_base_url") return "http://127.0.0.1:54321";
      if (command === "mpv_play") return nativePlay(args);
      return null;
    },
  },
};
const desktop = await import("./desktop.ts");
const HASH = "0123456789abcdef0123456789abcdef01234567";

function deferred(value = undefined) {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  const gate = { promise, resolve: (result = value) => resolve(result) };
  gates.push(gate);
  return gate;
}
function request(stream = { infoHash: HASH }) {
  const pending = desktop.playTorrent(stream);
  requests.push(pending);
  void pending.catch(() => undefined);
  return pending;
}
function releaseNative() {
  const stopped = desktop.stopTorrent();
  stops.push(stopped);
}
async function waitFor(ready) {
  for (let i = 0; i < 100 && !ready(); i++) await new Promise((done) => setImmediate(done));
  assert.ok(ready(), "fixture must reach the awaited production boundary");
}
function productionFunction(path, start, end, scope, result) {
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const offset = source.indexOf(start), limit = source.indexOf(end, offset);
  assert.ok(offset >= 0 && limit > offset, "production extraction boundaries remain exact");
  const js = stripTypeScriptTypes(source.slice(offset, limit).replace(/^export /, ""), { mode: "strip" });
  return Function(...Object.keys(scope), js + "\nreturn " + result + ";")(...Object.values(scope));
}
function closePlayer() {
  const close = productionFunction("./player.ts", "export function close(): void {", "/** Whether the player overlay is currently open.", {
    nativePlaybackOwned: desktop.nativePlaybackOwned,
    nativePlaybackActive: desktop.nativePlaybackActive,
    releaseNative,
    el: () => null,
    teardownMedia: () => undefined,
    document: { fullscreenElement: null },
    PLAYER_HOST_ID: "player",
    playToken: 0,
    sessionFallbacks: [],
    sessionIndex: 0,
    sessionOptions: {},
  }, "close");
  close();
}
function httpSourcePlayer(played) {
  return productionFunction("../views/detail.ts", "async function playStream(", "/** The episode that follows", {
    state: null,
    isDesktop: () => false,
    nativePlaybackOwned: desktop.nativePlaybackOwned,
    nativePlaybackActive: desktop.nativePlaybackActive,
    releaseNative,
    rankedFiltered: () => [],
    playbackFallbacks: () => [],
    play: (...args) => { played.push(args); return Promise.resolve(); },
    currentPlayToken: () => 0,
  }, "playStream");
}

beforeEach(async () => {
  prepare = async () => ({ ok: true });
  nativePlay = async () => null;
  await desktop.stopTorrent();
  assert.equal(await desktop.primeTorrentServer(), true);
  calls.length = 0; creates.length = 0; gates.length = 0; requests.length = 0; stops.length = 0;
});
afterEach(async () => {
  for (const gate of gates) gate.resolve();
  await Promise.allSettled([...requests, ...stops]);
  await desktop.stopTorrent();
});
after(() => {
  if (previousTauri === undefined) delete globalThis.__TAURI__;
  else globalThis.__TAURI__ = previousTauri;
  globalThis.fetch = previousFetch;
});

test("closing the actual player revokes deferred native preparation before mpv starts", async () => {
  const creating = deferred({ ok: true });
  prepare = () => creating.promise;
  const playing = request();
  assert.equal(desktop.nativePlaybackOwned(), true, "request admission owns teardown immediately");
  assert.equal(desktop.nativePlaybackActive(), false);
  await waitFor(() => creates.length === 1);
  await desktop.setNativePaused(true); await desktop.seekNative(10);
  assert.equal(calls.some(([name]) => name === "mpv_set_paused" || name === "mpv_seek_relative"), false,
    "pending ownership never grants active transport controls");
  closePlayer();
  assert.equal(desktop.nativePlaybackOwned(), false, "close revokes pending ownership synchronously");
  creating.resolve();
  assert.equal(await playing, false);
  await Promise.all(stops);
  assert.equal(calls.some(([name]) => name === "mpv_play"), false);
});

test("an actual HTTP source switch revokes native preparation without awaiting the lane", async () => {
  const creating = deferred({ ok: true });
  prepare = () => creating.promise;
  const native = request();
  await waitFor(() => creates.length === 1);
  const played = [];
  const switching = httpSourcePlayer(played)({ url: "https://media.invalid/new.mp4" });
  assert.equal(played.length, 1, "in-page play stays in the synchronous user-activation path");
  assert.equal(desktop.nativePlaybackOwned(), false);
  assert.equal(desktop.nativePlaybackActive(), false);
  creating.resolve();
  assert.equal(await native, false);
  await switching; await Promise.all(stops);
  assert.equal(calls.some(([name]) => name === "mpv_play"), false);
});

test("closing during an in-flight mpv command stops its late result in the same lane", async () => {
  const starting = deferred();
  nativePlay = () => starting.promise;
  const native = request();
  await waitFor(() => calls.some(([name]) => name === "mpv_play"));
  assert.equal(desktop.nativePlaybackOwned(), true);
  assert.equal(desktop.nativePlaybackActive(), false);
  closePlayer();
  assert.equal(desktop.nativePlaybackOwned(), false);
  starting.resolve();
  assert.equal(await native, false);
  await Promise.all(stops);
  const names = calls.map(([name]) => name);
  assert.ok(names.slice(names.indexOf("mpv_play") + 1).includes("mpv_stop"), "late native start is retired");
  assert.equal(desktop.nativePlaybackActive(), false);
  assert.equal(desktop.nativePlaybackOwned(), false);
});

test("an older preparation finally cannot clear a newer pending generation", async () => {
  const first = deferred({ ok: true }), second = deferred({ ok: true });
  prepare = () => creates.length === 1 ? first.promise : second.promise;
  const older = request();
  await waitFor(() => creates.length === 1);
  const newer = request({ infoHash: HASH, fileIdx: 2 });
  first.resolve();
  assert.equal(await older, false);
  await waitFor(() => creates.length === 2);
  assert.equal(desktop.nativePlaybackOwned(), true);
  assert.equal(desktop.nativePlaybackActive(), false);
  second.resolve();
  assert.equal(await newer, true);
  assert.equal(desktop.nativePlaybackActive(), true);
  assert.equal(desktop.nativePlaybackOwned(), true);
  assert.equal(calls.filter(([name]) => name === "mpv_play").length, 1);
  assert.equal(calls.find(([name]) => name === "mpv_play")[1].url.endsWith("/2"), true);
});

test("close followed by a new request preserves the new owner after an old native command settles", async () => {
  const firstStart = deferred(), secondPrepare = deferred({ ok: true });
  prepare = () => creates.length === 1 ? Promise.resolve({ ok: true }) : secondPrepare.promise;
  nativePlay = (args) => args.url.endsWith("/0") ? firstStart.promise : Promise.resolve(null);
  const older = request();
  await waitFor(() => calls.some(([name]) => name === "mpv_play"));
  closePlayer();
  const newer = request({ infoHash: HASH, fileIdx: 3 });
  assert.equal(desktop.nativePlaybackOwned(), true);
  firstStart.resolve();
  assert.equal(await older, false);
  await waitFor(() => creates.length === 2);
  assert.equal(desktop.nativePlaybackOwned(), true, "old finally/queued stop must not clear the new pending owner");
  assert.equal(desktop.nativePlaybackActive(), false);
  secondPrepare.resolve();
  assert.equal(await newer, true);
  assert.equal(desktop.nativePlaybackActive(), true);
  assert.equal(calls.filter(([name]) => name === "mpv_play").at(-1)[1].url.endsWith("/3"), true);
});

test("a failed current native command releases pending ownership without granting controls", async () => {
  nativePlay = async () => { throw new Error("synthetic native command failure"); };
  await assert.rejects(request(), /synthetic native command failure/);
  assert.equal(desktop.nativePlaybackOwned(), false);
  assert.equal(desktop.nativePlaybackActive(), false);
});
