import { fresh, admit, seedOwned, storageEvent } from "./auth-adoption.fixtures.mjs";
import assert from "node:assert/strict";
import test from "node:test";
import { webcrypto } from "node:crypto";
Object.defineProperty(globalThis, "crypto", { configurable: true, value: webcrypto });
let vault;
const json = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
class Storage {
  data = new Map();
  getItem(key) { return this.data.get(key) ?? null; }
  setItem(key, value) { this.data.set(key, String(value)); }
  removeItem(key) { this.data.delete(key); }
}
let sequence = 0;
async function session() {
  ({ vault } = await fresh());
  const id = "synthetic-cas-" + ++sequence;
  const s = { token: "shared-synthetic-token", account: { id, username: id, email: id + "@example.invalid" }, dataKey: new Uint8Array(32).fill(sequence) };
  await admit(vault, s);
  return s;
}
async function encrypt(doc, s) {
  const key = await crypto.subtle.importKey("raw", s.dataKey, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(JSON.stringify(doc)));
  return Buffer.concat([iv, new Uint8Array(ct)]).toString("base64");
}
async function decrypt(document, s) {
  const all = Buffer.from(document, "base64");
  const key = await crypto.subtle.importKey("raw", s.dataKey, "AES-GCM", false, ["decrypt"]);
  return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.subarray(0, 12) }, key, all.subarray(12))));
}
function relay(s, initial = { foreign: { nested: { future: 7 } }, vortx: { futureField: { opaque: true } } }, revision = 20) {
  let doc = initial, version = initial === null ? null : revision, gate, putStarted, lose = false, status = 200, malformed, acceptedResponse = true;
  const puts = [];
  const fetch = async (url, init = {}) => {
    assert.equal(String(url), "https://api.vortx.tv/v1/backup");
    assert.equal(init.headers.authorization, "Bearer " + s.token);
    if (init.method === "PUT") {
      const body = JSON.parse(init.body); puts.push(body);
      assert.ok(Object.hasOwn(body, "baseRevision"));
      assert.ok(body.baseRevision === null || (Number.isSafeInteger(body.baseRevision) && body.baseRevision >= 0));
      assert.equal(body.version, body.baseRevision === null ? 0 : body.baseRevision + 1);
      const wait = gate; gate = undefined; putStarted?.(); if (wait) await wait;
      if (status === 426) return json({ error: "upgrade_required", accepted: false }, 426);
      const accepted = body.baseRevision === version;
      if (accepted) { doc = await decrypt(body.document, s); version = body.version; }
      if (lose) { lose = false; throw new Error("synthetic accepted response lost"); }
      return json(acceptedResponse ? { ok: true, accepted, ...(!accepted ? { version } : {}) } : { ok: true });
    }
    if (malformed) return json(malformed);
    if (status !== 200 && status !== 426) return json({ error: "unavailable" }, status);
    if (version === null) return new Response(null, { status: 404 });
    const readVersion = version, readDoc = structuredClone(doc);
    return json({ document: await encrypt(readDoc, s), version: readVersion });
  };
  globalThis.fetch = fetch;
  return {
    fetch, puts, get version() { return version; }, read: () => structuredClone(doc),
    remote(next) { doc = structuredClone(next); version = version === null ? 0 : version + 1; },
    holdPut() {
      let release, started;
      gate = new Promise((resolve) => { release = resolve; });
      const ready = new Promise((resolve) => { started = resolve; });
      putStarted = () => { putStarted = undefined; started(); };
      return { release, ready };
    },
    loseResponse() { lose = true; }, requireUpgrade() { status = 426; }, error(code) { status = code; },
    malformed(data) { malformed = data; }, omitAcceptance() { acceptedResponse = false; },
  };
}
test("candidate-bound encrypted vault writes use real mutation methods", async (t) => {
  await t.test("same-token later GET cannot bless an earlier candidate; rejection remerges latest unknown carriers", async () => {
    const s = await session(), server = relay(s), held = server.holdPut();
    const intent = { id: "one-logical-action", value: "local" };
    localStorage.setItem("synthetic-retained-intent", JSON.stringify(intent));
    const writing = vault.mutateSyncDoc(s, (doc) => { doc.webIntent = intent; });
    await held.ready;
    const peer = server.read(); peer.foreign.nested.later = "peer"; peer.nativeHostPreferences = { futureCarrier: "retain" }; peer.nativeProviderCredentials = { opaque: "synthetic" };
    server.remote(peer);
    assert.equal((await vault.fetchSync(s)).version, 21, "independent poll shares this bearer");
    held.release(); await writing;
    assert.deepEqual(server.puts.map(({ baseRevision, version }) => [baseRevision, version]), [[20, 21], [21, 22]]);
    assert.deepEqual(server.read().webIntent, intent);
    assert.deepEqual(server.read().foreign.nested, { future: 7, later: "peer" });
    assert.deepEqual(server.read().nativeHostPreferences, peer.nativeHostPreferences);
    assert.deepEqual(server.read().nativeProviderCredentials, peer.nativeProviderCredentials);
    assert.deepEqual(server.read().vortx.futureField, { opaque: true });
    assert.equal(localStorage.getItem("synthetic-retained-intent"), JSON.stringify(intent));
  });
  await t.test("two writers from an authenticated absent row create at zero and remerge the losing intent", async () => {
    const s = await session(), server = relay(s, null), held = server.holdPut();
    const first = vault.mutateSyncDoc(s, (doc) => { doc.first = true; }); await held.ready;
    await vault.mutateSyncDoc(s, (doc) => { doc.second = true; }); held.release(); await first;
    assert.deepEqual(server.puts.map(({ baseRevision, version }) => [baseRevision, version]), [[null, 0], [null, 0], [0, 1]]);
    assert.deepEqual(server.read(), { first: true, second: true });
  });
  await t.test("unknown or unreadable bases, auth failures, and numeric overflow never become default null witnesses", async () => {
    for (const version of [undefined, "20", -1, 1.5, Number.MAX_SAFE_INTEGER + 1, Number.MAX_SAFE_INTEGER]) {
      const s = await session(), server = relay(s);
      server.malformed({ document: await encrypt({}, s), version });
      await assert.rejects(vault.mutateSyncDoc(s, (doc) => { doc.mine = true; }));
      assert.equal(server.puts.length, 0);
    }
    for (const code of [401, 503]) {
      const s = await session(), server = relay(s); server.error(code);
      await assert.rejects(vault.mutateSyncDoc(s, (doc) => { doc.mine = true; })); assert.equal(server.puts.length, 0);
    }
    const s = await session(), server = relay(s); server.malformed({ document: "cannot decrypt", version: 20 });
    await assert.rejects(vault.mutateSyncDoc(s, (doc) => { doc.mine = true; })); assert.equal(server.puts.length, 0);
  });
  await t.test("account replacement while candidate is sealing fences the PUT and retains the original intent", async () => {
    const s = await session(), server = relay(s);
    await assert.rejects(vault.mutateSyncDoc(s, (doc) => {
      doc.mine = "original account";
      // A separately owned tab publication can occur synchronously during this reducer.
      seedOwned({ ...s, token: "other-token", account: { ...s.account, id: "other-account" } }); storageEvent();
    }), /session changed/i);
    assert.equal(server.puts.length, 0);
  });
  await t.test("upgrade-required is terminal within the mutation and absent acceptance is never an ACK", async () => {
    const s = await session(), server = relay(s); server.requireUpgrade();
    await assert.rejects(vault.mutateSyncDoc(s, (doc) => { doc.mine = true; }), { name: "SyncUpgradeRequiredError" });
    assert.equal(server.puts.length, 1);
    const other = await session(), unconfirmed = relay(other); unconfirmed.omitAcceptance();
    await assert.rejects(vault.mutateSyncDoc(other, (doc) => { doc.mine = true; }), /confirm/);
    assert.equal(unconfirmed.puts.length, 1);
  });
  await t.test("a lost accepted response leaves the edit unacknowledged and fresh readback proves its retained identity", async () => {
    const s = await session(), server = relay(s), intent = { id: "durable-action", value: 3 };
    localStorage.setItem("synthetic-retained-intent", JSON.stringify(intent)); server.loseResponse();
    await assert.rejects(vault.mutateSyncDoc(s, (doc) => { doc.webIntent = intent; }), /response lost/);
    assert.equal(server.puts.length, 1);
    const resumed = vault.loadSession();
    assert.deepEqual((await vault.fetchSync(resumed)).contents.webIntent, JSON.parse(localStorage.getItem("synthetic-retained-intent")));
    assert.equal(server.version, 21);
  });
  await t.test("explicit owned deletion preserves unknown nested siblings", async () => {
    const s = await session(), server = relay(s, { apiKeys: { tmdb: "synthetic-remove", future: { retain: true } }, vortx: { futureField: "retain" } });
    await vault.mutateSyncDoc(s, (doc) => { delete doc.apiKeys.tmdb; });
    assert.deepEqual(server.read(), { apiKeys: { future: { retain: true } }, vortx: { futureField: "retain" } });
  });
});
