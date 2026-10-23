import { test } from "node:test";
import assert from "node:assert/strict";

// The desktop bridge against a fake Tauri shell: loopback-only server base, exact torrent route, tracker
// expansion and the ordered native play/stop lane. No network: fetch is stubbed.
const calls = [];
let serverBase = "http://127.0.0.1:54321";
globalThis.fetch = async () => ({ ok: true });
const shell = {
  core: {
    invoke: async (command, args) => {
      calls.push([command, args]);
      if (command === "server_base_url") return serverBase;
      return null;
    },
  },
};
const desktop = await import("./desktop.ts");
const HASH = "0123456789abcdef0123456789abcdef01234567";

test("a browser is not the desktop shell and cannot play torrents", async () => {
  assert.equal(desktop.isDesktop(), false);
  assert.equal(await desktop.primeTorrentServer(), false);
  assert.equal(desktop.torrentUrl({ infoHash: HASH }), null);
});

test("only a numeric loopback base unlocks torrents", async () => {
  globalThis.__TAURI__ = shell;
  for (const hostile of ["http://evil.example:1234", "http://localhost:1234", "https://127.0.0.1:1234", "http://127.0.0.1:0"]) {
    serverBase = hostile;
    assert.equal(await desktop.primeTorrentServer(), false, hostile);
    assert.equal(desktop.torrentsAvailable(), false, hostile);
  }
  serverBase = "http://127.0.0.1:54321";
  assert.equal(await desktop.primeTorrentServer(), true);
  assert.equal(desktop.torrentsAvailable(), true);
});

test("the torrent route is exact and validated", () => {
  assert.equal(desktop.torrentUrl({ infoHash: HASH.toUpperCase(), fileIdx: 3 }), `http://127.0.0.1:54321/${HASH}/3`);
  assert.equal(desktop.torrentUrl({ infoHash: HASH }), `http://127.0.0.1:54321/${HASH}/0`);
  assert.equal(desktop.torrentUrl({ infoHash: "not-a-hash" }), null);
  assert.equal(desktop.torrentUrl({ infoHash: HASH, fileIdx: -1 }), null);
  assert.equal(desktop.torrentUrl({ infoHash: HASH, fileIdx: 1.5 }), null);
  assert.equal(desktop.torrentUrl({ infoHash: HASH, fileIdx: 2 ** 32 }), null);
  assert.equal(desktop.torrentUrl({ url: "https://cdn.example/a.mkv", infoHash: HASH }), null, "url streams stay in the webview");
});

test("tracker sources add DHT, HTTP twins of udp trackers and the defaults, de-duplicated", () => {
  const sources = desktop.trackerSources(HASH, ["tracker:udp://tracker.example:1337/announce", "tracker:udp://tracker.example:1337/announce"]);
  assert.equal(sources[0], "tracker:udp://tracker.example:1337/announce");
  assert.ok(sources.includes(`dht:${HASH}`));
  assert.ok(sources.includes("tracker:http://tracker.example:1337/announce"));
  assert.ok(sources.includes("tracker:http://tracker.opentrackr.org:1337/announce"));
  assert.equal(new Set(sources).size, sources.length);
});

test("play stops the previous session first and passes the resume position", async () => {
  calls.length = 0;
  assert.equal(await desktop.playTorrent({ infoHash: HASH, fileIdx: 1 }, 42), true);
  const names = calls.map(([command]) => command);
  assert.deepEqual(names.filter((n) => n.startsWith("mpv_")), ["mpv_stop", "mpv_play"]);
  assert.deepEqual(calls.find(([command]) => command === "mpv_play")[1], { url: `http://127.0.0.1:54321/${HASH}/1`, start: 42 });
  assert.equal(desktop.nativePlaybackActive(), true);
});

test("a newer request supersedes an older one and stop ends the session", async () => {
  const older = desktop.playTorrent({ infoHash: HASH }, 0);
  const newer = desktop.playTorrent({ infoHash: HASH, fileIdx: 2 }, 0);
  assert.equal(await older, false);
  assert.equal(await newer, true);
  await desktop.stopTorrent();
  assert.equal(desktop.nativePlaybackActive(), false);
});
