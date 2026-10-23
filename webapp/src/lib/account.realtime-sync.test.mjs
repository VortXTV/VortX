import { admit, seedOwned, Locks } from "./auth-adoption.fixtures.mjs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const local = new Map();
const session = new Map();
const storage = (values) => ({
  get length() { return values.size; },
  key: (index) => [...values.keys()][index] ?? null,
  getItem: (key) => values.get(key) ?? null,
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
});
globalThis.localStorage = storage(local);
globalThis.sessionStorage = storage(session);
globalThis.document = Object.assign(new EventTarget(), {
  visibilityState: "visible",
  documentElement: { dataset: {}, style: { setProperty() {}, removeProperty() {} } },
});
globalThis.window = new EventTarget();
globalThis.matchMedia = () => ({ matches: false });
Object.defineProperty(globalThis, "navigator", { configurable: true, value: { onLine: true, locks: new Locks() } });
local.set("vortx.web.profiles.v1", JSON.stringify([{ id: "owner", name: "Owner" }]));
local.set("vortx.web.activeProfile.v1", "owner");

const realTimeout = globalThis.setTimeout;
const realClearTimeout = globalThis.clearTimeout;
const realNow = Date.now;
let now = 1_790_000_000_000;
let nextTimer = 0;
const timers = new Map();
globalThis.setTimeout = (fn, delay = 0) => {
  const id = ++nextTimer;
  timers.set(id, { fn, at: now + delay });
  return id;
};
globalThis.clearTimeout = (id) => timers.delete(id);
Date.now = () => now;
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => realTimeout(r, 1)); };
const until = async (predicate, message) => {
  for (let i = 0; i < 100 && !predicate(); i++) await new Promise((r) => realTimeout(r, 2));
  assert.ok(predicate(), message);
};
const advance = async (ms) => {
  const end = now + ms;
  for (;;) {
    const next = [...timers].filter(([, value]) => value.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
    if (!next) break;
    now = next[1].at;
    timers.delete(next[0]);
    next[1].fn();
    await settle();
  }
  now = end;
  await settle();
};

class FakeSocket {
  static instances = [];
  constructor(url) { this.url = url; this.closed = false; FakeSocket.instances.push(this); }
  open() { this.onopen?.(); }
  update(version) { this.onmessage?.({ data: JSON.stringify({ type: "updated", version }) }); }
  close() { this.closed = true; }
  disconnect() { this.closed = true; this.onclose?.(); }
}
globalThis.WebSocket = FakeSocket;

// Older TV browsers expose secure random bytes/WebCrypto but not randomUUID.
const nativeRandomUUID = Object.getOwnPropertyDescriptor(crypto, "randomUUID");
Object.defineProperty(crypto, "randomUUID", { configurable: true, value: undefined });
let vault = await import("./vault.ts");
let account = await import("./account.ts");
let store = await import("./store.ts");
let settings = await import("./settings.ts");
let profiles = await import("./profiles.ts");
let player = await import("./player.ts");
let { renderLibrary } = await import("../views/library.ts");
const nativeFixture = JSON.parse(readFileSync(new URL("./fixtures/native-sync-carrier.json", import.meta.url), "utf8"));
const { sealDocument, openDocument } = vault.__syncCryptoTestHooks;
const { profileEditEventFingerprintSync, canonicalJSONHashSync } = await import("./nativeProfileEvents.ts");
const { applyHostIntent, createHostIntent } = await import("./nativeHostEdits.ts");
const { createProfileIntent, applyProfileIntent, applyAddonEventIntent } = await import("./nativeBrowserEvents.ts");
const { projectNativeSync } = await import("./nativeSyncProjection.ts");
let reloadGeneration = 0;
async function reloadAccountGraph(bootSession) {
  timers.clear(); // pending callbacks belong to the retired synthetic page
  // A real page reload retires the entire realm, not only account.ts while its old authority
  // subscription remains live. Keep synthetic durable bytes/timers, replace module/event lifetimes.
  const query = "?auth-fixture=realtime-reload-" + (++reloadGeneration);
  globalThis.window = new EventTarget();
  globalThis.document = Object.assign(new EventTarget(), {
    visibilityState: "visible", documentElement: { dataset: {}, style: { setProperty() {}, removeProperty() {} } },
  });
  // Explicit synthetic boot only: install an already-owned pair after retiring the old realm,
  // without publishing a new auth adoption to its still-imported Account subscriber.
  if (bootSession) seedOwned(bootSession);
  vault = await import("./vault.ts" + query);
  account = await import("./account.ts" + query);
  store = await import("./store.ts" + query);
  settings = await import("./settings.ts" + query);
  profiles = await import("./profiles.ts" + query);
  player = await import("./player.ts" + query);
  ({ renderLibrary } = await import("../views/library.ts" + query));
  return account;
}
const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { "content-type": "application/json" },
});
let accountCount = 0;
const makeSession = () => {
  const id = `synthetic-sync-${++accountCount}`;
  return { token: `synthetic-token-${id}`, account: { id, email: `${id}@example.test`, username: id },
    dataKey: new Uint8Array(32).fill(accountCount) };
};
const legacyDoc = (accent = "vortx") => ({
  foreign: { preserve: true },
  vortx: { updatedAt: 10, profiles: [{ id: "remote-owner", name: "Owner", main: true,
    settings: { accent, playback: { audioLang: "en" } } }] },
});
const journalsFor = (s) => [...local.entries()].filter(([key, raw]) => {
  if (!key.startsWith("vortx.web.sync-intents.v1.") || key.endsWith(".owner")) return false;
  return JSON.parse(raw).accountId === s.account.id;
});

async function serverFor(s, initial = legacyDoc()) {
  let version = 20;
  let document;
  const requests = [];
  const puts = [];
  let nextGetGate;
  let nextPutGate;
  let failures = 0;
  let lostResponses = 0;
  let getFailures = 0;
  let conditional = true;
  let upgradeRequired = false;
  let activeGets = 0;
  let maxGets = 0;
  let activePuts = 0;
  let maxPuts = 0;
  const seal = async (doc) => sealDocument(s.dataKey, new TextEncoder().encode(JSON.stringify(doc)), s.account.id, version, false);
  document = await seal(initial);
  const fetch = async (input, init = {}) => {
    const url = String(input);
    if (!url.startsWith("https://api.vortx.tv/")) {
      return json({ id: "synthetic-addon", name: "Synthetic", resources: [], types: [], catalogs: [] });
    }
    assert.equal(init.headers.authorization, `Bearer ${s.token}`);
    assert.ok(!url.includes(s.token), "HTTP bearer never appears in a URL");
    requests.push({ method: init.method ?? "GET", headers: init.headers });
    if (init.method === "PUT") {
      activePuts++; maxPuts = Math.max(maxPuts, activePuts);
      const body = JSON.parse(init.body);
      assert.ok(Object.hasOwn(body, "baseRevision"), "every writer carries a candidate witness");
      assert.ok(body.baseRevision === null || (Number.isSafeInteger(body.baseRevision) && body.baseRevision >= 0));
      assert.equal(body.version, body.baseRevision === null ? 0 : body.baseRevision + 1);
      puts.push(body);
      const gate = nextPutGate; nextPutGate = undefined;
      if (gate) await gate;
      activePuts--;
      if (upgradeRequired) return json({ error: "upgrade_required", accepted: false }, 426);
      if (failures) { failures--; return json({ error: "synthetic offline" }, 503); }
      const accepted = body.baseRevision === version && body.version === version + 1;
      if (accepted) { version = body.version; document = body.document; }
      if (lostResponses) { lostResponses--; throw new Error("synthetic response lost after storage"); }
      return json({ ok: true, accepted, ...(!accepted ? { version } : {}) });
    }
    activeGets++; maxGets = Math.max(maxGets, activeGets);
    const result = { document, version };
    const gate = nextGetGate; nextGetGate = undefined;
    if (gate) await gate;
    activeGets--;
    if (getFailures) { getFailures--; throw new Error("synthetic readback offline"); }
    if (conditional && init.headers["if-none-match"] === `"${result.version}"`) return new Response(null, { status: 304 });
    return json(result);
  };
  globalThis.fetch = fetch;
  return {
    fetch, requests, puts,
    get version() { return version; },
    get maxGets() { return maxGets; },
    get maxPuts() { return maxPuts; },
    fail(count = 1) { failures = count; },
    losePutResponse(count = 1) { lostResponses = count; },
    failGet(count = 1) { getFailures = count; },
    conditional(value) { conditional = value; },
    requireUpgrade() { upgradeRequired = true; },
    holdGet() { let release; nextGetGate = new Promise((r) => { release = r; }); return release; },
    holdPut() { let release; nextPutGate = new Promise((r) => { release = r; }); return release; },
    async remote(doc) { version++; document = await seal(doc); },
    async read() {
      const value = await openDocument(s.dataKey, document, s.account.id, version);
      assert.ok(value); return JSON.parse(new TextDecoder().decode(value));
    },
  };
}

