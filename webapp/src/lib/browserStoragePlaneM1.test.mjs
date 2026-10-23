// SOURCE-ONLY SAVED FIXTURES. Not executed by the preparation author.
// These import the actual new module. The independent scheduler is synthetic, not browser proof.
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  M1_NAMESPACE, M1_AUTHORITY, M1_RECORD, M1_LOCK, M1_LIMITS,
  createStoragePlaneM1ForFixtures, platformM1Locks,
} from "./browserStoragePlaneM1.ts";

const A = Object.freeze({ owner: "account-A", session: "session-A-1", native: null });
const B = Object.freeze({ owner: "account-B", session: "session-B-1", native: "binding-B-1" });
const scope = (who) => JSON.stringify([who.owner, who.native]);
const byteLength = (raw) => 2 * raw.length;
const ordered = (rows) => [...rows].sort((a, b) => {
  const x = JSON.stringify([a[0], a[1]]), y = JSON.stringify([b[0], b[1]]);
  return x < y ? -1 : x > y ? 1 : 0;
});
const orderedEpochs = (epochs) => [...epochs].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
const oldBytes = [
  ["vortx.web.library.v1", '[ {"id":"unknown-legacy","extra":{"future":true}} ]'],
  ["vortx.web.storage.v2.root", "g-old"],
  ["vortx.web.storage.v2.snapshot.g-old", ' {"schemaVersion":2,"unknown":"preserve-exact"} '],
  ["vortx.web.storage.v2.overlay.g-old.any", '{"future":null}'],
  ["vortx.web.sync-intents.v1.foreign", '{"pending":"retain-exact"}'],
];
class MemoryStorage {
  values = new Map();
  writes = [];
  beforeGet = undefined;
  beforeKey = undefined;
  beforeSet = undefined;
  afterSet = undefined;
  denied = false;
  get length() { if (this.denied) throw new Error("synthetic read denial"); return this.values.size; }
  key(index) { if (this.denied) throw new Error("synthetic read denial"); this.beforeKey?.(index); return [...this.values.keys()][index] ?? null; }
  getItem(key) {
    if (this.denied) throw new Error("synthetic read denial");
    this.beforeGet?.(key);
    return this.values.get(key) ?? null;
  }
  setItem(key, value) {
    this.beforeSet?.(key, value);
    this.values.set(key, value);
    this.writes.push([key, value]);
    this.afterSet?.(key, value);
  }
}
class Clock {
  time = 0;
  tasks = new Set();
  now = () => this.time;
  later = (ms, callback) => {
    const task = { at: this.time + ms, callback };
    this.tasks.add(task);
    return () => this.tasks.delete(task);
  };
  tick(ms) {
    this.time += ms;
    for (const task of [...this.tasks].sort((a, b) => a.at - b.at)) {
      if (task.at <= this.time && this.tasks.delete(task)) task.callback();
    }
  }
}
/** Independent FIFO owner. No lease, TTL, steal, implicit release or production adapter substitution. */
class Scheduler {
  requests = [];
  active = false;
  heldExternally = false;
  ignoreAbortForGrantRace = false;
  run(signal, body) {
    return new Promise((resolve, reject) => {
      const request = { signal, body, resolve, reject, aborted: false };
      const abort = () => {
        request.aborted = true;
        if (!this.ignoreAbortForGrantRace) {
          this.requests = this.requests.filter((entry) => entry !== request);
          reject(new Error("scheduler aborted before entry"));
        }
      };
      request.cleanup = () => signal.removeEventListener("abort", abort);
      signal.addEventListener("abort", abort, { once: true });
      this.requests.push(request);
      if (signal.aborted) abort();
    });
  }
  grant() {
    if (this.active || this.heldExternally || !this.requests.length) return false;
    const request = this.requests.shift();
    this.active = true;
    request.cleanup();
    try {
      const value = request.body();
      // Hold until callback completion, even if another request arrives from a storage hook.
      Promise.resolve(value).then(request.resolve, request.reject).finally(() => { this.active = false; });
    } catch (error) { this.active = false; request.reject(error); }
    return true;
  }
}
function genesis(rows = [], epochs = [[scope(A), "epoch-A"], [scope(B), "epoch-B"]], id = "genesis") {
  const authority = { version: 3, kind: "authority", publication: id, operation: id, parent: null,
    checkpoint: id, head: null, generation: 0, epochs: orderedEpochs(epochs) };
  const checkpoint = { version: 3, kind: "checkpoint", id, authority, provenance: "synthetic-m1", rows: ordered(rows) };
  return { authority, checkpoint };
}
function seed(storage, rows = [], epochs, id) {
  const value = genesis(rows, epochs, id);
  storage.values.set(M1_RECORD + value.checkpoint.id, JSON.stringify(value.checkpoint));
  storage.values.set(M1_AUTHORITY, JSON.stringify(value.authority));
  return value;
}
function append(storage, changes, { who = A, payload = "", id, nextEpoch } = {}) {
  const previous = storage.values.get(M1_AUTHORITY), prior = JSON.parse(previous);
  id ??= "manual-" + String(prior.generation + 1).padStart(4, "0");
  const sourceEpoch = new Map(prior.epochs).get(scope(who));
  nextEpoch ??= sourceEpoch;
  const epochs = new Map(prior.epochs); epochs.set(scope(who), nextEpoch);
  const authority = { version: 3, kind: "authority", publication: id, operation: id, parent: prior.publication,
    checkpoint: prior.checkpoint, head: id, generation: prior.generation + 1, epochs: orderedEpochs(epochs) };
  const batch = { version: 3, kind: "batch", id, authority, previous, identity: who, sourceEpoch, nextEpoch,
    payload, changes: [...changes].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0) };
  storage.values.set(M1_RECORD + id, JSON.stringify(batch));
  storage.values.set(M1_AUTHORITY, JSON.stringify(authority));
  return batch;
}
function make({ rows = [], limits = {}, seeded = true, storage = new MemoryStorage(), clock = new Clock(), scheduler = new Scheduler() } = {}) {
  if (seeded && !storage.values.has(M1_AUTHORITY)) seed(storage, rows);
  for (const [key, value] of oldBytes) if (!storage.values.has(key)) storage.values.set(key, value);
  let currentA = A, currentB = A, idA = 0, idB = 0;
  const planeA = createStoragePlaneM1ForFixtures({ storage: () => storage, current: () => currentA,
    locks: scheduler, clock, id: () => "op-a-" + String(++idA).padStart(4, "0") }, limits);
  const planeB = createStoragePlaneM1ForFixtures({ storage: () => storage, current: () => currentB,
    locks: scheduler, clock, id: () => "op-b-" + String(++idB).padStart(4, "0") }, limits);
  return { storage, scheduler, clock, planeA, planeB,
    setA: (value) => { currentA = value; }, setB: (value) => { currentB = value; } };
}
async function run(fixture, promise) {
  assert.equal(fixture.scheduler.grant(), true, "fixture must grant one actual queued job");
  return await promise;
}
function values(plane) {
  const result = plane.capture();
  assert.equal(result.state, "ready", JSON.stringify(result));
  return new Map(result.entries);
}
function unchangedOld(storage) { for (const [key, value] of oldBytes) assert.equal(storage.values.get(key), value); }
function quota() { const error = new Error("synthetic quota"); error.name = "QuotaExceededError"; return error; }
function copy(storage) { const result = new MemoryStorage(); result.values = new Map(storage.values); return result; }
function storedBytes(storage) {
  return [...storage.values].filter(([key]) => key.startsWith(M1_NAMESPACE))
    .reduce((sum, [key, raw]) => sum + byteLength(key) + byteLength(raw), 0);
}

