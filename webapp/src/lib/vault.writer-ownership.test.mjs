import { fresh, admit, loginCandidate } from "./auth-adoption.fixtures.mjs";
import assert from "node:assert/strict";
import test from "node:test";
class Storage { values = new Map(); getItem(k) { return this.values.get(k) ?? null; } setItem(k, v) { this.values.set(k, String(v)); } removeItem(k) { this.values.delete(k); } }
let vault;
const make = (id, byte = 1) => ({ token: "synthetic-" + id, account: { id, username: id, email: id + "@example.invalid" }, dataKey: new Uint8Array(32).fill(byte) });
const env = async () => { ({ vault } = await fresh()); };
const desc = (s) => JSON.stringify({ token: s.token, account: s.account });
const deferred = () => { let resolve; const promise = new Promise((done) => { resolve = done; }); return { promise, resolve }; };
// Mocked storage and transport only; no account request leaves the process.
test("present unowned or malformed descriptors cannot use the in-memory writer exception", async () => {
  for (const descriptor of [desc(make("other", 2)), "invalid-json"]) {
    await env(); const a = make("a"); await admit(vault, a); localStorage.setItem("vortx.session.v1", descriptor); let calls = 0;
    globalThis.fetch = async () => { calls++; throw Error("unexpected transport"); };
    await assert.rejects(vault.mutateSyncDoc(a, (d) => { d.synthetic = true; }), /session changed/i);
    assert.equal(calls, 0); assert.equal(localStorage.getItem("vortx.session.v1"), descriptor);
  }
});
test("genuinely storage-free in-memory callers retain supported encrypted writes", async () => {
  await env(); const a = make("a");
  assert.equal(vault.completeMemoryOnly(await loginCandidate(vault, a)).status, "memory-only"); let puts = 0;
  globalThis.fetch = async (_url, init) => init.method === "PUT" ? (puts++, Response.json({ accepted: true })) : Response.json({}, { status: 404 });
  await vault.mutateSyncDoc(a, (d) => { d.synthetic = true; }); assert.equal(puts, 1);
});
test("a descriptor that appears during an in-memory write fences the candidate before PUT", async () => {
  await env(); const a = make("a"), b = make("b", 2), entered = deferred(), response = deferred(); let puts = 0;
  assert.equal(vault.completeMemoryOnly(await loginCandidate(vault, a)).status, "memory-only");
  globalThis.fetch = async (_url, init) => { if (init.method === "PUT") { puts++; return Response.json({ accepted: true }); } entered.resolve(); return response.promise; };
  const pending = vault.mutateSyncDoc(a, (d) => { d.synthetic = true; });
  const rejected = assert.rejects(pending, /session changed/i); void rejected.catch(() => {});
  try {
    await entered.promise;
    localStorage.setItem("vortx.session.v1", desc(b)); response.resolve(Response.json({}, { status: 404 }));
    await rejected; assert.equal(puts, 0); assert.equal(localStorage.getItem("vortx.session.v1"), desc(b));
  } finally { response.resolve(Response.json({}, { status: 404 })); await rejected; }
});

test("saved and loaded sessions retain persisted ownership after another tab removes the descriptor", async () => {
  for (const useLoaded of [false, true]) {
    await env(); const saved = make("owned"); await admit(vault, saved); const a = useLoaded ? vault.loadSession() : saved;
    localStorage.removeItem("vortx.session.v1"); let calls = 0;
    globalThis.fetch = async () => { calls++; throw Error("unexpected stale-account request"); };
    await assert.rejects(vault.mutateSyncDoc(a, (d) => { d.synthetic = true; }), /session changed/i);
    assert.equal(calls, 0); assert.equal(localStorage.getItem("vortx.session.v1"), null);
  }
});
test("failed persistence does not disable a genuine private-mode session's in-memory writes", async () => {
  await env(); const a = make("private-memory"); const handle = await loginCandidate(vault, a);
  sessionStorage.setItem = () => { throw Error("synthetic blocked storage"); };
  assert.equal((await vault.completeAuthAttempt(handle)).status, "not-persisted");
  assert.equal(vault.completeMemoryOnly(handle).status, "memory-only"); let puts = 0;
  globalThis.fetch = async (_url, init) => init.method === "PUT" ? (puts++, Response.json({ accepted: true })) : Response.json({}, { status: 404 });
  await vault.mutateSyncDoc(a, (d) => { d.synthetic = true; }); assert.equal(puts, 1);
});