test("automatic encrypted account sync uses sockets, clocks, network and durable storage", async (t) => {
  let stop;
  const clean = async () => {
    stop?.(); stop = undefined; await account.signOut(); timers.clear();
    document.visibilityState = "visible"; navigator.onLine = true;
    profiles.setActiveProfile(profiles.profiles()[0].id);
  };
  t.after(async () => {
    await clean(); globalThis.setTimeout = realTimeout; globalThis.clearTimeout = realClearTimeout; Date.now = realNow;
    if (nativeRandomUUID) Object.defineProperty(crypto, "randomUUID", nativeRandomUUID);
    else delete crypto.randomUUID;
  });

  await t.test("socket bursts coalesce delayed pulls, polling is conditional and foreground/online catches up", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s);
    await admit(vault, s, account); stop = account.startAccountSync();
    assert.match(session.get("vortx.web.sync-client.v1"), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, "journal actors work without randomUUID");
    await until(() => account.accountSyncStatus().receivedVersion === 20, "initial account pull");
    const socket = FakeSocket.instances.at(-1);
    assert.equal(new URL(socket.url).searchParams.get("token"), s.token);
    assert.ok(![...local.values(), ...session.values()].some((v) => v.includes("/v1/sync/connect")), "socket URL is transient");
    const release = server.holdGet();
    await server.remote(legacyDoc("ocean")); socket.update(21);
    await until(() => server.requests.length === 2, "the first hinted GET must snapshot its document/version before the next remote write");
    await server.remote(legacyDoc("royal"));
    for (let i = 0; i < 8; i++) socket.update(22);
    assert.equal(server.maxGets, 1, "only one receive GET may be active");
    release(); await until(() => account.accountSyncStatus().receivedVersion === 22, "coalesced follow-up pull");
    assert.equal(settings.getSettings().accentID, "royal"); assert.equal(server.puts.length, 0, "receive never echoes a PUT");
    await advance(3_000);
    assert.equal(server.requests.at(-1).headers["if-none-match"], '"22"');
    document.visibilityState = "hidden"; document.dispatchEvent(new Event("visibilitychange"));
    const count = server.requests.length; await server.remote(legacyDoc("gold")); await advance(6_000);
    assert.equal(server.requests.length, count, "hidden page does not poll"); assert.ok(socket.closed);
    document.visibilityState = "visible"; document.dispatchEvent(new Event("visibilitychange"));
    await until(() => settings.getSettings().accentID === "gold", "foreground catch-up");
    navigator.onLine = false; window.dispatchEvent(new Event("offline"));
    await server.remote(legacyDoc("ocean")); await advance(3_000);
    navigator.onLine = true; window.dispatchEvent(new Event("online"));
    await until(() => settings.getSettings().accentID === "ocean", "online catch-up");
    const old = FakeSocket.instances.at(-1); old.disconnect(); const before = FakeSocket.instances.length;
    await advance(999); assert.equal(FakeSocket.instances.length, before);
    await advance(1); assert.equal(FakeSocket.instances.length, before + 1, "socket reconnect uses backoff");
    server.conditional(false); await advance(3_000);
    assert.equal(settings.getSettings().accentID, "ocean", "older 200-only server fallback works");
  });

  await t.test("local settings survive an initial delayed GET and a PUT in flight, and retry without another edit", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s);
    await admit(vault, s, account); const releaseGet = server.holdGet(); stop = account.startAccountSync();
    settings.updateSettings({ accentID: "gold" });
    assert.ok(journalsFor(s).length, "pre-hydration edit is durable immediately");
    releaseGet(); await settle(); assert.equal(settings.getSettings().accentID, "gold");
    const releasePut = server.holdPut(); server.fail(); await advance(800);
    await until(() => server.puts.length === 1, "held first PUT");
    settings.updateSettings({ accentID: "royal", background: "oled" });
    await server.remote(legacyDoc("crimson")); FakeSocket.instances.at(-1).update(server.version);
    await settle(); assert.equal(settings.getSettings().accentID, "royal", "pull cannot overwrite pending local delta");
    releasePut(); await settle(); await advance(1_000);
    await until(() => server.puts.length >= 2, "automatic failure retry");
    const doc = await server.read();
    assert.equal(doc.profileEdits.roster[0].settings.accent, "royal"); assert.equal(doc.profileEdits.roster[0].settings.oled, true);
    assert.deepEqual(doc.foreign, { preserve: true }); assert.equal(server.maxPuts, 1);
    assert.equal(journalsFor(s).length, 0, "ACK removes durable intent");
  });

  await t.test("token rotation fences a delayed receive and creates a fresh receiver on guarded publication", async () => {
    await clean(); const s = makeSession(), server = await serverFor(s), release = server.holdGet();
    await admit(vault, s, account); stop = account.startAccountSync();
    await until(() => server.requests.length === 1, "held old-token GET");
    const old = FakeSocket.instances.at(-1), releaseFresh = server.holdGet();
    s.token = "synthetic-rotated-token"; await admit(vault, s);
    release(); await settle();
    assert.equal(account.accountSyncStatus().receivedVersion, undefined, "old reader never admits its response under the new token");
    assert.equal(local.get("vortx.syncVer." + s.account.id), undefined, "old response never raises storage floor");
    releaseFresh();
    await until(() => account.accountSyncStatus().appliedVersion === 20, "fresh token reader");
    assert.ok(old.closed); assert.notEqual(FakeSocket.instances.at(-1), old);
  });

  await t.test("upgrade-required retains durable intent and stops timer, foreground and socket writes until another account binds", async () => {
    await clean(); const s = makeSession(), server = await serverFor(s);
    await admit(vault, s, account); stop = account.startAccountSync();
    await until(() => account.accountSyncStatus().appliedVersion === 20, "initial account admitted");
    server.requireUpgrade(); settings.updateSettings({ accentID: "gold" }); await advance(800);
    assert.equal(server.puts.length, 1); assert.equal(account.accountSyncStatus().upgradeRequired, true);
    assert.ok(journalsFor(s).some(([, raw]) => JSON.parse(raw).settings.accentID === "gold"));
    await advance(60_000); window.dispatchEvent(new Event("online")); window.dispatchEvent(new Event("pageshow"));
    FakeSocket.instances.at(-1).update(server.version); settings.updateSettings({ background: "oled" }); await advance(5_000);
    assert.equal(server.puts.length, 1, "upgrade is not a retryable revision conflict");
    assert.ok(journalsFor(s).length, "new explicit edits are still durable while held");
    const other = makeSession(), nextServer = await serverFor(other); await admit(vault, other, account);
    await until(() => account.accountSyncStatus().appliedVersion === 20, "other account admitted");
    assert.equal(account.accountSyncStatus().upgradeRequired, undefined);
    settings.updateSettings({ accentID: "royal" }); await advance(800);
    assert.equal(nextServer.puts.length, 1); assert.ok(journalsFor(s).length, "old account's retained intent remains separate");
  });

  await t.test("add-on failure retries exact descriptor/removal intent and retains edits arriving during PUT", async () => {
    await clean(); const s = makeSession(); const preserved = { transportUrl: "https://old.test/manifest.json", manifest: { id: "old" }, foreign: 7 };
    const server = await serverFor(s, { ...legacyDoc(), addons: [preserved], nativeExtension: { future: "opaque" }, providerExtension: { keep: true } });
    await admit(vault, s, account); account.applySyncDoc(legacyDoc());
    const url = "https://addons.test:443/A/../B/manifest.json?Token=AbC";
    await store.addAddon(url); store.removeAddon(preserved.transportUrl);
    const release = server.holdPut(); server.fail(); await advance(350);
    await until(() => server.puts.length === 1, "first addon PUT");
    const second = "https://addons.test:443/A/../B/manifest.json?Token=abc";
    await store.addAddon(second); release(); await settle(); await advance(1_000);
    await until(() => server.puts.length >= 2 && journalsFor(s).length === 0, "durable addon retry and follow-on edit");
    const doc = await server.read();
    assert.ok(doc.addons.some((a) => a.transportUrl === url)); assert.ok(doc.addons.some((a) => a.transportUrl === second));
    assert.ok(!doc.addons.some((a) => a.transportUrl === preserved.transportUrl));
    assert.deepEqual(doc.nativeExtension, { future: "opaque" }); assert.deepEqual(doc.providerExtension, { keep: true });
    assert.equal(server.maxPuts, 1);
  });

  await t.test("progress captures owner/overlay scopes, failed settings cannot starve it, and inherited titles are not swept", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s, { foreign: true });
    await admit(vault, s, account);
    local.set("vortx.web.cw.v1", JSON.stringify([{ id: "foreign-title", type: "movie", name: "Foreign", resumeId: "foreign-title", position: 10, duration: 100, updatedAt: now }]));
    settings.updateSettings({ accentID: "gold" }); // No main profile: settings must remain pending.
    store.recordProgress({ id: "owner-title", type: "movie", name: "Owner" }, 20, 100);
    const overlay = profiles.addProfile("Synthetic overlay", "🦊");
    store.recordProgress({ id: "overlay-title", type: "movie", name: "Overlay" }, 30, 100);
    await advance(1_000); const doc = await server.read();
    assert.deepEqual(doc.webProgress.owner.map((e) => e.id), ["owner-title"]);
    assert.deepEqual(doc.webProgress.byProfile[overlay.id].map((e) => e.id), ["overlay-title"]);
    assert.ok(journalsFor(s).some(([, raw]) => JSON.parse(raw).settings.accentID === "gold"), "missing-main settings remain queued");
    assert.ok(!JSON.stringify(doc).includes("foreign-title")); assert.equal(server.maxPuts, 1);
  });

  await t.test("reload/new tab recovers inactive journals but does not copy a live tab's pending snapshot", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s);
    await admit(vault, s, account); account.applySyncDoc(legacyDoc());
    settings.updateSettings({ accentID: "gold" });
    const [key, raw] = journalsFor(s)[0], priorOwner = JSON.parse(local.get(key + ".owner"));
    assert.equal(typeof priorOwner.id, "string"); assert.ok(priorOwner.until > now, "captured journal initially belongs to a live old page");
    await account.signOut(); timers.clear(); // Retire the old page/account; its queued intent remains durable.
    const releasedRaw = local.get(key + ".owner"), released = JSON.parse(releasedRaw);
    assert.equal(local.get(key), raw, "signout preserves the exact pending journal");
    assert.equal(released.id, priorOwner.id); assert.equal(released.until, 0, "old page released, not expired or deleted");
    session.delete("vortx.web.sync-client.v1");
    const bootTime = now, reloaded = await reloadAccountGraph(s);
    assert.equal(local.get(key), raw, "boot seed/import does not rewrite pending intent");
    assert.equal(local.get(key + ".owner"), releasedRaw, "no old-graph re-adoption reclaimed the released lease");
    assert.equal(reloaded.currentSession().account.id, s.account.id);
    const claimed = JSON.parse(local.get(key + ".owner"));
    assert.notEqual(claimed.id, released.id, "the fresh graph alone claims the released journal");
    assert.equal(now, bootTime, "handoff needs no artificial expiry"); assert.equal(claimed.until, bootTime + 30_000);
    assert.equal(local.get(key), raw, "claim does not replace the captured edit");
    await advance(350); await until(() => server.puts.length === 1, "new-tab retry from retained journal");
    assert.equal((await server.read()).profileEdits.roster[0].settings.accent, "gold");
    assert.equal(local.get(key), undefined); await reloaded.signOut(); timers.clear(); account = reloaded;

    const liveKey = key + "-live";
    local.set(liveKey, raw);
    const liveOwnerRaw = JSON.stringify({ id: "another-live-page", until: now + 30_000 });
    local.set(liveKey + ".owner", liveOwnerRaw);
    await admit(vault, s, account); await advance(800);
    assert.equal(server.puts.length, 1, "live owner's old snapshot cannot be copied and replayed");
    assert.equal(local.get(liveKey), raw, "live owner's pending journal stays byte-identical");
    assert.equal(local.get(liveKey + ".owner"), liveOwnerRaw, "live ownership is neither stolen nor expired");
    local.delete(liveKey); local.delete(liveKey + ".owner");
  });

  await t.test("account switch fences delayed GET/manifest completions and keeps A's journal away from B", async () => {
    await clean(); const a = makeSession(); const first = await serverFor(a);
    await admit(vault, a, account); const releaseGet = first.holdGet(); stop = account.startAccountSync();
    settings.updateSettings({ accentID: "gold" });
    let releaseManifest;
    const pendingManifest = new Promise((r) => { releaseManifest = r; });
    globalThis.fetch = (url, init) => String(url).startsWith("https://slow.test/") ? pendingManifest : first.fetch(url, init);
    const install = store.addAddon("https://slow.test/manifest.json");
    const rejected = assert.rejects(install, /Account changed/);
    const b = makeSession(); const second = await serverFor(b, legacyDoc("ocean"));
    await admit(vault, b, account); releaseGet(); releaseManifest(json({ id: "slow", name: "Slow" }));
    await rejected; await until(() => account.accountSyncStatus().receivedVersion === 20, "account B catch-up");
    await advance(1_000);
    assert.equal(settings.getSettings().accentID, "ocean"); assert.equal(second.puts.length, 0);
    assert.ok(journalsFor(a).length); assert.equal(journalsFor(b).length, 0);
    assert.ok(!store.installedUrls().includes("https://slow.test/manifest.json"));
  });

  await t.test("native fields mark received separately from applied without causing a full-GET loop", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s, { ...legacyDoc(), nativeSync: { schemaVersion: 1, opaque: true } });
    await admit(vault, s, account); stop = account.startAccountSync();
    await until(() => account.accountSyncStatus().receivedVersion === 20, "native encrypted document received");
    assert.deepEqual(account.accountSyncStatus(), { receivedVersion: 20, appliedVersion: undefined, projectionPending: true });
    await advance(3_000); assert.equal(server.requests.at(-1).headers["if-none-match"], '"20"');
    assert.equal(server.puts.length, 0);
  });

  await t.test("a stalled mutation times out and retries its durable intent without blocking the writer", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s);
    await admit(vault, s, account); account.applySyncDoc(legacyDoc());
    let hung = false; let aborted = false;
    globalThis.fetch = (url, init = {}) => {
      if (!hung && String(url).endsWith("/v1/backup") && (init.method ?? "GET") === "GET") {
        hung = true;
        return new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => {
          aborted = true; reject(new DOMException("Synthetic timeout", "AbortError"));
        }, { once: true }));
      }
      return server.fetch(url, init);
    };
    settings.updateSettings({ accentID: "royal" }); await advance(800);
    assert.ok(hung); assert.equal(server.puts.length, 0);
    await advance(15_000); assert.ok(aborted, "mutation GET has a bounded deadline");
    assert.ok(journalsFor(s).length, "timeout never drops the queued edit");
    await advance(1_000); await until(() => server.puts.length === 1, "automatic retry after timeout");
    assert.equal((await server.read()).profileEdits.roster[0].settings.accent, "royal");
    assert.equal(journalsFor(s).length, 0);
  });

  await t.test("a resumed page retires its old snapshot after another page recovered and ACKed the journal", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s);
    await admit(vault, s, account); account.applySyncDoc(legacyDoc());
    settings.updateSettings({ accentID: "gold" });
    const [key] = journalsFor(s)[0];
    timers.clear(); // The original page is suspended before its debounce fires.
    local.set(key + ".owner", JSON.stringify({ id: "recovering-page", until: now + 30_000 }));
    await vault.mutateSyncDoc(s, (doc) => { doc.vortx.profiles[0].settings.accent = "gold"; });
    await vault.mutateSyncDoc(s, (doc) => { doc.vortx.profiles[0].settings.accent = "royal"; });
    local.delete(key);
    local.set(key + ".owner", JSON.stringify({ id: "recovering-page", until: 0 }));
    stop = account.startAccountSync();
    await until(() => settings.getSettings().accentID === "royal", "resumed page applies the newest ACKed value");
    await advance(3_000);
    assert.equal(server.puts.length, 2, "the original gold snapshot cannot replay after ownership cleanup");
    assert.equal(journalsFor(s).length, 0);
  });

  await t.test("active fallback polling recovers a crashed page's journal when its lease expires", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s);
    const key = `vortx.web.sync-intents.v1.${s.account.id}.synthetic-crashed-page`;
    local.set(key, JSON.stringify({ accountId: s.account.id, editedAt: now, revision: 1,
      settings: { accentID: "royal" }, addons: {}, progress: {} }));
    local.set(key + ".owner", JSON.stringify({ id: "synthetic-crashed-page", until: now + 5_000 }));
    await admit(vault, s, account); stop = account.startAccountSync(); await settle();
    await advance(3_000); assert.equal(server.puts.length, 0, "unexpired ownership is respected");
    await advance(3_350); await until(() => server.puts.length === 1, "expired orphan automatically recovered");
    assert.equal((await server.read()).profileEdits.roster[0].settings.accent, "royal");
    assert.equal(settings.getSettings().accentID, "royal"); assert.equal(local.get(key), undefined);
  });

  await t.test("an owner-library-only receive signals a live UI refresh without echoing an upload", async () => {
    await clean(); const s = makeSession(); const server = await serverFor(s);
    await admit(vault, s, account); stop = account.startAccountSync(); await settle();
    let changes = 0; const changed = () => changes++;
    window.addEventListener("vortx:addons-changed", changed);
    const doc = legacyDoc(); doc.vortx.library = [{ id: "remote-library-only", type: "movie", name: "Synced title" }];
    await server.remote(doc); FakeSocket.instances.at(-1).update(server.version);
    await until(() => changes === 1, "owner library UI refresh event");
    window.removeEventListener("vortx:addons-changed", changed);
    assert.ok(store.libraryItems().some((item) => item.id === "remote-library-only"));
    assert.equal(server.puts.length, 0);
  });

  await t.test("actual native export reaches live Library, Watchlist, CW, profiles and add-ons through a socket update", async () => {
    await clean(); const s = makeSession(); s.account.id = "sync-fixture";
    const initial = structuredClone(nativeFixture.cases[0].document);
    const server = await serverFor(s, initial);
    local.set("vortx.web.library.v1", JSON.stringify([{ id: "foreign-local-save", type: "movie", name: "Other account" }]));
    await admit(vault, s, account); stop = account.startAccountSync();
    await until(() => account.accountSyncStatus().appliedVersion === 20, "compatible native projection applied");
    assert.equal(account.accountSyncStatus().projectionPending, false);
    assert.deepEqual(store.nativeWatchlistItems().map((item) => item.id), ["tt-watchlist"]);
    assert.deepEqual(store.nativeLibraryItems().map((item) => item.id), ["tt-saved"]);
    assert.deepEqual(store.continueWatching().map((item) => [item.id, item.resumeId, item.position, item.duration, item.updatedAt]),
      [["tt-saved", "tt-saved:1:2", 120, 1200, 1791497839000]], "milliseconds/playhead and seconds/activity are converted exactly once");
    assert.equal(store.cwPosition("tt-saved:1:2"), 120);
    assert.deepEqual(store.browserLibraryItems(), [], "inherited local saves are not another account's native Library");
    const host = { innerHTML: "" }; renderLibrary(host);
    assert.match(host.innerHTML, /Account Watchlist/); assert.match(host.innerHTML, /Account Library/);
    assert.match(host.innerHTML, /Saved in this browser/); assert.ok(!host.innerHTML.includes("foreign-local-save"));
    const owner = initial.nativeSync.ownerProfileId;
    const updated = structuredClone(nativeFixture.cases[1].document);
    updated.nativeSync.libraries[owner] = { records: {}, order: { ids: [], updatedAt: 2000000000 } };
    updated.nativeSync.watches[owner].log["tt-saved:1:2"].removed_at = 2000000000;
    updated.nativeHostPreferences.profiles[owner].fields["watchlist.movie.dHQtd2F0Y2hsaXN0"].value = null;
    updated.nativeHostPreferences.profiles[owner].fields["watchlist.movie.dHQtd2F0Y2hsaXN0"].clock++;
    updated.vortx = { profiles: [{ id: "stale-profile", name: "Stale profile" }], library: [{ id: "stale-legacy-title", type: "movie", name: "Stale" }] };
    await server.remote(updated); FakeSocket.instances.at(-1).update(server.version);
    await until(() => account.accountSyncStatus().appliedVersion === 21, "native update applies immediately");
    assert.deepEqual(store.nativeLibraryItems(), []); assert.deepEqual(store.nativeWatchlistItems(), []); assert.deepEqual(store.continueWatching(), []);
    assert.ok(profiles.profiles().some((profile) => profile.name === "Renamed on Android"));
    assert.ok(!profiles.profiles().some((profile) => profile.id === "stale-profile"));
    assert.ok(!store.installedUrls().includes("https://fixture.invalid/one/manifest.json"));
    assert.equal(server.puts.length, 0, "native read-down never edits native/legacy channels or echoes upload");
  });

  await t.test("native own-account rebinding fences queued progress, delayed manifests, local saves and account switch", async () => {
    await clean(); const s = makeSession(); s.account.id = "website-own-slot-fixture";
    const ownA = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("03-own-A"));
    const ownB = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("04-own-B"));
    const server = await serverFor(s, structuredClone(ownA.document));
    await admit(vault, s, account); account.applySyncDoc(ownA.document);
    const viewer = ownA.playback.profileId.toUpperCase(); profiles.setActiveProfile(viewer);
    assert.deepEqual(store.nativeLibraryItems().map((row) => row.id), ["tt-own-a-only"]);
    store.toggleLibrary({ id: "own-a-browser-save", type: "movie", name: "A browser save" });
    store.recordProgress({ id: "own-a-edited", type: "movie", name: "A dirty edit" }, 20, 100);
    assert.ok(store.continueWatching().some((row) => row.id === "own-a-edited"));
    const fetch = globalThis.fetch; let release; const manifest = new Promise((resolve) => { release = resolve; });
    globalThis.fetch = (url, init) => String(url).startsWith("https://slow-native.test/") ? manifest : fetch(url, init);
    const install = store.addAddon("https://slow-native.test/manifest.json");
    await server.remote(structuredClone(ownB.document)); account.applySyncDoc(ownB.document);
    assert.deepEqual(store.nativeLibraryItems().map((row) => row.id), ["tt-own-b-only"]);
    assert.deepEqual(store.browserLibraryItems(), []); assert.ok(!store.continueWatching().some((row) => row.id === "own-a-edited"));
    release(json({ id: "slow-native", name: "Slow", version: "1", resources: [], types: [], catalogs: [] }));
    await assert.rejects(install, /Account changed/);
    await advance(1_000); assert.equal(server.puts.length, 0, "A's dirty progress is not written into B's active account slot");
    assert.ok(journalsFor(s).some(([, raw]) => raw.includes("own-a-edited")), "unacknowledged original-slot intent stays durable");
    const other = makeSession(); await admit(vault, other, account);
    assert.equal(store.hasNativeAccountProjection(), false); assert.ok(!store.libraryItems().some((row) => row.id === "tt-own-b-only"));
  });

  await t.test("native-valid zero resume remains visible, and protected native profiles cannot activate browser resources", async () => {
    await clean(); const sample = nativeFixture.edgeCases.find((sample) => sample.source.startsWith("01-zero"));
    const s = makeSession(); s.account.id = sample.document.nativeSync.scope.replace(/^account\./, "");
    await admit(vault, s, account); account.applySyncDoc(sample.document);
    assert.equal(store.continueWatching().length, 1); assert.equal(store.continueWatching()[0].position, 0);
    const document = structuredClone(sample.document), owner = document.nativeSync.ownerProfileId;
    document.nativeSync.profiles[owner].profile.pin = "synthetic-pin";
    account.applySyncDoc(document);
    assert.deepEqual(store.continueWatching(), []); assert.deepEqual(store.nativeLibraryItems(), []); assert.deepEqual(store.installedUrls(), []);
  });

  await t.test("native settings/add-on/progress intent survives missing carrier while independent metadata keys ACK", async () => {
    await clean(); const s = makeSession();
    const doc = structuredClone(nativeFixture.cases[0].document);
    doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
    doc.vortx = legacyDoc().vortx; // A retained historical main is not native settings authority.
    doc.nativeProviderCredentials = { opaque: "synthetic-retained-carrier" };
    const server = await serverFor(s, doc);
    await admit(vault, s, account); account.applySyncDoc(doc);
    settings.updateSettings({ accentID: "royal", tmdbKey: "synthetic-metadata-key" });
    await store.addAddon("https://native-held.test/manifest.json");
    store.recordProgress({ id: "native-held-progress", type: "movie", name: "Native browser progress" }, 20, 100);
    await advance(1_000); await until(() => server.puts.length === 2, "profile event publication and independent metadata ACK");
    assert.equal(server.puts.length, 2, "profile publication is not a native receipt; metadata ACK is independent");
    const accepted = await server.read();
    assert.equal(accepted.apiKeys.tmdb, "synthetic-metadata-key");
    assert.deepEqual(accepted.nativeSync, doc.nativeSync); assert.deepEqual(accepted.nativeHostPreferences, doc.nativeHostPreferences);
    assert.deepEqual(accepted.nativeProviderCredentials, doc.nativeProviderCredentials); assert.equal(accepted.profileEdits, undefined);
    assert.equal(accepted.webProgress, undefined);
    assert.equal(accepted.profileEditEvents.events[0].roster[0].settings.accent, "royal");
    assert.ok(journalsFor(s).some(([, raw]) => raw.includes("native-held-progress") && raw.includes("native-held.test") && raw.includes("royal")));
    const missing = { ...legacyDoc(), foreign: { preserve: true } };
    await server.remote(missing); await advance(3_000);
    assert.equal(server.puts.length, 2, "binding-captured edits cannot fall through to a missing native carrier");
    assert.ok(journalsFor(s).length);
    await account.signOut(); timers.clear(); await admit(vault, s, account); account.applySyncDoc(doc);
    assert.equal(settings.getSettings().accentID, "royal", "native dirty settings survive account re-adoption");
    await advance(1_000); assert.equal(server.puts.length, 2); assert.ok(journalsFor(s).length);
  });

  await t.test("pre-hydration unbound browser progress cannot be attributed or ACKed by a native carrier", async () => {
    await clean(); const s = makeSession();
    const doc = structuredClone(nativeFixture.cases[0].document);
    doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
    const server = await serverFor(s, doc);
    await admit(vault, s, account);
    store.recordProgress({ id: "unbound-before-first-pull", type: "movie", name: "Unbound" }, 20, 100);
    account.applySyncDoc(doc); await advance(1_000);
    assert.equal(server.puts.length, 0);
    assert.ok(journalsFor(s).some(([, raw]) => raw.includes("unbound-before-first-pull")));
    assert.ok(!store.continueWatching().some((row) => row.id === "unbound-before-first-pull"));
  });

  await t.test("native equal removal/resume clock retains the CABI-accepted CW row in the real browser store", async () => {
    await clean(); const doc = structuredClone(nativeFixture.edgeCases.find((sample) => sample.source.startsWith("01-zero")).document);
    const s = makeSession(); s.account.id = doc.nativeSync.scope.replace(/^account\./, "");
    const owner = doc.nativeSync.ownerProfileId, state = Object.values(doc.nativeSync.watches[owner].log)[0];
    Object.assign(state, { resume_at: 100, removed_at: 100, resume_ms: 1, watched_at: 0, reset_at: 0 });
    await admit(vault, s, account); account.applySyncDoc(doc);
    assert.equal(store.continueWatching().length, 1); assert.equal(store.continueWatching()[0].position, .001);
    store.clearProgress(store.continueWatching()[0].id); assert.deepEqual(store.continueWatching(), [], "explicit browser removal is a separate pending overlay");
  });

  await t.test("real player progress listeners retain start-time admission across own-slot and account changes", async () => {
    await clean(); const ownA = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("03-own-A"));
    const ownB = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("04-own-B"));
    const s = makeSession(); s.account.id = "website-own-slot-fixture";
    const server = await serverFor(s, ownA.document); await admit(vault, s, account); account.applySyncDoc(ownA.document);
    profiles.setActiveProfile(ownA.playback.profileId.toUpperCase());
    const video = Object.assign(new EventTarget(), { currentTime: 20, duration: 100 });
    player.__playerTestHooks.wireProgress(video, { id: "playing-under-A", type: "movie", name: "A movie" }, store.captureProgressAdmission());
    video.dispatchEvent(new Event("timeupdate"));
    assert.ok(store.continueWatching().some((row) => row.id === "playing-under-A"));
    await server.remote(ownB.document); account.applySyncDoc(ownB.document); await advance(5_001);
    video.currentTime = 35; video.dispatchEvent(new Event("timeupdate")); video.dispatchEvent(new Event("ended"));
    assert.ok(!store.continueWatching().some((row) => row.id === "playing-under-A"));
    const [journal] = journalsFor(s).map(([, raw]) => JSON.parse(raw));
    assert.equal(Object.values(journal.progress).flatMap((intent) => intent.entries).find((row) => row.id === "playing-under-A").t, 20);
    assert.equal(server.puts.length, 0);
    const other = makeSession(); await admit(vault, other, account); await advance(5_001);
    video.dispatchEvent(new Event("timeupdate")); video.dispatchEvent(new Event("ended"));
    assert.equal(journalsFor(other).length, 0); assert.ok(!store.continueWatching().some((row) => row.id === "playing-under-A"));
  });

  await t.test("native look intent stays durable in its exact profile and binding, never in inherited local roster", async () => {
    await clean(); const ownA = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("03-own-A"));
    const ownB = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("04-own-B"));
    const s = makeSession(); s.account.id = "website-own-slot-fixture"; await serverFor(s, ownA.document);
    await admit(vault, s, account); account.applySyncDoc(ownA.document);
    const viewer = ownA.playback.profileId.toUpperCase(); profiles.setActiveProfile(viewer);
    const originalRoster = local.get("vortx.web.profiles.v1");
    settings.updateSettings({ accentID: "crimson", audioLang: "fr" });
    account.applySyncDoc(ownA.document); assert.equal(settings.getSettings().accentID, "crimson");
    assert.equal(settings.getSettings().audioLang, "fr");
    account.applySyncDoc(ownB.document); assert.notEqual(settings.getSettings().accentID, "crimson");
    assert.notEqual(settings.getSettings().audioLang, "fr");
    await account.signOut(); timers.clear(); await admit(vault, s, account); account.applySyncDoc(ownA.document); profiles.setActiveProfile(viewer);
    assert.equal(settings.getSettings().accentID, "crimson"); assert.equal(settings.getSettings().audioLang, "fr");
    assert.equal(local.get("vortx.web.profiles.v1"), originalRoster);
    const roster = JSON.stringify(profiles.profiles());
    assert.throws(() => profiles.addProfile("Unsafe local-only native profile", "🦊"));
    profiles.updateProfileMeta(viewer, { name: "Unsafe rename" }); profiles.deleteProfile(viewer);
    assert.equal(JSON.stringify(profiles.profiles()), roster);
  });

  await t.test("public host settings project supported values without echo and malformed carriers quarantine native resources", async () => {
    await clean(); const s = makeSession(), doc = structuredClone(nativeFixture.cases[0].document);
    doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
    const owner = doc.nativeSync.ownerProfileId, fields = doc.nativeHostPreferences.profiles[owner].fields;
    const actor = fields.avatar.actor;
    fields.playback = { clock: 3, actor, value: { audioLang: "fr", subtitleLang: "en", forcedPolicy: "off", useAddonOrder: true, sourceTypeOrder: ["direct", "debrid"] } };
    doc.nativeHostPreferences.globals.fields = {
      "stremiox.autoplayTrailers": { clock: 4, actor, value: false },
      "stremiox.directLinksOnly": { clock: 5, actor, value: true },
      "stremiox.performanceMode": { clock: 6, actor, value: "reduced" },
    };
    const server = await serverFor(s, doc); await admit(vault, s, account); assert.equal(account.applySyncDoc(doc), true, "known supported host projection applies");
    profiles.setActiveProfile(owner); // A prior synthetic session's remembered child is not this assertion target.
    const applied = settings.getSettings();
    assert.deepEqual([applied.accentID, applied.background, applied.textScale], ["ember", "warm", 1]);
    assert.deepEqual([applied.audioLang, applied.subtitleLang, applied.subtitlesMode, applied.useAddonOrder, applied.sourceOrder], ["fr", "en", "off", true, ["direct", "debrid"]]);
    assert.deepEqual([applied.autoplayTrailers, applied.directLinksOnly, applied.performance], [false, true, "reduced"]);
    await advance(1_000); assert.equal(server.puts.length, 0); assert.equal(journalsFor(s).length, 0);
    assert.ok(store.continueWatching().length);
    const malformed = structuredClone(doc); malformed.nativeSync.profiles[owner].profile.parental.kids = "invalid";
    assert.equal(account.applySyncDoc(malformed), false);
    assert.deepEqual(store.continueWatching(), []); assert.deepEqual(store.nativeLibraryItems(), []);
    assert.deepEqual(store.browserLibraryItems(), []); assert.deepEqual(store.installedUrls(), []);
    assert.throws(() => profiles.addProfile("Not a native profile", "🦊"));
    account.applySyncDoc(doc); assert.ok(store.continueWatching().length, "compatible native receive exits quarantine");
    doc.nativeSync.profiles[owner].profile.settings.disabledAddons = ["https://fixture.invalid/one/manifest.json"];
    account.applySyncDoc(doc); assert.ok(!store.installedUrls().includes("https://fixture.invalid/one/manifest.json"));
  });

  await t.test("non-look native settings preserve A and B deltas through metadata edits and reload", async () => {
    await clean(); const s = makeSession();
    // Derived from actual schema-4 active-slot exports. Only target placement is changed; no
    // native clocks are invented or written by the browser under test.
    const ownerSlot = (sample) => {
      const doc = structuredClone(sample.document), owner = doc.nativeSync.ownerProfileId, viewer = sample.playback.profileId;
      doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
      doc.nativeSync.profiles[owner].profile.account = structuredClone(doc.nativeSync.profiles[viewer].profile.account);
      doc.nativeSync.accountSlots[owner] = structuredClone(doc.nativeSync.accountSlots[viewer]);
      return doc;
    };
    const a = ownerSlot(nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("03-own-A")));
    const b = ownerSlot(nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("04-own-B")));
    const server = await serverFor(s, a); await admit(vault, s, account); assert.equal(account.applySyncDoc(a), true);
    const owner = a.nativeSync.ownerProfileId; profiles.setActiveProfile(owner);
    const orderA = ["torrent", "direct"], orderB = ["usenet", "debrid"];
    settings.updateSettings({ sourceOrder: orderA });
    await server.remote(b); account.applySyncDoc(b);
    settings.updateSettings({ tmdbKey: "synthetic-independent-metadata" });
    const pendingA = JSON.parse(journalsFor(s).at(-1)[1]);
    assert.deepEqual(pendingA.settings.sourceOrder, orderA, "unrelated B edit never copies B's live default over A's pending value");
    settings.updateSettings({ sourceOrder: orderB });
    const queued = JSON.parse(journalsFor(s).at(-1)[1]);
    assert.deepEqual(queued.settings.sourceOrder, orderB);
    assert.ok(Object.values(queued.retainedNativeSettings).some((delta) => JSON.stringify(delta.sourceOrder) === JSON.stringify(orderA)));
    account.applySyncDoc(a); assert.deepEqual(settings.getSettings().sourceOrder, orderA);
    account.applySyncDoc(b); assert.deepEqual(settings.getSettings().sourceOrder, orderB);
    await account.signOut(); timers.clear(); await admit(vault, s, account); account.applySyncDoc(a); profiles.setActiveProfile(owner);
    assert.deepEqual(settings.getSettings().sourceOrder, orderA, "retained A delta survives journal restore");
    account.applySyncDoc(b); assert.deepEqual(settings.getSettings().sourceOrder, orderB, "newest B delta survives journal restore");
  });

  const hostDoc = (s) => {
    const doc = structuredClone(nativeFixture.cases[0].document);
    doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
    doc.nativeProviderCredentials = { future: "synthetic opaque credentials carrier" };
    doc.futureCarrier = { unknown: ["retain", 7] };
    return doc;
  };
  const startNative = async (s, doc) => {
    const server = await serverFor(s, doc);
    await admit(vault, s, account); stop = account.startAccountSync();
    await until(() => account.accountSyncStatus().appliedVersion === 20, "native host document loaded");
    profiles.setActiveProfile(doc.nativeSync.ownerProfileId);
    return server;
  };
  const hostJournal = (s) => journalsFor(s).flatMap(([, raw]) => Object.values(JSON.parse(raw).host ?? {}));
  const profileJournal = (s) => journalsFor(s).flatMap(([, raw]) => Object.values(JSON.parse(raw).profile ?? {}));
  const fullPlayback = { audioLang: "en", subtitleLang: "hi", forcedPolicy: "always", subFont: "modern", subSize: "m", subColor: "white", subBackground: "outline",
    subBrightness: "100", preferKeywords: "retained-preference", futurePlayback: { opaque: true } };
  const playbackDoc = (s) => {
    const doc = hostDoc(s), owner = doc.nativeSync.ownerProfileId;
    doc.nativeHostPreferences.profiles[owner].fields.playback = { clock: 10, actor: "11111111-1111-4111-8111-111111111111", value: structuredClone(fullPlayback) };
    return doc;
  };

  await t.test("full native playback register carries keyword/filter controls and preserves authenticated unmodeled siblings", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc);
    settings.updateSettings({ hideWords: "cam,screener", requireWords: "dual", sourceOrder: ["torrent", "debrid"], safetyFilter: "strict", subtitleScale: 1.2 });
    assert.equal(hostJournal(s).filter((edit) => "playback" in edit.intent.fields).length, 1);
    await advance(900);
    const accepted = await server.read(), value = accepted.nativeHostPreferences.profiles[doc.nativeSync.ownerProfileId].fields.playback.value;
    assert.equal(value.excludeKeywords, "cam,screener"); assert.equal(value.includeKeywords, "dual"); assert.equal(value.safetyMode, "strict");
    assert.deepEqual(value.sourceTypeOrder, ["torrent", "debrid"]); assert.equal(value.subSizeScale, 1.2);
    for (const [key, expected] of Object.entries(fullPlayback)) assert.deepEqual(value[key], expected);
    assert.deepEqual(accepted.nativeSync, doc.nativeSync); assert.equal(accepted.profileEdits, undefined);
    assert.equal(hostJournal(s).length, 0); assert.equal(journalsFor(s).length, 0);
    assert.equal(settings.getSettings().hideWords, "cam,screener"); assert.equal(server.puts.length, 1);
  });

  await t.test("lost playback PUT response and definite stale rejection retain full-register identity and fresh siblings", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc), owner = doc.nativeSync.ownerProfileId;
    server.losePutResponse(); settings.updateSettings({ hideWords: "first" }); await advance(900);
    const planned = structuredClone(hostJournal(s)[0].intent.registers);
    await advance(1200); assert.equal(hostJournal(s).length, 0); assert.equal(server.puts.length, 1);
    assert.deepEqual((await server.read()).nativeHostPreferences.profiles[owner].fields.playback, planned.playback);
    settings.updateSettings({ requireWords: "second" }); const release = server.holdPut();
    const advanceWrite = advance(900); await until(() => server.puts.length === 2, "held playback write");
    const peer = await server.read(); peer.nativeHostPreferences.profiles[owner].fields.playback = { clock: 900,
      actor: "ffffffff-ffff-ffff-ffff-ffffffffffff", value: { ...peer.nativeHostPreferences.profiles[owner].fields.playback.value, subBrightness: "85", peerOnly: "preserve" } };
    await server.remote(peer); release(); await advanceWrite;
    const value = (await server.read()).nativeHostPreferences.profiles[owner].fields.playback.value;
    assert.equal(value.includeKeywords, "second"); assert.equal(value.excludeKeywords, "first"); assert.equal(value.subBrightness, "85"); assert.equal(value.peerOnly, "preserve");
    assert.equal(hostJournal(s).length, 0); assert.equal(server.puts.length, 3);
  });

  await t.test("six-field native look event remains pending after publication and retires only exact paired native receipt", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc), owner = doc.nativeSync.ownerProfileId;
    settings.updateSettings({ accentID: "royal", background: "oled", textScale: 1.15, audioLang: "fr", subtitleLang: "es", subtitlesMode: "off" });
    assert.equal(profileJournal(s).length, 1); await advance(900);
    const published = await server.read(), event = published.profileEditEvents.events[0];
    assert.deepEqual(event.roster[0].settings, { accent: "royal", oled: true, textScale: 1.15, playback: { audioLang: "fr", subtitleLang: "es", forced: "off" } });
    assert.equal(profileJournal(s).length, 1, "encrypted PUT alone never ACKs native semantics");
    await advance(3100); assert.equal(server.puts.length, 1, "already-published pending event never echoes another PUT");
    const fingerprint = profileEditEventFingerprintSync(event, { scope: published.nativeSync.scope, ownerProfileId: owner });
    published.nativeSync.legacyProfileEditReceipts = { [fingerprint]: { schemaVersion: 1, eventId: "different-event", source: { fingerprint } } };
    await server.remote(published); await advance(3100); assert.equal(profileJournal(s).length, 1, "mismatched receipt cannot retire intent");
    const accepted = await server.read();
    accepted.nativeSync.legacyProfileEditReceipts[fingerprint] = { schemaVersion: 1, eventId: event.eventId, source: { fingerprint, editedAtMs: event.editedAt, observedNativeClock: event.observedNativeClock } };
    Object.assign(accepted.nativeSync.profiles[owner].profile.settings, { accent: "royal", oled: true, textScale: 1150 });
    accepted.nativeHostPreferences.profiles[owner].fields.playback = { clock: event.observedHostClock + 1, actor: event.eventId,
      value: { ...fullPlayback, audioLang: "fr", subtitleLang: "es", forcedPolicy: "off" } };
    await server.remote(accepted); await advance(7000);
    assert.equal(profileJournal(s).length, 0); assert.equal(journalsFor(s).length, 0); assert.equal(server.puts.length, 1);
    assert.equal(settings.getSettings().accentID, "royal"); assert.equal(settings.getSettings().audioLang, "fr");
    assert.ok(![...local.keys()].some((key) => key.includes(".look-intent.") && key.includes(encodeURIComponent(`account.${s.account.id}`))));
  });

  await t.test("published native look survives lost response and reload with immutable event bytes, not new IDs", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc);
    server.losePutResponse(); settings.updateSettings({ accentID: "ocean" }); await advance(900);
    const planned = structuredClone(profileJournal(s)[0].intent.event); assert.ok(planned);
    stop(); stop = undefined; await account.signOut(); timers.clear();
    account = await reloadAccountGraph(); await admit(vault, s, account); stop = account.startAccountSync(); await advance(4000);
    assert.deepEqual(profileJournal(s)[0].intent.event, planned);
    assert.equal((await server.read()).profileEditEvents.events.length, 1); assert.equal(server.puts.length, 1);
    assert.ok(journalsFor(s).length);
  });

  await t.test("exact profile receipt retires matching retained migration values but preserves newer values and another binding", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc), owner = doc.nativeSync.ownerProfileId;
    settings.updateSettings({ accentID: "royal", audioLang: "fr" }); await advance(900);
    const edit = profileJournal(s)[0], target = `${owner}|${edit.intent.target.binding}`;
    const otherBinding = `${owner}|${JSON.stringify({ account: { kind: "own", value: "0123456789abcdef01234567" }, revision: 1, transactionId: null })}`;
    const [journalKey, raw] = journalsFor(s).at(-1), journal = JSON.parse(raw);
    journal.retainedNativeSettings = { [target]: { accentID: "royal", audioLang: "newer-language" }, [otherBinding]: { accentID: "ember" } };
    stop(); stop = undefined; await account.signOut(); timers.clear();
    local.set(journalKey, JSON.stringify(journal));
    account = await reloadAccountGraph(); await admit(vault, s, account); stop = account.startAccountSync(); await advance(1000);
    assert.equal(profileJournal(s)[0].intent.event.eventId, edit.intent.event.eventId, "reload restores the exact originally published event");
    const accepted = await server.read(), event = accepted.profileEditEvents.events[0];
    const fingerprint = profileEditEventFingerprintSync(event, { scope: accepted.nativeSync.scope, ownerProfileId: owner });
    accepted.nativeSync.legacyProfileEditReceipts = { [fingerprint]: { schemaVersion: 1, eventId: event.eventId,
      source: { fingerprint, editedAtMs: event.editedAt, observedNativeClock: event.observedNativeClock } } };
    accepted.nativeSync.profiles[owner].profile.settings.accent = "royal";
    accepted.nativeHostPreferences.profiles[owner].fields.playback = { clock: event.observedHostClock + 1, actor: event.eventId, value: { ...fullPlayback, audioLang: "fr" } };
    await server.remote(accepted); await advance(7000);
    const retained = JSON.parse(journalsFor(s).at(-1)[1]).retainedNativeSettings;
    const pending = profileJournal(s);
    assert.ok(pending.every((entry) => entry.intent.event?.eventId !== event.eventId), "accepted historical edit cannot remain queued");
    assert.deepEqual(pending[0]?.look, { audioLang: "newer-language" }, "newer same-binding explicit migration value remains an independent pending intent");
    assert.deepEqual(retained[target], { audioLang: "newer-language" });
    assert.deepEqual(retained[otherBinding], { accentID: "ember" }); assert.equal(settings.getSettings().audioLang, "newer-language");
    const remainingLook = [...local.entries()].filter(([key]) => key.includes(".look-intent.") && key.includes(encodeURIComponent(`account.${s.account.id}`)));
    assert.deepEqual(remainingLook.map(([, raw]) => JSON.parse(raw)), [{ audioLang: "newer-language" }]);
  });

  await t.test("published language event is not deadlocked by a later keyword register intent", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc), owner = doc.nativeSync.ownerProfileId;
    settings.updateSettings({ audioLang: "fr" }); await advance(900);
    const published = await server.read(), event = published.profileEditEvents.events[0];
    settings.updateSettings({ hideWords: "cam" }); await advance(900);
    assert.equal(server.puts.length, 1); assert.equal(hostJournal(s).length, 1); assert.equal(profileJournal(s).length, 1);
    const fingerprint = profileEditEventFingerprintSync(event, { scope: published.nativeSync.scope, ownerProfileId: owner });
    published.nativeSync.legacyProfileEditReceipts = { [fingerprint]: { schemaVersion: 1, eventId: event.eventId,
      source: { fingerprint, editedAtMs: event.editedAt, observedNativeClock: event.observedNativeClock } } };
    published.nativeHostPreferences.profiles[owner].fields.playback = { clock: event.observedHostClock + 1, actor: event.eventId, value: { ...fullPlayback, audioLang: "fr" } };
    await server.remote(published); await advance(7000);
    const final = (await server.read()).nativeHostPreferences.profiles[owner].fields.playback.value;
    assert.equal(final.audioLang, "fr"); assert.equal(final.excludeKeywords, "cam");
    assert.equal(profileJournal(s).length, 0); assert.equal(hostJournal(s).length, 0); assert.equal(server.puts.length, 2);
  });

  await t.test("restored immutable plans fail closed for unintended profile mutations and malformed full native DTOs", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), owner = doc.nativeSync.ownerProfileId;
    const view = projectNativeSync(doc, `account.${s.account.id}`), profile = view.profiles.find((row) => row.id === owner);
    const target = { scope: view.scope, ownerProfileId: owner, profileId: owner, binding: profile.binding };
    const actor = "22222222-2222-4222-8222-222222222222";
    const host = createHostIntent(target, { playback: { excludeKeywords: "cam" } }, false, actor);
    applyHostIntent(structuredClone(doc), host, 0);
    for (const [field, value] of [["useAddonOrder", "bad"], ["maxResolution", 2147483648], ["sourceTypeOrder", ["direct", 1]]]) {
      const invalid = structuredClone(host), candidate = structuredClone(doc); invalid.registers.playback.value[field] = value;
      assert.throws(() => applyHostIntent(candidate, invalid, 0)); assert.deepEqual(candidate, doc);
    }
    const look = createProfileIntent(target, { accent: "royal", playback: { audioLang: "fr" } });
    await applyProfileIntent(structuredClone(doc), look);
    for (const corrupt of [(event) => { event.roster[0].deleted = true; }, (event) => { event.roster[0].name = "Injected"; },
      (event) => { event.libraryAdds = []; }, (event) => { event.hostBases[owner].playback.extra = true; }]) {
      const invalid = structuredClone(look), candidate = structuredClone(doc); corrupt(invalid.event);
      await assert.rejects(applyProfileIntent(candidate, invalid)); assert.deepEqual(candidate, doc);
    }
    const addon = { target, mutations: [{ url: "https://planned-addon.test/manifest.json", added: true, descriptor: { transportUrl: "https://planned-addon.test/manifest.json", name: "Synthetic", manifest: { id: "synthetic", name: "Synthetic", version: "1.0.0", types: [], catalogs: [], resources: [] } } }] };
    applyAddonEventIntent(structuredClone(doc), addon);
    for (const corrupt of [(event) => { event.counter = 1; }, (event) => { event.counter = ["1"]; }, (event) => { event.eventId = [event.eventId]; },
      (event) => { event.observed = {}; }, (event) => { event.observed.order.updatedAt = "1"; }, (event) => { event.mutations[0].extra = true; },
      (event) => { event.mutations[0].addon.flags.official = true; }]) {
      const invalid = structuredClone(addon), candidate = structuredClone(doc); corrupt(invalid.event);
      assert.throws(() => applyAddonEventIntent(candidate, invalid)); assert.deepEqual(candidate, doc);
    }
    const remove = { target, mutations: [{ url: "https://planned-addon.test/manifest.json", added: false }] };
    applyAddonEventIntent(structuredClone(doc), remove); remove.event.mutations[0].addon = {};
    assert.throws(() => applyAddonEventIntent(structuredClone(doc), remove));
    for (const extension of [{ token: "synthetic" }, { apiKey: "synthetic" }, { extension: { password: "synthetic" } }]) {
      const invalid = structuredClone(addon), candidate = structuredClone(doc); delete invalid.event;
      Object.assign(invalid.mutations[0].descriptor.manifest, extension);
      assert.throws(() => applyAddonEventIntent(candidate, invalid)); assert.deepEqual(candidate, doc);
    }
    const considered = structuredClone(doc); applyAddonEventIntent(considered, addon);
    const event = addon.event, fingerprint = canonicalJSONHashSync(event, "vortx.website-addon.v1\n");
    considered.nativeSync.websiteAddonReceipts = { [event.eventId]: { schemaVersion: 1, eventId: event.eventId, counter: event.counter,
      fingerprint, scope: event.scope, ownerProfileId: event.ownerProfileId, profileId: event.profileId, expectedBinding: event.expectedBinding } };
    const second = structuredClone(addon); delete second.event; second.mutations[0].url = second.mutations[0].descriptor.transportUrl = "https://second-addon.test/manifest.json";
    applyAddonEventIntent(considered, second);
    assert.deepEqual(considered.webAddonEdits.events.map((entry) => entry.eventId), [event.eventId, second.event.eventId], "a receipt without install materialization cannot compact the first source");
    const newer = createProfileIntent(target, { accent: "ocean" }), published = structuredClone(doc);
    await applyProfileIntent(published, look); await applyProfileIntent(published, newer);
    assert.ok(newer.event.editedAt > look.event.editedAt, "new explicit source strictly follows earlier published source at same wall time");
  });

  await t.test("full host writer preserves one lowercase UUID alias but paired profile event fails closed until public native admission supports it", async () => {
    await clean(); const s = makeSession(), original = playbackDoc(s), originalOwner = original.nativeSync.ownerProfileId;
    const owner = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", doc = JSON.parse(JSON.stringify(original).replaceAll(originalOwner, owner));
    doc.nativeHostPreferences.profiles[owner.toLowerCase()] = doc.nativeHostPreferences.profiles[owner]; delete doc.nativeHostPreferences.profiles[owner];
    const view = projectNativeSync(doc, `account.${s.account.id}`), profile = view.profiles.find((row) => row.id === owner);
    const target = { scope: view.scope, ownerProfileId: owner, profileId: owner, binding: profile.binding };
    const host = createHostIntent(target, { playback: { excludeKeywords: "cam" } }, false, "22222222-2222-4222-8222-222222222222"), candidate = structuredClone(doc);
    applyHostIntent(candidate, host, 0);
    assert.equal(candidate.nativeHostPreferences.profiles[owner], undefined); assert.equal(candidate.nativeHostPreferences.profiles[owner.toLowerCase()].fields.playback.value.preferKeywords, "retained-preference");
    const look = createProfileIntent(target, { playback: { audioLang: "fr" } }), snapshot = structuredClone(candidate);
    await assert.rejects(applyProfileIntent(candidate, look)); assert.deepEqual(candidate, snapshot); assert.equal(look.event, undefined);
  });

  await t.test("native owner add-on event is immutable across lost response and ACKs only its exact bound native receipt", async () => {
    await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc);
    globalThis.fetch = async (input, init = {}) => String(input).startsWith("https://api.vortx.tv/") ? server.fetch(input, init)
      : json({ id: "synthetic-native-addon", name: "Synthetic Native", version: "1.0.0", resources: [], types: [], catalogs: [] });
    server.losePutResponse(); await store.addAddon("https://native-event.test/manifest.json"); await advance(500);
    const published = await server.read(), event = published.webAddonEdits.events[0];
    assert.equal(event.mutations[0].state, "present"); assert.equal(event.mutations[0].addon.manifest.version, "1.0.0");
    assert.ok(journalsFor(s).some(([, raw]) => Object.keys(JSON.parse(raw).addons).length));
    await advance(3100); assert.equal(server.puts.length, 1); assert.equal((await server.read()).webAddonEdits.events.length, 1);
    const fingerprint = canonicalJSONHashSync(event, "vortx.website-addon.v1\n");
    published.nativeSync.websiteAddonReceipts = { [event.eventId]: { schemaVersion: 1, eventId: event.eventId, counter: event.counter,
      fingerprint: "0".repeat(64), scope: event.scope, ownerProfileId: event.ownerProfileId, profileId: event.profileId, expectedBinding: event.expectedBinding } };
    await server.remote(published); await advance(3100); assert.ok(journalsFor(s).length);
    const accepted = await server.read(); accepted.nativeSync.websiteAddonReceipts[event.eventId].fingerprint = fingerprint;
    await server.remote(accepted); await advance(7000);
    assert.ok(journalsFor(s).length, "receipt of consideration without native materialization cannot ACK install");
    const mutation = event.mutations[0], clock = 1790000001;
    const source = { schemaVersion: 1, counter: event.counter, eventId: event.eventId, fingerprint, observedClock: 1790000000 };
    accepted.nativeSync.addons[event.profileId].records[mutation.transportUrl] = { value: mutation.addon, valueAt: clock, addedAt: clock, removedAt: 0,
      webSources: { addedAt: source, valueAt: source } };
    await server.remote(accepted); await advance(7000);
    assert.equal(journalsFor(s).length, 0); assert.equal(server.puts.length, 1); assert.deepEqual(accepted.nativeSync.profiles, doc.nativeSync.profiles);
  });

  await t.test("recovered revision-linked add-on event cannot publish or ACK another URL or stale manifest", async () => {
    for (const mode of ["different-url", "stale-manifest"]) {
      await clean(); const s = makeSession(), doc = playbackDoc(s), server = await startNative(s, doc);
      globalThis.fetch = async (input, init = {}) => String(input).startsWith("https://api.vortx.tv/") ? server.fetch(input, init)
        : json({ id: "synthetic-linked-addon", name: "Synthetic Linked", version: "1.0.0", resources: [], types: [], catalogs: [] });
      server.fail(); await store.addAddon("https://linked-addon.test/manifest.json"); await advance(500);
      const [journalKey, raw] = journalsFor(s).at(-1), journal = JSON.parse(raw), linked = Object.values(journal.addonEvents)[0];
      assert.ok(linked.intent.event); assert.equal(server.puts.length, 1);
      if (mode === "different-url") {
        linked.intent.mutations[0].url = linked.intent.mutations[0].descriptor.transportUrl = "https://different-linked-addon.test/manifest.json";
        linked.intent.event.mutations[0].transportUrl = linked.intent.event.mutations[0].addon.transportUrl = linked.intent.mutations[0].url;
      } else {
        linked.intent.mutations[0].descriptor.manifest.version = linked.intent.event.mutations[0].addon.manifest.version = "0.5.0";
      }
      const frozen = structuredClone(linked.intent);
      stop(); stop = undefined; await account.signOut(); timers.clear(); local.set(journalKey, JSON.stringify(journal));
      account = await reloadAccountGraph(); await admit(vault, s, account); stop = account.startAccountSync(); await advance(7000);
      assert.equal(server.puts.length, 1, "revision collision never publishes mismatched frozen effect");
      const restored = JSON.parse(journalsFor(s).at(-1)[1]);
      assert.ok(Object.values(restored.addons).some((intent) => intent.url === "https://linked-addon.test/manifest.json" && intent.descriptor.manifest.version === "1.0.0"));
      assert.deepEqual(Object.values(restored.addonEvents)[0].intent, frozen, "invalid linkage remains durable without changing immutable identity");
      assert.equal((await server.read()).webAddonEdits, undefined);
    }
  });

  await t.test("supported native global settings use actual host registers and do not starve held native edits", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    settings.updateSettings({ autoplayTrailers: false, directLinksOnly: true, performance: "reduced", sourceOrder: ["torrent"], tmdbKey: "synthetic-host-key" });
    assert.equal(hostJournal(s).filter((edit) => edit.intent.global).length, 3, "supported explicit global edits are durable before upload");
    await advance(900);
    const accepted = await server.read(), fields = accepted.nativeHostPreferences.globals.fields;
    assert.deepEqual([fields["stremiox.autoplayTrailers"].value, fields["stremiox.directLinksOnly"].value, fields["stremiox.performanceMode"].value], [false, true, "reduced"]);
    for (const field of Object.values(fields)) { assert.match(field.actor, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/); assert.ok(Number.isSafeInteger(field.clock)); }
    assert.deepEqual(accepted.nativeSync, doc.nativeSync); assert.deepEqual(accepted.nativeProviderCredentials, doc.nativeProviderCredentials);
    assert.deepEqual(accepted.futureCarrier, doc.futureCarrier); assert.equal(accepted.profileEdits, undefined);
    assert.equal(accepted.apiKeys.tmdb, "synthetic-host-key");
    assert.equal(hostJournal(s).filter((edit) => edit.intent.global).length, 0, "only verified host receipts retire their intent");
    assert.equal(hostJournal(s).filter((edit) => !edit.intent.global).length, 1, "playback waits for an authenticated full-register baseline");
    assert.ok(journalsFor(s).some(([, raw]) => JSON.parse(raw).settings.sourceOrder?.[0] === "torrent"), "unsupported core settings stay durable");
    assert.equal(server.maxPuts, 1);
  });

  await t.test("account Watchlist add/remove/re-add is distinct from browser Save and preserves a native null tombstone", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    const item = { id: "tt-host-roundtrip", type: "movie", name: "Synthetic host title", poster: "https://fixture.invalid/poster.jpg" };
    store.toggleLibrary(item);
    assert.equal(store.setAccountWatchlist(item, true), true);
    assert.ok(store.inAccountWatchlist(item.id, item.type));
    assert.equal(hostJournal(s).length, 1);
    const pending = hostJournal(s)[0].intent;
    assert.equal(Object.values(pending.fields)[0].addedAt, now / 1000, "native host timestamp uses epoch seconds");
    await advance(400);
    const owner = doc.nativeSync.ownerProfileId, field = Object.keys(pending.fields)[0];
    const added = (await server.read()).nativeHostPreferences.profiles[owner].fields[field];
    assert.ok(added.value); assert.equal(hostJournal(s).length, 0);
    assert.equal(store.setAccountWatchlist(item, false), true); assert.ok(!store.inAccountWatchlist(item.id, item.type));
    await advance(400);
    const removed = (await server.read()).nativeHostPreferences.profiles[owner].fields[field];
    assert.equal(removed.value, null); assert.ok(removed.clock > added.clock);
    assert.ok(store.inLibrary(item.id), "Watchlist removal never erases a browser Save");
    assert.equal(store.setAccountWatchlist(item, true), true); await advance(400);
    const readded = (await server.read()).nativeHostPreferences.profiles[owner].fields[field];
    assert.ok(readded.value); assert.ok(readded.clock > removed.clock);
    assert.ok(store.nativeLibraryItems().every((row) => row.id !== item.id), "Watchlist never authors native Library membership");
    const host = { innerHTML: "" }; renderLibrary(host);
    assert.match(host.innerHTML, /data-kind="watchlist"/); assert.match(host.innerHTML, /Saved in this browser/);
  });

  await t.test("lost PUT response keeps one durable Lamport identity and exact readback ACKs without another upload", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    server.losePutResponse(); settings.updateSettings({ directLinksOnly: true });
    await advance(900);
    assert.equal(server.puts.length, 1); assert.equal(hostJournal(s).length, 1);
    const planned = structuredClone(hostJournal(s)[0].intent.registers);
    assert.ok(planned); assert.equal(hostJournal(s)[0].intent.accepted, undefined);
    await advance(1000);
    assert.equal(server.puts.length, 1, "exact authenticated receipt avoids an echo PUT");
    assert.equal(hostJournal(s).length, 0);
    assert.deepEqual((await server.read()).nativeHostPreferences.globals.fields["stremiox.directLinksOnly"], planned["stremiox.directLinksOnly"]);
  });

  await t.test("definite CAS rejection replans above a peer clock while a newer same-field local edit survives in-flight PUT", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    const release = server.holdPut(); settings.updateSettings({ directLinksOnly: true }); await advance(900);
    assert.equal(server.puts.length, 1);
    const peer = structuredClone(doc);
    peer.nativeHostPreferences.globals.fields["stremiox.directLinksOnly"] = { clock: 900, actor: "ffffffff-ffff-ffff-ffff-ffffffffffff", value: false };
    await server.remote(peer); settings.updateSettings({ directLinksOnly: false });
    release(); await settle(); await advance(800);
    const field = (await server.read()).nativeHostPreferences.globals.fields["stremiox.directLinksOnly"];
    assert.equal(field.value, false); assert.ok(field.clock > 900);
    assert.equal(hostJournal(s).length, 0); assert.equal(settings.getSettings().directLinksOnly, false);
    assert.equal(server.maxPuts, 1); assert.deepEqual((await server.read()).nativeSync, doc.nativeSync);
  });

  await t.test("an ambiguous rejected upload never overwrites a newer peer or ACKs without explicit new user intent", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    server.fail(); settings.updateSettings({ directLinksOnly: true }); await advance(900);
    const oldPlan = hostJournal(s)[0].intent.registers;
    const peer = structuredClone(doc);
    peer.nativeHostPreferences.globals.fields["stremiox.directLinksOnly"] = { clock: 1000, actor: "ffffffff-ffff-ffff-ffff-ffffffffffff", value: false };
    await server.remote(peer); FakeSocket.instances.at(-1).update(server.version); await settle(); await advance(1100);
    assert.equal(server.puts.length, 1, "uncertain retry cannot manufacture a higher causal edit");
    assert.deepEqual(hostJournal(s)[0].intent.registers, oldPlan); assert.equal(hostJournal(s).length, 1);
    settings.updateSettings({ directLinksOnly: false }); settings.updateSettings({ directLinksOnly: true }); await advance(900);
    assert.equal((await server.read()).nativeHostPreferences.globals.fields["stremiox.directLinksOnly"].value, true);
    assert.ok((await server.read()).nativeHostPreferences.globals.fields["stremiox.directLinksOnly"].clock > 1000);
    assert.equal(hostJournal(s).length, 0, "a new explicit action may causally supersede the peer");
  });

  await t.test("host intent survives a reload after failed PUT without borrowing another profile binding", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    const item = { id: "tmdb:host-reload", type: "series", name: "Reload fixture" };
    server.fail(); assert.equal(store.setAccountWatchlist(item, true), true); await advance(400);
    const captured = structuredClone(hostJournal(s)[0].intent);
    stop(); stop = undefined; await account.signOut(); timers.clear();
    account = await reloadAccountGraph();
    await admit(vault, s, account); stop = account.startAccountSync(); await advance(400);
    assert.equal(hostJournal(s).length, 0);
    const fields = (await server.read()).nativeHostPreferences.profiles[doc.nativeSync.ownerProfileId].fields;
    assert.deepEqual(fields[Object.keys(captured.fields)[0]], captured.registers[Object.keys(captured.fields)[0]], "reload reuses durable actor and clock");
    assert.ok(store.inAccountWatchlist(item.id, item.type));
  });

  await t.test("missing or malformed accepted acknowledgement cannot falsely ACK an unstored host edit against a newer peer", async () => {
    for (const acknowledgement of [{}, { accepted: "true" }]) {
      await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
      globalThis.fetch = async (url, init = {}) => { const response = await server.fetch(url, init); return init.method === "PUT" ? json(acknowledgement) : response; };
      const release = server.holdPut(); settings.updateSettings({ directLinksOnly: true }); await advance(900);
      const peer = structuredClone(doc);
      peer.nativeHostPreferences.globals.fields["stremiox.directLinksOnly"] = { clock: 1500, actor: "ffffffff-ffff-ffff-ffff-ffffffffffff", value: false };
      await server.remote(peer); release(); await settle(); await advance(1100);
      assert.equal(server.puts.length, 1, "unknown worker acknowledgement never enables a causal overwrite");
      assert.equal(hostJournal(s).length, 1, "an edit not actually stored remains durable");
      assert.equal(hostJournal(s)[0].intent.accepted, undefined);
      assert.equal((await server.read()).nativeHostPreferences.globals.fields["stremiox.directLinksOnly"].value, false);
    }
  });

  await t.test("accepted old PUT/readback cannot clear a newer same-field local edit", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    const release = server.holdPut(); settings.updateSettings({ directLinksOnly: true }); await advance(900);
    const firstPlan = structuredClone(hostJournal(s)[0].intent.registers);
    settings.updateSettings({ directLinksOnly: false }); release(); await settle();
    assert.equal(hostJournal(s).length, 1);
    assert.equal(Object.values(hostJournal(s)[0].intent.fields)[0], false, "new explicit value survives old exact receipt");
    assert.equal(settings.getSettings().directLinksOnly, false, "old readback does not flash the superseded value");
    await advance(900);
    const result = (await server.read()).nativeHostPreferences.globals.fields["stremiox.directLinksOnly"];
    assert.equal(result.value, false); assert.ok(result.clock > firstPlan["stremiox.directLinksOnly"].clock);
    assert.equal(hostJournal(s).length, 0); assert.equal(server.puts.length, 2); assert.equal(server.maxPuts, 1);
  });

  await t.test("definite accepted host edit may be superseded by a newer peer; receipt shows peer value and never echoes", async () => {
    await clean(); const s = makeSession(), doc = hostDoc(s), server = await startNative(s, doc);
    let peerNeeded = false;
    globalThis.fetch = async (url, init = {}) => {
      if (init.method === "PUT") { const response = await server.fetch(url, init); peerNeeded = true; return response; }
      if (peerNeeded) {
        peerNeeded = false; const peer = await server.read();
        peer.nativeHostPreferences.globals.fields["stremiox.directLinksOnly"] = { clock: 1900, actor: "ffffffff-ffff-ffff-ffff-ffffffffffff", value: false };
        await server.remote(peer);
      }
      return server.fetch(url, init);
    };
    settings.updateSettings({ directLinksOnly: true }); await advance(900);
    assert.equal(hostJournal(s).length, 0, "definite stored edit with a later peer winner is legitimately superseded");
    assert.equal(settings.getSettings().directLinksOnly, false, "after ACK the native peer winner is visible");
    await advance(3100); assert.equal(server.puts.length, 1, "received winner never becomes a fresh local action");
  });

  await t.test("a delayed receive cannot roll back a verified host write, and account switch retires its stale completion", async () => {
    await clean(); const a = makeSession(), docA = hostDoc(a), serverA = await startNative(a, docA);
    const releaseGet = serverA.holdGet(); FakeSocket.instances.at(-1).update(21); await settle();
    settings.updateSettings({ directLinksOnly: true }); await advance(900);
    assert.equal(hostJournal(a).length, 0); assert.equal(account.accountSyncStatus().receivedVersion, 21);
    releaseGet(); await settle(); assert.equal(settings.getSettings().directLinksOnly, true);
    assert.equal(account.accountSyncStatus().appliedVersion, 21, "older delayed pull never lowers applied revision");
    const releasePut = serverA.holdPut(); settings.updateSettings({ directLinksOnly: false }); await advance(900);
    assert.equal(hostJournal(a).length, 1);
    const b = makeSession(), docB = hostDoc(b), serverB = await serverFor(b, docB);
    await admit(vault, b, account); await until(() => account.accountSyncStatus().appliedVersion === 20, "new account received");
    releasePut(); await settle();
    assert.equal(settings.getSettings().directLinksOnly, false); assert.equal(serverB.puts.length, 0); assert.equal(hostJournal(b).length, 0);
    assert.equal(hostJournal(a).length, 1, "retired completion never ACKs or copies A's journal into B");
    globalThis.fetch = serverA.fetch; await admit(vault, a, account); await advance(400);
    assert.equal(hostJournal(a).length, 0, "A later recovers its own exact stored edit receipt");
    assert.equal(serverA.puts.length, 2, "recovery never creates a third upload");
  });

  await t.test("Watchlist intents remain captured to own-slot binding, while a new action supersedes only the same public profile address", async () => {
    await clean(); const s = makeSession();
    const aSample = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("03-own-A"));
    const bSample = nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("04-own-B"));
    const a = structuredClone(aSample.document), b = structuredClone(bSample.document);
    for (const doc of [a, b]) doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
    const server = await startNative(s, a), viewer = aSample.playback.profileId;
    profiles.setActiveProfile(viewer);
    const item = { id: "tt-watch-binding", type: "movie", name: "Captured watchlist" };
    server.fail(); assert.equal(store.setAccountWatchlist(item, true), true); await advance(400);
    const capturedA = hostJournal(s)[0].intent.target;
    await server.remote(b); account.applySyncDoc(b);
    assert.equal(store.inAccountWatchlist(item.id, item.type), false, "A's pending action is not projected into B");
    await advance(1000); assert.equal(server.puts.length, 1, "A cannot upload against B's fresh binding");
    assert.equal(store.setAccountWatchlist(item, false), true);
    assert.equal(hostJournal(s).length, 1, "new explicit same host address supersedes the old queued add, not another profile");
    assert.notEqual(hostJournal(s)[0].intent.target.binding, capturedA.binding);
    await advance(2100);
    const stored = await server.read(), field = Object.keys(hostJournal(s)[0]?.intent.fields ?? { "watchlist.movie.dHQtd2F0Y2gtYmluZGluZw": null })[0];
    assert.equal(stored.nativeHostPreferences.profiles[viewer].fields[field].value, null);
    assert.equal(hostJournal(s).length, 0);
    a.nativeHostPreferences = stored.nativeHostPreferences; await server.remote(a); account.applySyncDoc(a); await advance(3100);
    assert.equal(store.inAccountWatchlist(item.id, item.type), false, "returning to A never replays its superseded add");
    assert.equal(server.puts.length, 2);
  });

  await t.test("recovered A source is compacted before B reload and cannot resurrect after partial B ACK", async () => {
    await clean(); const s = makeSession();
    const ownerSlot = (sample) => {
      const doc = structuredClone(sample.document), owner = doc.nativeSync.ownerProfileId, viewer = sample.playback.profileId;
      doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
      doc.nativeSync.profiles[owner].profile.account = structuredClone(doc.nativeSync.profiles[viewer].profile.account);
      doc.nativeSync.accountSlots[owner] = structuredClone(doc.nativeSync.accountSlots[viewer]);
      return doc;
    };
    const a = ownerSlot(nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("03-own-A")));
    const b = ownerSlot(nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("04-own-B")));
    const server = await startNative(s, a);
    settings.updateSettings({ directLinksOnly: true, sourceOrder: ["torrent"] });
    const sourceKey = journalsFor(s)[0][0], bindingA = hostJournal(s)[0].intent.target.binding;
    stop(); stop = undefined; await account.signOut(); timers.clear(); session.delete("vortx.web.sync-client.v1");
    await server.remote(b); account = await reloadAccountGraph();
    await admit(vault, s, account); stop = account.startAccountSync(); await until(() => account.accountSyncStatus().appliedVersion === 21, "B loaded while recovered A remains held");
    settings.updateSettings({ directLinksOnly: true }); settings.updateSettings({ directLinksOnly: false });
    const globals = hostJournal(s).filter((edit) => edit.intent.global);
    assert.equal(globals.length, 1); assert.notEqual(globals[0].intent.target.binding, bindingA);
    assert.equal(local.get(sourceKey), undefined, "only after merged checkpoint succeeded is the exact adopted source retired");
    stop(); stop = undefined; await account.signOut(); timers.clear();
    account = await reloadAccountGraph();
    await admit(vault, s, account); stop = account.startAccountSync(); await advance(400);
    assert.equal(hostJournal(s).filter((edit) => edit.intent.global).length, 0, "B ACKs independently while sourceOrder lacks a full playback baseline");
    assert.ok(journalsFor(s).some(([, raw]) => JSON.parse(raw).settings.sourceOrder?.[0] === "torrent"));
    const stored = await server.read(); a.nativeHostPreferences = stored.nativeHostPreferences; await server.remote(a);
    stop(); stop = undefined; await account.signOut(); timers.clear();
    account = await reloadAccountGraph();
    await admit(vault, s, account); stop = account.startAccountSync(); await advance(3100);
    assert.equal(hostJournal(s).filter((edit) => edit.intent.global).length, 0, "old unplanned A cannot be revived from a source or retained global delta");
    assert.equal(server.puts.length, 1); assert.equal(settings.getSettings().directLinksOnly, false);
  });

  await t.test("superseded in-flight A cannot replan after CAS rejection when active slot returns A", async () => {
    await clean(); const s = makeSession();
    const ownerSlot = (sample) => {
      const doc = structuredClone(sample.document), owner = doc.nativeSync.ownerProfileId, viewer = sample.playback.profileId;
      doc.nativeSync.scope = doc.nativeHostPreferences.scope = `account.${s.account.id}`;
      doc.nativeSync.profiles[owner].profile.account = structuredClone(doc.nativeSync.profiles[viewer].profile.account);
      doc.nativeSync.accountSlots[owner] = structuredClone(doc.nativeSync.accountSlots[viewer]); return doc;
    };
    const a = ownerSlot(nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("03-own-A")));
    const b = ownerSlot(nativeFixture.ownSlotCases.find((sample) => sample.source.startsWith("04-own-B")));
    const server = await startNative(s, a), release = server.holdPut();
    settings.updateSettings({ directLinksOnly: true }); await advance(900);
    await server.remote(b); account.applySyncDoc(b);
    settings.updateSettings({ directLinksOnly: true }); settings.updateSettings({ directLinksOnly: false });
    await server.remote(a); account.applySyncDoc(a); release(); await settle(); await advance(1000);
    assert.equal(server.puts.length, 1, "obsolete A snapshot cannot replan even with a currently matching A binding");
    assert.equal(hostJournal(s).length, 1); assert.equal(Object.values(hostJournal(s)[0].intent.fields)[0], false);
    await server.remote(b); account.applySyncDoc(b); await advance(2100);
    assert.equal(server.puts.length, 2); assert.equal(hostJournal(s).length, 0);
    assert.equal((await server.read()).nativeHostPreferences.globals.fields["stremiox.directLinksOnly"].value, false);
  });
});