test("M1 constants are frozen; empty first read/status and construction leave all namespaces untouched", async () => {
  assert.deepEqual(M1_LIMITS, { keyUnits: 4096, slots: 4096, authorityBytes: 16384, projectionBytes: 4194304,
    changedSlots: 128, batchBytes: 524288, chainBatches: 128, chainBytes: 2097152, retainedRecords: 512,
    retainedBytes: 8388608, readAttempts: 2, queuedJobs: 32, queuedBytes: 2097152, waitMs: 10000,
    recoveryBytes: 2097152, enumerationSlots: 4096 });
  assert.equal(M1_LOCK, "vortx.web.storage.writer");
  const f = make({ seeded: false }), before = [...f.storage.values];
  assert.deepEqual(f.planeA.capture(), { state: "blocked", code: "uninitialized" });
  assert.deepEqual(f.planeA.status(), { state: "blocked", code: "uninitialized" });
  assert.equal((await f.planeA.submit("not-initialization", (d) => d.set("x", "x"))).code, "uninitialized");
  assert.deepEqual([...f.storage.values], before); assert.equal(f.storage.writes.length, 0);
});

test("stale receipt after B commit rejects before callback and preserves unrelated data and epochs", async () => {
  const f = make({ rows: [[scope(B), "saved", "B0"]] });
  const snapshot = f.planeA.capture(); assert.equal(snapshot.state, "ready");
  f.setB(B);
  assert.equal((await run(f, f.planeB.submit("save-B1", (d) => d.set("saved", "B1")))).state, "committed");
  let invoked = 0;
  const result = await run(f, f.planeA.submit("stale-restore", (d) => { invoked++; d.set("A", "value"); }, { expected: snapshot.receipt }));
  assert.equal(result.state, "noncommit"); assert.equal(result.code, "conflict"); assert.equal(invoked, 0);
  assert.equal(values(f.planeB).get("saved"), "B1"); assert.equal(f.planeB.capture().epoch, "epoch-B");
  assert.equal((await f.planeA.submit("", () => {}, { expected: { kind: "m1-snapshot" } })).code, "invalid_receipt");
  unchangedOld(f.storage);
});

test("exact final-authority rival admission cannot enter while the first logical owner is held", async () => {
  const f = make(); let rival, rivalRuns = 0, admissionAtFinalPointer = false;
  f.storage.beforeSet = (key) => {
    if (key === M1_AUTHORITY && !admissionAtFinalPointer) {
      admissionAtFinalPointer = true;
      rival = f.planeB.submit("rival-add", (d) => { rivalRuns++; d.set("B", "accepted"); });
      assert.equal(f.scheduler.grant(), false);
      assert.equal(rivalRuns, 0);
    }
  };
  const first = await run(f, f.planeA.submit("first-add", (d) => d.set("A", "accepted")));
  assert.equal(first.state, "committed"); assert.equal(admissionAtFinalPointer, true);
  assert.equal((await run(f, rival)).state, "committed");
  assert.deepEqual([...values(f.planeA)], [["A", "accepted"], ["B", "accepted"]]);
  unchangedOld(f.storage);
});

test("two same-admission logical additions read the fresh locked collection", async () => {
  const f = make({ rows: [[scope(A), "library", "[]"]] });
  const add = (name) => (d) => d.set("library", JSON.stringify([...JSON.parse(d.get("library")), name]));
  const first = f.planeA.submit("X", add("X")), second = f.planeB.submit("Y", add("Y"));
  assert.equal((await run(f, first)).state, "committed");
  assert.equal((await run(f, second)).state, "committed");
  assert.deepEqual(JSON.parse(values(f.planeA).get("library")), ["X", "Y"]);
});

for (const order of ["add-remove", "remove-add"]) test("explicit removal remains ordered: " + order, async () => {
  const f = make({ rows: [[scope(A), "library", '["X"]']] });
  const add = (d) => d.set("library", JSON.stringify([...new Set([...JSON.parse(d.get("library")), "X"])]));
  const remove = (d) => d.set("library", JSON.stringify(JSON.parse(d.get("library")).filter((id) => id !== "X")));
  const callbacks = order === "add-remove" ? [add, remove] : [remove, add];
  const one = f.planeA.submit(order + "-1", callbacks[0]), two = f.planeB.submit(order + "-2", callbacks[1]);
  await run(f, one); await run(f, two);
  assert.deepEqual(JSON.parse(values(f.planeA).get("library")), order === "add-remove" ? [] : ["X"]);
});

test("multi-key values and context epochs read all old or all new; unrelated epoch unchanged", async () => {
  const f = make({ rows: [[scope(A), "one", "old"], [scope(A), "two", "old"]] }), observations = [];
  f.storage.afterSet = () => {
    const snapshot = f.planeB.capture(); assert.equal(snapshot.state, "ready");
    observations.push({ rows: [...snapshot.entries], epoch: snapshot.epoch });
  };
  const result = await run(f, f.planeA.submit("pair", (d) => { d.set("one", "new"); d.set("two", "new"); d.advanceEpoch(); }));
  assert.equal(result.state, "committed");
  assert.deepEqual(observations, [
    { rows: [["one", "old"], ["two", "old"]], epoch: "epoch-A" },
    { rows: [["one", "new"], ["two", "new"]], epoch: result.attempt.operation },
  ]);
  f.setB(B); assert.equal(f.planeB.capture().epoch, "epoch-B");
});

test("same-byte callback is an unchanged operation without epoch advance or disk writes", async () => {
  const f = make({ rows: [[scope(A), "one", "same"]] });
  const result = await run(f, f.planeA.submit("same", (d) => { d.set("one", "same"); d.advanceEpoch(); }));
  assert.equal(result.state, "unchanged"); assert.equal(f.planeA.capture().epoch, "epoch-A");
  assert.equal(f.storage.writes.length, 0);
});

for (const phase of ["stage-before", "stage-after", "head-before", "stage-readback"]) {
  test("quota/readback failure has no durable acknowledgement: " + phase, async () => {
    const f = make(), before = f.storage.values.get(M1_AUTHORITY);
    if (phase === "stage-before") f.storage.beforeSet = (key) => { if (key.startsWith(M1_RECORD)) throw quota(); };
    if (phase === "stage-after") f.storage.afterSet = (key) => { if (key.startsWith(M1_RECORD)) throw quota(); };
    if (phase === "head-before") f.storage.beforeSet = (key) => { if (key === M1_AUTHORITY) throw quota(); };
    if (phase === "stage-readback") f.storage.afterSet = (key) => { if (key.startsWith(M1_RECORD)) f.storage.denied = true; };
    const result = await run(f, f.planeA.submit("save", (d) => d.set("new", "value")));
    f.storage.denied = false;
    assert.equal(result.state, "noncommit"); assert.equal(f.storage.values.get(M1_AUTHORITY), before);
    assert.equal(values(f.planeA).has("new"), false); unchangedOld(f.storage);
  });
}
test("head write that throws after publishing is committed when exact readback proves it", async () => {
  const f = make();
  f.storage.afterSet = (key) => { if (key === M1_AUTHORITY) throw quota(); };
  const result = await run(f, f.planeA.submit("save", (d) => d.set("new", "value")));
  assert.equal(result.state, "committed"); assert.equal(values(f.planeA).get("new"), "value");
  assert.throws(() => { throw new Error("postcommit UI failure"); });
  assert.equal((await f.planeA.resolve(result.attempt)).state, "committed");
  assert.equal(values(f.planeA).get("new"), "value");
});

