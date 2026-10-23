import { fresh, admit, loginCandidate } from "./auth-adoption.fixtures.mjs";
import assert from "node:assert/strict";
import test from "node:test";
const WEBAPP = import.meta.url.includes("/webapp/");
let vault;
class Storage {
  data = new Map();
  getItem(key) { return this.data.get(key) ?? null; }
  setItem(key, value) { this.data.set(key, String(value)); }
  removeItem(key) { this.data.delete(key); }
}
let sequence = 0;
const encode = (value) => new TextEncoder().encode(value);
async function environment() {
  ({ vault } = await fresh());
  const id = "synthetic-reset-generation-" + ++sequence;
  const s = { token: "synthetic-old-token", account: { id, username: id, email: id + "@example.invalid" }, dataKey: new Uint8Array(32).fill(sequence) };
  await admit(vault, s); localStorage.setItem("vortx.syncVer." + id, "100"); localStorage.setItem("vortx.sawV2." + id, "1"); return s;
}
async function encrypt(doc, s, version, v2 = false) {
  const key = await crypto.subtle.importKey("raw", s.dataKey, "AES-GCM", false, ["encrypt"]), iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv, ...(v2 ? { additionalData: encode("vortx/sync-doc/v2\n" + s.account.id + "\n" + version) } : {}) }, key, encode(JSON.stringify(doc)));
  return (v2 ? "v2." : "") + Buffer.concat([iv, new Uint8Array(ct)]).toString("base64");
}
const read = (s, version) => vault.fetchSync(s, WEBAPP ? { version } : { knownVersion: version });
async function reset(old, result = 200) {
  let posted;
  globalThis.fetch = async (url, init) => {
    if (String(url).endsWith("/v1/auth/prelogin")) return Response.json({ kdfSalt: Buffer.alloc(16, 4).toString("base64"), kdfIters: 210000 });
    assert.ok(String(url).endsWith("/v1/auth/reset/complete")); posted = JSON.parse(init.body);
    return result === 200 ? Response.json({ token: "synthetic-reset-token", account: old.account }) : result === "malformed" ? Response.json({ account: old.account }) : Response.json({ error: "synthetic" }, { status: result });
  };
  const handle = vault.beginAuthAttempt("reset");
  const candidate = await vault.resetComplete(old.account.email, "123456", "synthetic-password", handle);
  const receipt = await vault.completeAuthAttempt(handle);
  assert.equal(receipt.status, "persisted");
  assert.equal(vault.recoveryCodeFor(receipt.effect), candidate.recoveryCode);
  assert.equal(vault.acknowledgeRecoveryCode(receipt.effect), true);
  return { ...candidate, posted };
}
function reply(s, doc, version, v2 = false) { globalThis.fetch = async () => Response.json({ document: await encrypt(doc, s, version, v2), version }); }
function retained(old) { assert.equal(localStorage.getItem("vortx.syncVer." + old.account.id), "100"); assert.equal(localStorage.getItem("vortx.sawV2." + old.account.id), "1"); }

test("accepted email reset isolates the new key while preserving legacy ratchets and same-key session protections", async () => {
  const old = await environment(), { session: s } = await reset(old);
  reply(s, { fresh: true }, 0); assert.deepEqual((await read(s)).contents, { fresh: true }); retained(old);
  const proofs = [...localStorage.values].filter(([key]) => key.startsWith("vortx.syncGeneration.v1."));
  assert.equal(proofs.length, 1); assert.equal(JSON.stringify(proofs).includes(Buffer.from(s.dataKey).toString("base64")), false);
  const adopted = { ...s, token: "synthetic-qr-session", dataKey: s.dataKey.slice() }; await vault.clearSession(); await admit(vault, adopted);
  reply(adopted, { current: true }, 8, true); assert.deepEqual((await read(adopted)).contents, { current: true });
  reply(adopted, { stale: true }, 7, true); assert.equal((await read(adopted)).decryptFailed, true);
  reply(adopted, { downgrade: true }, 9); assert.equal((await read(adopted)).decryptFailed, true);
});

test("first reset-generation write uses witnessed absence then reads its revision-zero backup", async () => {
  const old = await environment(), { session: s } = await reset(old); let body;
  globalThis.fetch = async (url, init) => {
    if (init.method !== "PUT") return body ? Response.json({ document: body.document, version: body.version }) : new Response(null, { status: 404 });
    body = JSON.parse(init.body); return Response.json({ accepted: true });
  };
  await vault.mutateSyncDoc(s, (doc) => { doc.synthetic = "retained"; });
  assert.equal(body.baseRevision, null); assert.equal(body.version, 0); assert.deepEqual((await read(s)).contents, { synthetic: "retained" }); retained(old);
});

test("same-key password login retains the reset generation's floor and v2 ratchet", async () => {
  const old = await environment(), { session: s, posted } = await reset(old); reply(s, { current: true }, 12, true); assert.deepEqual((await read(s)).contents, { current: true });
  globalThis.fetch = async (url) => String(url).endsWith("/prelogin") ? Response.json({ kdfSalt: Buffer.alloc(16, 4).toString("base64"), kdfIters: 210000 })
    : Response.json({ token: "synthetic-relogin-token", account: old.account, wrappedKeyPassword: posted.wrappedKeyPassword });
  const handle = vault.beginAuthAttempt("login");
  const login = await vault.login(old.account.email, "synthetic-password", undefined, handle); assert.deepEqual(login.dataKey, s.dataKey);
  assert.equal((await vault.completeAuthAttempt(handle)).status, "persisted");
  reply(login, { stale: true }, 11, true); assert.equal((await read(login)).decryptFailed, true);
  reply(login, { downgrade: true }, 13); assert.equal((await read(login)).decryptFailed, true); retained(old);
});

