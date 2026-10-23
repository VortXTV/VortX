import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";

const makeSession = (id) => ({ token: `token-${id}`, account: { id }, dataKey: new Uint8Array(32).fill(id === "a" ? 1 : 2) });
const listeners = new Set();
let session = makeSession("a");
let readStatus = async () => ({ hasBlob: true, hhKeyVersion: 1, role: "member" });
let mutate = async (candidate, change, isCurrent) => { assert.ok(isCurrent()); change({}); };
let loadManifest = async (url) => ({ transportUrl: url, manifest: { id: "test", name: "Test", version: "1", resources: [] } });
let shared;
const values = new Map();
const settings = {};
const h = globalThis.__householdFence = {
  currentSession: () => session,
  // This existing orchestration suite mocks the ownership dependency; real authority/blocked/ABA
  // behavior is exercised separately by vault.auth-adoption.test.mjs against the actual graph.
  captureSessionOwnership: (source) => () => source === session,
  subscribe(fn) { listeners.add(fn); fn(session); return () => listeners.delete(fn); },
  householdStatus: (...args) => readStatus(...args),
  householdBlobGet: async () => ({ document: "shared" }),
  getSyncDoc: async () => ({ household: { wrappedHhKey: "self", hhKeyVersion: 1 } }),
  openSharedBlob: async (blob) => blob === "self" ? new Uint8Array(32) : new TextEncoder().encode(JSON.stringify(shared)),
  mutateSyncDoc: (...args) => mutate(...args),
  loadAddon: (...args) => loadManifest(...args),
  getSettings: () => settings,
  updateSettings: (patch) => Object.assign(settings, patch),
};
const proxy = (names) => `const h = globalThis.__householdFence; ${names.map((name) => `export const ${name} = (...args) => h.${name}(...args);`).join(" ")}`;
const mocks = {
  "./account": proxy(["currentSession", "subscribe"]),
  "./vault": proxy(["captureSessionOwnership", "householdStatus", "householdBlobGet", "householdKeyRequest", "householdKeyStatus", "unwrapHhKey", "newHouseholdEphemeral", "sealSharedBlob", "openSharedBlob", "getSyncDoc", "mutateSyncDoc"]),
  "./addon": `export const CINEMETA_URL = "https://cinemeta.test/manifest.json"; ${proxy(["loadAddon"])}`,
  "./settings": proxy(["getSettings", "updateSettings"]),
  "./profiles": "export const activeScope = () => ''; export const activeProfileId = () => 'owner';",
};
registerHooks({
  resolve(specifier, context, next) {
    if (mocks[specifier] && /\/(household|store)\.ts$/.test(context.parentURL ?? "")) {
      return { url: "data:text/javascript," + encodeURIComponent(mocks[specifier]), shortCircuit: true };
    }
    if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
      const candidate = new URL(specifier + ".ts", context.parentURL);
      if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});
globalThis.localStorage = {
  getItem: (key) => values.get(key) ?? null,
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
};
const { acceptShared } = await import("./household.ts");
const { addAddon, registerAddonsSyncPusher } = await import("./store.ts");
const switchAccount = (next) => { session = next; for (const fn of listeners) fn(session); };
const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r; }); return { promise, resolve }; };
function reset() {
  assert.equal(listeners.size, 0, "finished consent actions release their session listeners");
  session = makeSession("a"); values.clear(); for (const key of Object.keys(settings)) delete settings[key];
  readStatus = async () => ({ hasBlob: true, hhKeyVersion: 1, role: "member" });
  mutate = async (candidate, change, isCurrent) => { assert.equal(candidate.account.id, "a"); assert.ok(isCurrent()); change({}); };
  loadManifest = async (url) => ({ transportUrl: url, manifest: { id: "test", name: "Test", version: "1", resources: [] } });
  shared = { addOns: [], library: [], metadataKeys: {}, debridKeys: { rd: { key: "synthetic-key", contributorAccountId: "owner" } } };
  registerAddonsSyncPusher(null);
}

test("debrid consent waits for acceptance and a failed write leaves no success receipt", async () => {
  reset();
  const write = deferred(); let writes = 0, done = false;
  mutate = async (_session, _change, current) => { writes++; await write.promise; assert.ok(current()); throw new Error("save failed"); };
  const pending = acceptShared("debrid").finally(() => { done = true; });
  while (!writes) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(done, false);
  assert.equal(values.has("vortx.household.consent.debrid.a"), false);
  write.resolve();
  await assert.rejects(pending, /save failed/);
  assert.equal(values.has("vortx.household.consent.debrid.a"), false);
  assert.equal(listeners.size, 0);
});

test("account replacement during a household read cancels adoption even after A returns", async () => {
  reset();
  const status = deferred(); let writes = 0;
  readStatus = () => status.promise;
  mutate = async () => { writes++; };
  const a = session, pending = acceptShared("debrid");
  switchAccount(makeSession("b")); switchAccount(a);
  status.resolve({ hasBlob: true, hhKeyVersion: 1, role: "member" });
  assert.equal(await pending, false);
  assert.equal(writes, 0); assert.equal(values.size, 0); assert.equal(listeners.size, 0);
});

test("account replacement during manifest loading prevents any later add-on or metadata adoption", async () => {
  reset();
  const manifest = deferred(); let loads = 0, pushes = 0;
  shared.addOns = ["first", "second"].map((name) => ({ transportUrl: `https://${name}.test/manifest.json`, contributorAccountId: "owner" }));
  shared.metadataKeys.tmdb = "synthetic-metadata";
  loadManifest = (url) => { loads++; return manifest.promise.then(() => ({ transportUrl: url, manifest: { id: "test", name: "Test", version: "1" } })); };
  registerAddonsSyncPusher(() => { pushes++; });
  const pending = acceptShared("content");
  while (!loads) await new Promise((resolve) => setImmediate(resolve));
  switchAccount(makeSession("b")); manifest.resolve();
  await assert.rejects(pending, /Account changed/);
  assert.equal(loads, 1); assert.equal(pushes, 0); assert.equal(values.size, 0); assert.deepEqual(settings, {});
  assert.equal(listeners.size, 0);
});

test("successful debrid adoption retains existing keys and records consent after the guarded mutation", async () => {
  reset();
  let saved;
  mutate = async (candidate, change, current) => { assert.equal(candidate.account.id, "a"); assert.ok(current()); saved = { apiKeys: { rd: "existing", untouched: "retained" } }; change(saved); };
  assert.equal(await acceptShared("debrid"), true);
  assert.deepEqual(saved.apiKeys, { rd: "existing", untouched: "retained" });
  assert.match(values.get("vortx.household.consent.debrid.a"), /^[0-9a-f]{64}$/);
  assert.equal(listeners.size, 0);
});

test("add-on caller admission is checked before fetching as well as before persistence", async () => {
  reset(); let loads = 0;
  loadManifest = async () => { loads++; throw new Error("should not fetch"); };
  await assert.rejects(addAddon("https://example.test/manifest.json", () => false), /Account changed/);
  assert.equal(loads, 0); assert.equal(values.size, 0);
});