test("published ambiguous outcome resolves through an acknowledged successor and never replays", async () => {
  const f = make(); let invoked = 0;
  f.storage.afterSet = (key) => { if (key === M1_AUTHORITY) f.storage.denied = true; };
  const pending = await run(f, f.planeA.submit("toggle-once", (d) => { invoked++; d.set("one", d.get("one") ? "off" : "on"); }));
  assert.equal(pending.state, "pending");
  f.storage.denied = false; f.storage.afterSet = undefined;
  assert.equal((await run(f, f.planeB.submit("successor", (d) => d.set("two", "new")))).state, "committed");
  const before = [...f.storage.values], writeCount = f.storage.writes.length;
  const resolved = await run(f, f.planeA.resolve(pending.attempt));
  assert.equal(resolved.state, "committed"); assert.equal(resolved.attempt, pending.attempt); assert.equal(invoked, 1);
  assert.equal((await f.planeA.resolve(pending.attempt)).state, "committed");
  assert.deepEqual([...f.storage.values], before); assert.equal(f.storage.writes.length, writeCount);
});

test("retained orphan plus unavailable publication readback is pending, then proves only noncommit", async () => {
  const f = make(), before = f.storage.values.get(M1_AUTHORITY);
  f.storage.beforeSet = (key) => { if (key === M1_AUTHORITY) { f.storage.denied = true; throw quota(); } };
  const pending = await run(f, f.planeA.submit("orphan", (d) => d.set("orphan", "retained")));
  assert.equal(pending.state, "pending");
  assert.ok(f.storage.values.has(M1_RECORD + pending.attempt.operation));
  f.storage.denied = false; f.storage.beforeSet = undefined;
  assert.equal((await run(f, f.planeA.resolve(pending.attempt))).state, "noncommit");
  assert.equal(f.storage.values.get(M1_AUTHORITY), before);
  assert.equal(values(f.planeA).has("orphan"), false);
  assert.ok(f.storage.values.has(M1_RECORD + pending.attempt.operation), "orphan remains physical recovery material");
});

test("pending proof requires exact raw payload and owner, and foreign/forged attempt tokens fail closed", async () => {
  const f = make();
  f.storage.afterSet = (key) => { if (key === M1_AUTHORITY) f.storage.denied = true; };
  const pending = await run(f, f.planeA.submit("original-payload", (d) => d.set("one", "original")));
  f.storage.denied = false; f.storage.afterSet = undefined;
  const key = M1_RECORD + pending.attempt.operation, batch = JSON.parse(f.storage.values.get(key));
  batch.payload = "different-payload"; f.storage.values.set(key, JSON.stringify(batch));
  assert.equal((await run(f, f.planeA.resolve(pending.attempt))).state, "pending");
  assert.equal((await f.planeB.resolve(pending.attempt)).code, "invalid_attempt");
  assert.equal((await f.planeA.resolve({ ...pending.attempt })).code, "invalid_attempt");
  f.setA(B);
  assert.equal((await f.planeA.resolve(pending.attempt)).code, "retired");
});

test("callback throw, thenable and escaped draft cannot publish or remain writable", async () => {
  const f = make(); let escaped;
  const thrown = await run(f, f.planeA.submit("throw", (d) => { escaped = d; d.set("x", "bad"); throw new Error("user callback"); }));
  assert.equal(thrown.code, "callback"); assert.throws(() => escaped.set("x", "late"), /revoked_draft/);
  const thenable = await run(f, f.planeA.submit("async", (d) => { escaped = d; d.set("x", "bad"); return { then() {} }; }));
  assert.equal(thenable.code, "async_callback"); assert.throws(() => escaped.get("x"), /revoked_draft/);
  const getter = await run(f, f.planeA.submit("then-getter", (d) => ({ get then() { d.set("x", "late"); } })));
  assert.equal(getter.state, "noncommit"); assert.equal(getter.code, "revoked_draft");
  assert.equal(f.storage.writes.length, 0); assert.equal(values(f.planeA).has("x"), false);
});

test("admission captures exact owner/session/native and rejects a changed binding at lock entry or prepublication", async () => {
  const f = make(); let invoked = 0;
  const waiting = f.planeA.submit("A", () => { invoked++; });
  f.setA({ ...A, native: "other-binding" });
  assert.equal((await run(f, waiting)).code, "retired"); assert.equal(invoked, 0);
  f.setA(A);
  const changed = await run(f, f.planeA.submit("A", (d) => { d.set("x", "A"); f.setA(B); }));
  assert.equal(changed.code, "retired"); assert.equal(f.storage.writes.length, 0);
  f.setA(A);
  const committed = await run(f, f.planeA.submit("A", (d) => d.set("x", "A")));
  assert.equal(f.planeA.permitsEffect(committed.receipt), true);
  f.setA(B); assert.equal(f.planeA.permitsEffect(committed.receipt), false);
  assert.equal(f.planeA.permitsEffect({ ...committed.receipt }), false);
});

test("auth race after final check stays exactly A-bound and never grants B an effect", async () => {
  const f = make();
  f.storage.beforeSet = (key) => { if (key === M1_AUTHORITY) f.setA(B); };
  const result = await run(f, f.planeA.submit("A-only", (d) => d.set("secret", "A-value")));
  assert.equal(result.state, "committed"); assert.equal(f.planeA.permitsEffect(result.receipt), false);
  assert.equal(values(f.planeA).has("secret"), false);
  f.setA(A); assert.equal(values(f.planeA).get("secret"), "A-value");
});

test("abort before entry and abort racing grant do not invoke callback; held owner is never stolen", async () => {
  const f = make(); let invoked = 0;
  const signal = new AbortController();
  const request = f.planeA.submit("abort", () => { invoked++; }, { signal: signal.signal });
  signal.abort();
  assert.equal((await request).code, "aborted"); assert.equal(invoked, 0);
  f.scheduler.ignoreAbortForGrantRace = true;
  const secondSignal = new AbortController();
  const race = f.planeA.submit("race", () => { invoked++; }, { signal: secondSignal.signal });
  secondSignal.abort();
  assert.equal((await run(f, race)).code, "aborted"); assert.equal(invoked, 0);
  f.scheduler.ignoreAbortForGrantRace = false; f.scheduler.heldExternally = true;
  const waiting = f.planeA.submit("held", () => { invoked++; });
  f.clock.tick(10000);
  assert.equal((await waiting).code, "busy");
  assert.equal(f.scheduler.heldExternally, true); assert.equal(invoked, 0); assert.equal(f.storage.writes.length, 0);
});