test("unproven keys retain historical floors and copied reset proofs do not authorize them", async () => {
  const old = await environment(), unproven = { ...old, dataKey: new Uint8Array(32).fill(240) };
  await admit(vault, unproven); reply(unproven, {}, 0);
  assert.equal((await read(unproven)).decryptFailed, true);
  await admit(vault, old);
  reply(old, {}, 99, true); assert.equal((await read(old)).decryptFailed, true); reply(old, {}, 101); assert.equal((await read(old)).decryptFailed, true);
  await reset(old); const [, proof] = [...localStorage.values].find(([key]) => key.startsWith("vortx.syncGeneration.v1."));
  const domain = encode("vortx/reset-sync-generation/v1\n" + old.account.id + "\n"), material = new Uint8Array(domain.length + old.dataKey.length);
  material.set(domain); material.set(old.dataKey, domain.length);
  const digest = Buffer.from(await crypto.subtle.digest("SHA-256", material)).toString("hex");
  localStorage.setItem("vortx.syncGeneration.v1." + old.account.id + ".key." + digest, proof);
  await admit(vault, old); reply(old, {}, 0); assert.equal((await read(old)).decryptFailed, true); retained(old);
});

test("failed or malformed reset acknowledgements never authorize another generation", async () => {
  for (const result of [401, 500, "malformed"]) { const old = await environment(); await assert.rejects(reset(old, result)); retained(old);
    assert.equal([...localStorage.values.keys()].some((key) => key.startsWith("vortx.syncGeneration.v1.")), false); }
});

test("an old in-flight response cannot advance the replacement key's floor", async () => {
  const old = await environment(); let release, started; const pending = new Promise((resolve) => { release = resolve; }), ready = new Promise((resolve) => { started = resolve; });
  globalThis.fetch = async () => { started(); return pending; }; const oldRead = read(old); await ready;
  const { session: s } = await reset(old); reply(s, {}, 5, true); assert.equal((await read(s)).decryptFailed, false);
  const oldRejected = assert.rejects(oldRead, /session changed/i);
  release(Response.json({ document: await encrypt({}, old, 1000, true), version: 1000 })); await oldRejected;
  assert.equal(localStorage.getItem("vortx.syncVer." + old.account.id), "100", "retired response cannot advance even the old floor");
  reply(s, {}, 5, true); assert.equal((await read(s)).decryptFailed, false); reply(s, {}, 4, true); assert.equal((await read(s)).decryptFailed, true);
});

test("conditional responses below this key's floor are rejected", async () => {
  const old = await environment(), { session: s } = await reset(old); reply(s, {}, 8, true); assert.equal((await read(s)).decryptFailed, false);
  globalThis.fetch = async () => new Response(null, { status: 304 }); const stale = await read(s, 7);
  assert.equal(stale.decryptFailed, true); assert.notEqual(stale.unchanged, true);
});

test("a witnessed v2 head stays v2 after mutation even before the global migration toggle", async () => {
  const old = await environment(); let document = await encrypt({ foreign: { retain: true } }, old, 100, true), version = 100;
  globalThis.fetch = async (url, init) => { if (init.method === "PUT") { const body = JSON.parse(init.body); document = body.document; version = body.version; return Response.json({ accepted: true }); }
    return Response.json({ document, version }); };
  await vault.mutateSyncDoc(old, (doc) => { doc.local = true; }); assert.ok(document.startsWith("v2."));
  assert.deepEqual((await read(old)).contents, { foreign: { retain: true }, local: true });
});

test("a legacy response cannot pass after another read establishes the v2 ratchet during decrypt", async () => {
  const s = await environment(); localStorage.removeItem("vortx.sawV2." + s.account.id);
  let release, started; const pending = new Promise((resolve) => { release = resolve; }), ready = new Promise((resolve) => { started = resolve; });
  const original = crypto.subtle.decrypt.bind(crypto.subtle); let hold = true;
  crypto.subtle.decrypt = async (...args) => { if (!args[0].additionalData && hold) { hold = false; started(); await pending; } return original(...args); };
  try {
    reply(s, { legacy: true }, 102); const legacy = read(s); await ready;
    reply(s, { current: true }, 101, true); assert.deepEqual((await read(s)).contents, { current: true });
    release(); const rejected = await legacy; assert.equal(rejected.decryptFailed, true); assert.equal(rejected.contents, undefined);
    assert.equal(localStorage.getItem("vortx.syncVer." + s.account.id), "101");
  } finally { release(); crypto.subtle.decrypt = original; }
});

test("website restore retains the v2 format of its witnessed head", { skip: WEBAPP }, async () => {
  const s = await environment(); let document = await encrypt({ current: true }, s, 100, true), version = 100;
  const file = JSON.stringify({ document: await encrypt({ restored: { future: true } }, s, 7, true), version: 7 });
  globalThis.fetch = async (url, init) => { if (init.method === "PUT") { const body = JSON.parse(init.body); document = body.document; version = body.version; return Response.json({ accepted: true }); }
    return Response.json({ document, version }); };
  await vault.importBackup(s, file); assert.ok(document.startsWith("v2.")); assert.equal(version, 101);
  assert.deepEqual((await read(s)).contents, { restored: { future: true } });
});