test("deadline is inclusive at 10000 ms; grant at 9999 is admitted and later time does not steal entry", async () => {
  const f = make();
  const beforeDeadline = f.planeA.submit("within", (d) => { f.clock.tick(100000); d.set("x", "saved"); });
  f.clock.tick(9999);
  assert.equal((await run(f, beforeDeadline)).state, "committed");
  const timedOut = f.planeA.submit("deadline", () => { assert.fail("late callback"); });
  f.clock.tick(10000);
  assert.equal((await timedOut).code, "busy");
});

test("unsupported/denied production lock adapter has no unlocked durable fallback", async () => {
  // Narrow adapter test with synthetic navigator only; no real browser or account is accessed.
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  try {
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: {} });
    await assert.rejects(platformM1Locks().run(new AbortController().signal, () => assert.fail("unlocked")), /unsupported_lock/);
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: { locks: { request: async () => { throw new Error("denied"); } } } });
    await assert.rejects(platformM1Locks().run(new AbortController().signal, () => assert.fail("unlocked")), /unsupported_lock/);
    let observed;
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: { locks: { request: async (name, options, callback) => {
      observed = { name, mode: options.mode, steal: options.steal }; return callback({});
    } } } });
    const failure = new Error("body storage failure");
    await assert.rejects(platformM1Locks().run(new AbortController().signal, () => { throw failure; }), (error) => error === failure);
    assert.deepEqual(observed, { name: M1_LOCK, mode: "exclusive", steal: undefined });
  } finally {
    if (descriptor) Object.defineProperty(globalThis, "navigator", descriptor); else delete globalThis.navigator;
  }
});

for (const kind of ["missing", "cycle", "parent", "generation", "future-authority", "future-record", "duplicate-slot", "tombstone", "owner-epoch"]) {
  test("corrupt/missing/future material fails closed without a read repair: " + kind, () => {
    const f = make({ rows: [[scope(A), "x", "saved"]] });
    let batch;
    if (["cycle", "parent", "generation", "tombstone", "owner-epoch"].includes(kind)) batch = append(f.storage, [["x", "next"]]);
    if (kind === "missing") f.storage.values.delete(M1_RECORD + "genesis");
    if (kind === "future-authority") {
      const a = JSON.parse(f.storage.values.get(M1_AUTHORITY)); a.version = 4;
      f.storage.values.set(M1_AUTHORITY, JSON.stringify(a));
    }
    if (kind === "future-record" || kind === "duplicate-slot") {
      const cp = JSON.parse(f.storage.values.get(M1_RECORD + "genesis"));
      if (kind === "future-record") cp.version = 4; else cp.rows.push(cp.rows[0]);
      f.storage.values.set(M1_RECORD + "genesis", JSON.stringify(cp));
    }
    if (batch) {
      if (kind === "parent") batch.authority.parent = "wrong-parent";
      if (kind === "generation") batch.authority.generation++;
      if (kind === "tombstone") batch.changes[0][1] = { invalid: "not a string or tombstone" };
      if (kind === "owner-epoch") batch.sourceEpoch = "foreign-epoch";
      if (kind === "cycle") {
        const prior = { ...batch.authority };
        batch.previous = JSON.stringify(prior);
        batch.authority = { ...batch.authority, parent: batch.id, generation: prior.generation + 1 };
      }
      f.storage.values.set(M1_RECORD + batch.id, JSON.stringify(batch));
      f.storage.values.set(M1_AUTHORITY, JSON.stringify(batch.authority));
    }
    const before = [...f.storage.values];
    assert.equal(f.planeA.capture().state, "blocked"); assert.equal(f.planeA.status().state, "blocked");
    assert.deepEqual([...f.storage.values], before); assert.equal(f.storage.writes.length, 0); unchangedOld(f.storage);
  });
}

test("same head with changed raw records is fully reread, and old exact source receipt is rejected", async () => {
  const f = make({ rows: [[scope(A), "x", "before"]] }), snapshot = f.planeA.capture();
  const key = M1_RECORD + "genesis", cp = JSON.parse(f.storage.values.get(key));
  cp.rows[0][2] = "after"; f.storage.values.set(key, JSON.stringify(cp));
  assert.equal(values(f.planeA).get("x"), "after", "no stale pointer-only cache");
  const result = await run(f, f.planeA.submit("", (d) => d.set("y", "unsafe"), { expected: snapshot.receipt }));
  assert.equal(result.code, "conflict"); assert.equal(f.storage.writes.length, 0);
});

test("two changing complete reads stop at the exact retry ceiling, with no spin or writes", () => {
  const f = make({ rows: [[scope(A), "x", "before"]] }); let checkpointGets = 0;
  f.storage.beforeGet = (key) => {
    if (key === M1_RECORD + "genesis" && ++checkpointGets % 2 === 0) {
      const cp = JSON.parse(f.storage.values.get(key)); cp.rows[0][2] += "x";
      f.storage.values.set(key, JSON.stringify(cp));
    }
  };
  assert.deepEqual(f.planeA.capture(), { state: "blocked", code: "conflict" });
  assert.equal(checkpointGets, 4, "two census reads and two source-validation reads");
  assert.equal(f.storage.writes.length, 0);
});

test("every pure read/status/receipt effect check leaves raw/v2/unknown bytes unchanged", async () => {
  const f = make({ rows: [[scope(A), "x", "saved"]] });
  const result = await run(f, f.planeA.submit("receipt", (d) => d.set("y", "saved")));
  const before = [...f.storage.values], writes = f.storage.writes.length;
  for (let i = 0; i < 3; i++) {
    const read = f.planeA.capture(); assert.equal(read.state, "ready");
    assert.ok(Object.isFrozen(read.entries)); assert.ok(read.entries.every(Object.isFrozen));
    assert.throws(() => read.entries.push(["late", "mutation"]));
    f.planeA.status(); f.planeA.permitsEffect(result.receipt);
  }
  assert.deepEqual([...f.storage.values], before); assert.equal(f.storage.writes.length, writes); unchangedOld(f.storage);
});

test("logical key at 4096 units is accepted; 4097 is rejected without truncation", async () => {
  const f = make(), at = "k".repeat(4096), over = at + "x";
  assert.equal((await run(f, f.planeA.submit("", (d) => d.set(at, "kept")))).state, "committed");
  const before = [...f.storage.values];
  assert.equal((await run(f, f.planeA.submit("", (d) => d.set(over, "rejected")))).code, "over_budget");
  assert.deepEqual([...f.storage.values], before); assert.equal(values(f.planeA).get(at), "kept");
});
test("4096 live slots are readable; 4097 cannot be published", async () => {
  const rows = Array.from({ length: 4096 }, (_, i) => [scope(A), "key-" + String(i).padStart(4, "0"), "v"]);
  const f = make({ rows });
  assert.equal(f.planeA.capture().entries.length, 4096);
  assert.equal((await run(f, f.planeA.submit("", (d) => d.set("extra", "rejected")))).code, "over_budget");
  assert.equal(f.storage.writes.length, 0);
});
test("128 changed slots commit together; 129 changed slots reject together", async () => {
  for (const count of [128, 129]) {
    const f = make();
    const result = await run(f, f.planeA.submit("", (d) => {
      for (let i = 0; i < count; i++) d.set("key-" + String(i).padStart(3, "0"), "v");
    }));
    assert.equal(result.state, count === 128 ? "committed" : "noncommit");
    assert.equal(values(f.planeA).size, count === 128 ? 128 : 0);
  }
});
test("128 active batches are readable; batch 129 refuses progress without compaction/deletion", async () => {
  const f = make();
  for (let i = 0; i < 128; i++) append(f.storage, [["x", String(i)]]);
  assert.equal(values(f.planeA).get("x"), "127");
  const before = [...f.storage.values];
  assert.equal((await run(f, f.planeA.submit("", (d) => d.set("x", "129")))).code, "over_budget");
  assert.deepEqual([...f.storage.values], before);
  append(f.storage, [["x", "unsupported-129"]]);
  assert.equal(f.planeA.capture().code, "over_budget");
});
test("512 retained namespace records including orphans are accepted; 513 are preserved and blocked", () => {
  const f = make();
  for (let i = 0; i < 510; i++) {
    const cp = genesis([], undefined, "orphan-" + String(i).padStart(4, "0")).checkpoint;
    f.storage.values.set(M1_RECORD + cp.id, JSON.stringify(cp));
  }
  assert.equal(f.planeA.capture().state, "ready");
  const cp = genesis([], undefined, "orphan-over").checkpoint;
  f.storage.values.set(M1_RECORD + cp.id, JSON.stringify(cp));
  const before = [...f.storage.values];
  assert.equal(f.planeA.capture().code, "over_budget"); assert.deepEqual([...f.storage.values], before);
});

function padRecord(object, targetBytes, change) {
  assert.equal(targetBytes % 2, 0);
  const base = JSON.stringify(object);
  const extra = targetBytes / 2 - base.length;
  assert.ok(extra >= 0);
  change("x".repeat(extra));
  const raw = JSON.stringify(object); assert.equal(byteLength(raw), targetBytes); return raw;
}
test("authority at 16 KiB reads coherently; one UTF-16 unit over is retained and blocked", () => {
  const epochs = [[scope(A), "epoch-A"], [scope(B), "epoch-B"],
    [scope({ owner: "padding-1-" + "a".repeat(2500), native: null }), "e"],
    [scope({ owner: "padding-2-" + "b".repeat(2500), native: null }), "e"],
    [scope({ owner: "padding-3-", native: null }), "e"]];
  const g = genesis([], epochs);
  const missing = M1_LIMITS.authorityBytes / 2 - JSON.stringify(g.authority).length;
  g.authority.epochs = orderedEpochs([...epochs.slice(0, -1), [scope({ owner: "padding-3-" + "c".repeat(missing), native: null }), "e"]]);
  assert.equal(byteLength(JSON.stringify(g.authority)), M1_LIMITS.authorityBytes);
  const f = make();
  f.storage.values.set(M1_RECORD + "genesis", JSON.stringify(g.checkpoint));
  f.storage.values.set(M1_AUTHORITY, JSON.stringify(g.authority));
  assert.equal(f.planeA.capture().state, "ready");
  const last = g.authority.epochs.findIndex(([key]) => key.includes("padding-3-"));
  const [owner, native] = JSON.parse(g.authority.epochs[last][0]);
  g.authority.epochs[last][0] = scope({ owner: owner + "c", native });
  f.storage.values.set(M1_RECORD + "genesis", JSON.stringify(g.checkpoint));
  f.storage.values.set(M1_AUTHORITY, JSON.stringify(g.authority));
  assert.equal(f.planeA.capture().code, "over_budget");
});
test("checkpoint at 4 MiB reads; one serialized UTF-16 unit over is blocked unchanged", () => {
  const f = make(), cp = genesis([[scope(A), "large", ""]]).checkpoint;
  const raw = padRecord(cp, M1_LIMITS.projectionBytes, (padding) => { cp.rows[0][2] = padding; });
  f.storage.values.set(M1_RECORD + "genesis", raw);
  assert.equal(f.planeA.capture().state, "ready");
  cp.rows[0][2] += "x"; f.storage.values.set(M1_RECORD + "genesis", JSON.stringify(cp));
  assert.equal(f.planeA.capture().code, "over_budget"); assert.equal(f.storage.writes.length, 0);
});
test("materialized projection at 4 MiB reads; one unit beyond blocks the complete projection", () => {
  const f = make(), cp = genesis([[scope(A), "base", ""]]).checkpoint;
  f.storage.values.set(M1_RECORD + "genesis",
    padRecord(cp, M1_LIMITS.projectionBytes - 200_000, (padding) => { cp.rows[0][2] = padding; }));
  const batch = append(f.storage, [["growth", ""]]);
  const rows = ordered([...cp.rows, [scope(A), "growth", ""]]);
  const extra = M1_LIMITS.projectionBytes / 2 - JSON.stringify({ version: 3, rows, epochs: batch.authority.epochs }).length;
  batch.changes[0][1] = "g".repeat(extra); rows.find((row) => row[1] === "growth")[2] = batch.changes[0][1];
  assert.equal(byteLength(JSON.stringify({ version: 3, rows, epochs: batch.authority.epochs })), M1_LIMITS.projectionBytes);
  f.storage.values.set(M1_RECORD + batch.id, JSON.stringify(batch));
  assert.equal(f.planeA.capture().state, "ready");
  batch.changes[0][1] += "x"; f.storage.values.set(M1_RECORD + batch.id, JSON.stringify(batch));
  assert.equal(f.planeA.capture().code, "over_budget");
});
test("batch at 512 KiB reads; one serialized unit beyond fails without deleting the record", () => {
  const f = make(), batch = append(f.storage, [["x", "saved"]]);
  f.storage.values.set(M1_RECORD + batch.id,
    padRecord(batch, M1_LIMITS.batchBytes, (padding) => { batch.payload = padding; }));
  assert.equal(f.planeA.capture().state, "ready");
  batch.payload += "x"; f.storage.values.set(M1_RECORD + batch.id, JSON.stringify(batch));
  assert.equal(f.planeA.capture().code, "over_budget"); assert.equal(f.storage.writes.length, 0);
});
test("chain at 2 MiB reads; one serialized unit beyond fails before materialization", () => {
  const f = make(); let total = 0, last;
  for (let i = 0; i < 5; i++) {
    const batch = append(f.storage, [["x", String(i)]]);
    const target = i < 4 ? 420_000 : M1_LIMITS.chainBytes - total;
    const raw = padRecord(batch, target, (padding) => { batch.payload = padding; });
    f.storage.values.set(M1_RECORD + batch.id, raw); total += byteLength(raw); last = batch;
  }
  assert.equal(total, M1_LIMITS.chainBytes); assert.equal(f.planeA.capture().state, "ready");
  last.payload += "x"; f.storage.values.set(M1_RECORD + last.id, JSON.stringify(last));
  assert.equal(f.planeA.capture().code, "over_budget");
});
test("8 MiB retained physical accounting includes key bytes and orphan checkpoints", () => {
  const f = make();
  const one = genesis([[scope(A), "large", ""]], undefined, "orphan-large-one").checkpoint;
  f.storage.values.set(M1_RECORD + one.id,
    padRecord(one, M1_LIMITS.projectionBytes, (padding) => { one.rows[0][2] = padding; }));
  const two = genesis([[scope(A), "large", ""]], undefined, "orphan-large-two").checkpoint;
  const available = M1_LIMITS.retainedBytes - storedBytes(f.storage) - byteLength(M1_RECORD + two.id);
  f.storage.values.set(M1_RECORD + two.id, padRecord(two, available, (padding) => { two.rows[0][2] = padding; }));
  assert.equal(storedBytes(f.storage), M1_LIMITS.retainedBytes);
  assert.equal(f.planeA.capture().state, "ready");
  two.rows[0][2] += "x"; f.storage.values.set(M1_RECORD + two.id, JSON.stringify(two));
  assert.equal(f.planeA.capture().code, "over_budget"); unchangedOld(f.storage);
});

test("32 queued jobs retained; 33rd is rejected without evicting earlier requests", async () => {
  const f = make(); f.scheduler.heldExternally = true;
  const requests = Array.from({ length: 32 }, (_, i) => f.planeA.submit(String(i), () => assert.fail("held")));
  assert.equal(f.scheduler.requests.length, 32);
  assert.equal((await f.planeA.submit("33", () => assert.fail("overflow"))).code, "over_budget");
  assert.equal(f.scheduler.requests.length, 32);
  f.clock.tick(10000);
  assert.ok((await Promise.all(requests)).every((result) => result.code === "busy"));
  assert.equal(f.scheduler.heldExternally, true);
});
test("2 MiB captured queue payload is admitted; one unit over is rejected before lock acquisition", async () => {
  for (const over of [false, true]) {
    const f = make(); f.scheduler.heldExternally = true;
    const base = JSON.stringify({ identity: A, epoch: "epoch-A", payload: "", expected: null, operation: "op-a-0001" });
    const payload = "q".repeat(M1_LIMITS.queuedBytes / 2 - base.length + Number(over));
    const request = f.planeA.submit(payload, () => assert.fail("held"));
    if (over) {
      assert.equal((await request).code, "over_budget"); assert.equal(f.scheduler.requests.length, 0);
    } else {
      assert.equal(f.scheduler.requests.length, 1);
      f.clock.tick(10000); assert.equal((await request).code, "busy");
    }
    assert.equal(f.storage.writes.length, 0);
  }
});

test("exact fixture recovery ceiling retains pending evidence; cap plus one rejects before staging; resolution frees no disk bytes", async () => {
  const recoveryPayload = "recovery-payload-" + "p".repeat(4096);
  const baseline = make(), before = { authority: baseline.storage.values.get(M1_AUTHORITY),
    records: [[M1_RECORD + "genesis", baseline.storage.values.get(M1_RECORD + "genesis")]] };
  const acknowledged = await run(baseline, baseline.planeA.submit(recoveryPayload, (d) => d.set("x", "saved")));
  const operation = acknowledged.attempt.operation, key = M1_RECORD + operation;
  const evidence = { before, expected: baseline.storage.values.get(M1_AUTHORITY), key, raw: baseline.storage.values.get(key),
    identity: A, payload: recoveryPayload, operation };
  const cost = byteLength(JSON.stringify(evidence));
  assert.ok(cost < M1_LIMITS.recoveryBytes);
  for (const reduction of [0, 1]) {
    const f = make({ limits: { recoveryBytes: cost - reduction } });
    f.storage.afterSet = (key) => { if (key === M1_AUTHORITY) f.storage.denied = true; };
    const result = await run(f, f.planeA.submit(recoveryPayload, (d) => d.set("x", "saved")));
    if (reduction) {
      assert.equal(result.code, "over_budget"); assert.equal(f.storage.writes.length, 0);
    } else {
      assert.equal(result.state, "pending"); f.storage.denied = false; f.storage.afterSet = undefined;
      const beforeNext = [...f.storage.values];
      f.setA(B);
      const next = await run(f, f.planeA.submit("second", (d) => d.set("y", "must-not-evict")));
      assert.equal(next.code, "over_budget"); assert.deepEqual([...f.storage.values], beforeNext);
      assert.equal((await f.planeA.resolve(result.attempt)).code, "retired");
      f.setA(A);
      const count = f.storage.writes.length;
      assert.equal((await run(f, f.planeA.resolve(result.attempt))).state, "committed");
      assert.equal(f.storage.writes.length, count);
      assert.equal((await run(f, f.planeA.submit("after-resolution", (d) => d.set("y", "saved")))).state, "committed");
    }
  }
});
test("4096 origin enumeration slots are bounded; 4097 old/unknown keys are preserved and unsupported", () => {
  const f = make(); let index = 0;
  while (f.storage.values.size < 4096) f.storage.values.set("unrelated-old-" + index++, "keep");
  assert.equal(f.planeA.capture().state, "ready");
  f.storage.values.set("unrelated-over", "keep");
  const before = [...f.storage.values];
  assert.equal(f.planeA.capture().code, "over_budget"); assert.deepEqual([...f.storage.values], before);
});
test("reused stage ID is a collision and never overwrites physical evidence", async () => {
  const f = make(), orphan = genesis([], undefined, "op-a-0001").checkpoint;
  f.storage.values.set(M1_RECORD + orphan.id, JSON.stringify(orphan));
  const before = [...f.storage.values];
  assert.equal((await run(f, f.planeA.submit("", (d) => d.set("x", "no")))).code, "id_collision");
  assert.deepEqual([...f.storage.values], before);
});

test("bounded enumeration detects new namespace records arriving during the scan and never reads old values", () => {
  const f = make();
  for (let i = 0; i < 509; i++) {
    const cp = genesis([], undefined, "scan-orphan-" + String(i).padStart(4, "0")).checkpoint;
    f.storage.values.set(M1_RECORD + cp.id, JSON.stringify(cp));
  }
  let inserted = false;
  f.storage.beforeGet = (key) => assert.ok(key.startsWith(M1_NAMESPACE), "old/raw/v2 values are not read for census");
  f.storage.beforeKey = (index) => {
    if (index === 1 && !inserted) {
      inserted = true;
      for (const id of ["late-orphan-one", "late-orphan-two"]) {
        const cp = genesis([], undefined, id).checkpoint;
        f.storage.values.set(M1_RECORD + id, JSON.stringify(cp));
      }
    }
  };
  assert.equal(f.planeA.capture().code, "over_budget");
  assert.equal(f.storage.writes.length, 0); unchangedOld(f.storage);
});
test("unknown new-namespace address is blocked and preserved, including on status reads", () => {
  const f = make(); f.storage.values.set(M1_NAMESPACE + "future-partition", "uninterpreted");
  const before = [...f.storage.values];
  assert.equal(f.planeA.capture().state, "blocked"); assert.equal(f.planeA.status().state, "blocked");
  assert.deepEqual([...f.storage.values], before); assert.equal(f.storage.writes.length, 0);
});
test("a fresh second coherent-read attempt is allowed, while first-attempt mutation is never cached", () => {
  const f = make({ rows: [[scope(A), "x", "before"]] }); let gets = 0;
  f.storage.beforeGet = (key) => {
    if (key === M1_RECORD + "genesis" && ++gets === 2) {
      const cp = JSON.parse(f.storage.values.get(key)); cp.rows[0][2] = "second";
      f.storage.values.set(key, JSON.stringify(cp));
    }
  };
  assert.equal(values(f.planeA).get("x"), "second");
  assert.equal(gets, 5);
  assert.equal(f.storage.writes.length, 0);
});
test("a waiting old epoch is rejected after a rival logical restore, before its callback runs", async () => {
  const f = make(); let invoked = 0;
  const first = f.planeB.submit("restore", (d) => { d.set("x", "restored"); d.advanceEpoch(); });
  const waiting = f.planeA.submit("old-surface", () => { invoked++; });
  assert.equal((await run(f, first)).state, "committed");
  assert.equal((await run(f, waiting)).code, "retired"); assert.equal(invoked, 0);
  assert.equal(values(f.planeA).get("x"), "restored");
});
test("abort after entry never steals the owner or rolls back an acknowledged mutation", async () => {
  const f = make(), signal = new AbortController();
  const result = await run(f, f.planeA.submit("entered", (d) => {
    signal.abort(); d.set("x", "saved");
  }, { signal: signal.signal }));
  assert.equal(result.state, "committed"); assert.equal(values(f.planeA).get("x"), "saved");
});
test("draft caps apply during callback and a caught rejected edit cannot retain oversized speculative state", async () => {
  const f = make({ limits: { changedSlots: 1 } });
  const result = await run(f, f.planeA.submit("bounded", (d) => {
    d.set("kept", "saved");
    assert.throws(() => d.set("extra", "rejected"), /over_budget/);
    assert.deepEqual(d.keys(), ["kept"]);
  }));
  assert.equal(result.state, "committed"); assert.deepEqual([...values(f.planeA)], [["kept", "saved"]]);
});
test("orphan changes during callback invalidate physical accounting before any staged write", async () => {
  const f = make();
  const result = await run(f, f.planeA.submit("physical-change", (d) => {
    d.set("x", "candidate");
    const cp = genesis([], undefined, "uncoordinated-orphan").checkpoint;
    f.storage.values.set(M1_RECORD + cp.id, JSON.stringify(cp));
  }));
  assert.equal(result.code, "conflict"); assert.equal(f.storage.writes.length, 0);
  assert.equal(values(f.planeA).has("x"), false);
});

test("a transport rejection after the lock body acknowledged commit cannot reclassify or roll it back", async () => {
  const f = make(), runOriginal = f.scheduler.run.bind(f.scheduler);
  f.scheduler.run = (signal, body) => runOriginal(signal, body).then(() => { throw new Error("post-body delivery failed"); });
  const result = await run(f, f.planeA.submit("save", (d) => d.set("x", "acknowledged")));
  assert.equal(result.state, "committed"); assert.equal(values(f.planeA).get("x"), "acknowledged");
  assert.equal((await f.planeA.resolve(result.attempt)).state, "committed");
});

test("pending noncommit requires every exact prior source record, retains its charge, and never replays", async () => {
  for (const changedKind of ["checkpoint", "earlier-batch"]) {
    const rows = [[scope(A), "x", "before"]], payload = "orphan-provenance-" + "p".repeat(4096);
    const baseline = make({ rows });
    if (changedKind === "earlier-batch") append(baseline.storage, [["x", "before-batch"]]);
    const before = { authority: baseline.storage.values.get(M1_AUTHORITY),
      records: [[M1_RECORD + "genesis", baseline.storage.values.get(M1_RECORD + "genesis")]] };
    if (changedKind === "earlier-batch") before.records.push([M1_RECORD + "manual-0001",
      baseline.storage.values.get(M1_RECORD + "manual-0001")]);
    const acknowledged = await run(baseline, baseline.planeA.submit(payload, (d) => d.set("y", "candidate")));
    assert.equal(acknowledged.state, "committed");
    const operation = acknowledged.attempt.operation, key = M1_RECORD + operation;
    const cost = byteLength(JSON.stringify({ before, expected: baseline.storage.values.get(M1_AUTHORITY),
      key, raw: baseline.storage.values.get(key), identity: A, payload, operation }));
    const f = make({ rows, limits: { recoveryBytes: cost } });
    if (changedKind === "earlier-batch") append(f.storage, [["x", "before-batch"]]);
    let invoked = 0;
    f.storage.beforeSet = (name) => {
      if (name === M1_AUTHORITY) { f.storage.denied = true; throw quota(); }
    };
    const pending = await run(f, f.planeA.submit(payload, (d) => { invoked++; d.set("y", "candidate"); }));
    assert.equal(pending.state, "pending"); assert.equal(pending.attempt.operation, operation);
    f.storage.denied = false; f.storage.beforeSet = undefined;
    const changedKey = M1_RECORD + (changedKind === "checkpoint" ? "genesis" : "manual-0001");
    const original = f.storage.values.get(changedKey), changed = JSON.parse(original);
    if (changedKind === "checkpoint") changed.rows[0][2] = "different-source";
    else changed.changes[0][1] = "different-source";
    f.storage.values.set(changedKey, JSON.stringify(changed));
    assert.equal(f.storage.values.get(M1_AUTHORITY), before.authority);
    assert.equal(f.planeA.capture().state, "ready", "changed predecessor is structurally valid");
    const count = f.storage.writes.length, rawPending = f.storage.values.get(key);
    for (let retry = 0; retry < 2; retry++) {
      const result = await run(f, f.planeA.resolve(pending.attempt));
      assert.equal(result.state, "pending"); assert.equal(result.attempt, pending.attempt);
      assert.equal(invoked, 1); assert.equal(f.storage.writes.length, count);
    }
    f.setA(B);
    assert.equal((await run(f, f.planeA.submit("second-context", (d) => d.set("z", "no-eviction")))).code, "over_budget");
    assert.equal((await f.planeA.resolve(pending.attempt)).code, "retired");
    assert.equal(f.storage.writes.length, count); assert.equal(f.storage.values.get(key), rawPending);
    f.setA(A); f.storage.values.set(changedKey, original);
    const resolved = await run(f, f.planeA.resolve(pending.attempt));
    assert.equal(resolved.state, "noncommit"); assert.equal(resolved.attempt, pending.attempt);
    assert.equal(invoked, 1); assert.equal(f.storage.writes.length, count);
    assert.equal(f.storage.values.get(key), rawPending, "terminal proof does not delete the orphan");
    assert.equal(f.storage.values.get(M1_AUTHORITY), before.authority);
    assert.equal((await f.planeA.resolve(pending.attempt)).state, "noncommit");
    const explicit = await run(f, f.planeA.submit(payload, (d) => { invoked++; d.set("y", "candidate"); }));
    assert.equal(explicit.state, "committed"); assert.notEqual(explicit.attempt.operation, operation);
    assert.equal(invoked, 2); unchangedOld(f.storage);
  }
});

test("production recovery ceiling includes complete prior Source at exactly 2 MiB and one UTF-16 unit beyond", async () => {
  const payload = "exact-production-recovery", baseline = make({ rows: [[scope(A), "base", ""]] });
  const before = { authority: baseline.storage.values.get(M1_AUTHORITY),
    records: [[M1_RECORD + "genesis", baseline.storage.values.get(M1_RECORD + "genesis")]] };
  const acknowledged = await run(baseline, baseline.planeA.submit(payload, (d) => d.set("new", "value")));
  assert.equal(acknowledged.state, "committed");
  const operation = acknowledged.attempt.operation, key = M1_RECORD + operation;
  const evidence = { before, expected: baseline.storage.values.get(M1_AUTHORITY), key,
    raw: baseline.storage.values.get(key), identity: A, payload, operation };
  const baseCost = byteLength(JSON.stringify(evidence));
  const padding = (M1_LIMITS.recoveryBytes - baseCost) / 2;
  assert.equal(Number.isSafeInteger(padding), true); assert.ok(padding > 0);
  for (const over of [0, 1]) {
    const f = make({ rows: [[scope(A), "base", "p".repeat(padding + over)]] });
    const exactBefore = { authority: f.storage.values.get(M1_AUTHORITY),
      records: [[M1_RECORD + "genesis", f.storage.values.get(M1_RECORD + "genesis")]] };
    assert.equal(byteLength(JSON.stringify({ ...evidence, before: exactBefore })), M1_LIMITS.recoveryBytes + 2 * over);
    assert.equal(f.planeA.capture().state, "ready");
    const saved = [...f.storage.values];
    const result = await run(f, f.planeA.submit(payload, (d) => d.set("new", "value")));
    if (over) {
      assert.equal(result.state, "noncommit"); assert.equal(result.code, "over_budget");
      assert.equal(f.storage.writes.length, 0); assert.deepEqual([...f.storage.values], saved);
    } else assert.equal(result.state, "committed");
    unchangedOld(f.storage);
  }
});

test("readable source too large for complete pending proof rejects before staging without narrowing evidence", async () => {
  const f = make({ rows: [[scope(A), "large", "v".repeat(1_100_000)]] });
  assert.equal(f.planeA.capture().state, "ready");
  const before = [...f.storage.values]; let invoked = 0;
  const result = await run(f, f.planeA.submit("small-edit", (d) => { invoked++; d.set("small", "saved"); }));
  assert.equal(result.state, "noncommit"); assert.equal(result.code, "over_budget");
  assert.equal(invoked, 1); assert.equal(f.storage.writes.length, 0);
  assert.deepEqual([...f.storage.values], before); unchangedOld(f.storage);
});

test("effect permission requires exact acknowledged raw payload, identity and changes, not only its descriptor", async () => {
  for (const changedKind of ["payload", "session", "changed-value", "owner-native"]) {
    const f = make();
    const committed = await run(f, f.planeA.submit("original-payload", (d) => d.set("x", "original")));
    assert.equal(committed.state, "committed"); assert.equal(f.planeA.permitsEffect(committed.receipt), true);
    const key = M1_RECORD + committed.attempt.operation, original = f.storage.values.get(key);
    const changed = JSON.parse(original), descriptor = JSON.stringify(changed.authority);
    if (changedKind === "payload") changed.payload = "different-payload";
    if (changedKind === "session") changed.identity.session = "different-session";
    if (changedKind === "changed-value") changed.changes[0][1] = "different-value";
    if (changedKind === "owner-native") {
      changed.identity = B; changed.sourceEpoch = "epoch-B"; changed.nextEpoch = "epoch-B";
    }
    f.storage.values.set(key, JSON.stringify(changed));
    assert.equal(JSON.stringify(changed.authority), descriptor);
    const count = f.storage.writes.length, changedStorage = [...f.storage.values];
    assert.equal(f.planeA.capture().state, "ready", "tampered exact record remains structurally valid");
    assert.equal(f.planeA.status().state, "ready");
    assert.equal(f.planeA.permitsEffect(committed.receipt), false);
    assert.equal(f.planeA.permitsEffect({ ...committed.receipt }), false);
    assert.equal(f.planeB.permitsEffect(committed.receipt), false);
    assert.equal(await f.planeA.resolve(committed.attempt), committed, "terminal outcome remains historical truth");
    assert.equal(f.storage.writes.length, count); assert.deepEqual([...f.storage.values], changedStorage);
    f.storage.values.set(key, original);
    const restored = [...f.storage.values];
    assert.equal(f.planeA.permitsEffect(committed.receipt), true);
    assert.equal(f.storage.writes.length, count); assert.deepEqual([...f.storage.values], restored);
    unchangedOld(f.storage);
  }
});

test("exact committed effect proof survives valid descendants but not same-context epoch retirement", async () => {
  const f = make();
  const committed = await run(f, f.planeA.submit("first", (d) => d.set("x", "original")));
  assert.equal(committed.state, "committed");
  assert.equal((await run(f, f.planeA.submit("descendant", (d) => d.set("y", "new")))).state, "committed");
  let count = f.storage.writes.length;
  assert.equal(f.planeA.permitsEffect(committed.receipt), true); assert.equal(f.storage.writes.length, count);
  f.setB(B);
  assert.equal((await run(f, f.planeB.submit("foreign-descendant", (d) => { d.set("b", "new"); d.advanceEpoch(); }))).state, "committed");
  count = f.storage.writes.length;
  assert.equal(f.planeA.permitsEffect(committed.receipt), true); assert.equal(f.storage.writes.length, count);
  assert.equal((await run(f, f.planeA.submit("same-owner-restore", (d) => { d.set("x", "restored"); d.advanceEpoch(); }))).state, "committed");
  const saved = [...f.storage.values]; count = f.storage.writes.length;
  assert.equal(f.planeA.permitsEffect(committed.receipt), false);
  assert.equal(await f.planeA.resolve(committed.attempt), committed);
  assert.equal(f.planeA.capture().state, "ready"); assert.equal(f.planeA.status().state, "ready");
  assert.equal(f.storage.writes.length, count); assert.deepEqual([...f.storage.values], saved);
  unchangedOld(f.storage);
});

for (const terminal of ["committed", "noncommit"]) {
  test("twin queued resolution preserves exact " + terminal + " outcome after owner retirement", async () => {
    const f = make(); let invoked = 0;
    if (terminal === "committed") {
      f.storage.afterSet = (key) => { if (key === M1_AUTHORITY) f.storage.denied = true; };
    } else {
      f.storage.beforeSet = (key) => {
        if (key === M1_AUTHORITY) { f.storage.denied = true; throw quota(); }
      };
    }
    const pending = await run(f, f.planeA.submit("twin-resolution", (d) => { invoked++; d.set("x", "candidate"); }));
    assert.equal(pending.state, "pending");
    f.storage.denied = false; f.storage.beforeSet = undefined; f.storage.afterSet = undefined;
    const saved = [...f.storage.values], count = f.storage.writes.length;
    const first = f.planeA.resolve(pending.attempt), second = f.planeA.resolve(pending.attempt);
    assert.equal(f.scheduler.requests.length, 2, "both resolutions queue while evidence is unfinished");
    const finished = await run(f, first);
    assert.equal(finished.state, terminal); assert.equal(finished.attempt, pending.attempt);
    assert.equal(f.scheduler.requests.length, 1);
    f.setA(B);
    const afterRetirement = await run(f, second);
    assert.equal(afterRetirement, finished, "later queued retirement cannot turn terminal state back into pending");
    assert.equal(await f.planeA.resolve(pending.attempt), finished);
    assert.equal(await f.planeA.resolve(pending.attempt), finished);
    assert.equal(invoked, 1); assert.equal(f.storage.writes.length, count);
    assert.deepEqual([...f.storage.values], saved); unchangedOld(f.storage);
  });
}
