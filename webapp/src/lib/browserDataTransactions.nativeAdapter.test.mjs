// SAVED, NOT EXECUTED. Drives the ACTUAL native adapter with fake IDB events; not browser proof.
import assert from "node:assert/strict";
import { test } from "node:test";
import { browserDataTransactionFixtures as fixtures, DATA_LIMITS as L } from "./browserDataTransactions.ts";

const names = ["meta", "contexts", "records", "attempts", "outbox", "recovery"];
const canonical = value => value && typeof value === "object"
  ? Array.isArray(value) ? "[" + value.map(canonical).join(",") + "]"
    : "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}"
  : JSON.stringify(value);
const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const identity = ["account", "A", "profile", null];
const admission = canonical({ context: identity, epoch: 1, generation: "G1" });
const command = canonical({ version: 1, kind: "library", type: "movie", id: "x", desired: true,
  seed: { type: "movie", id: "x", history: [{ keep: true }] }, fixture: null });

class Clock {
  now = 0; serial = 0; timers = [];
  later = (delay, body) => {
    const timer = { id: ++this.serial, at: this.now + delay, delay, active: true, body };
    this.timers.push(timer); return () => { timer.active = false; };
  };
  advance(ms) {
    this.now += ms;
    for (const timer of this.timers) if (timer.active && timer.at <= this.now) { timer.active = false; timer.body(); }
  }
}

/** Storage/request shim only: no reducer, provenance, reservations or operation outcomes. */
class FakeDB {
  onversionchange = null; onclose = null; closes = 0; transactions = [];
  tables = new Map(names.map(name => [name, new Map()]));
  constructor() {
    const row = fixtures.initialRow();
    this.tables.get("meta").set(canonical(row.key), row);
  }
  close() { this.closes++; }
  dump() { return canonical([...this.tables].map(([name, rows]) => [name, [...rows]])); }
  transaction(stores, mode, options) {
    assert.ok(stores.every(name => names.includes(name)));
    if (mode === "readwrite") assert.deepEqual(options, { durability: "strict" });
    const db = this;
    const tx = {
      error: null, oncomplete: null, onabort: null, onerror: null, mode,
      tasks: [], requests: [], abortCalls: 0, aborted: false, done: false, working: null, writes: 0,
      firstAbortThrows: false,
      ensure() {
        this.working ??= new Map([...db.tables].map(([name, rows]) => [name, new Map([...rows].map(([key, row]) => [key, clone(row)]))]));
      },
      abort() {
        this.abortCalls++;
        if (this.firstAbortThrows || this.abortCalls > 1) throw Object.assign(new Error("inactive"), { name: "InvalidStateError" });
        this.aborted = true;
      },
      request(work) {
        const r = { result: undefined, error: null, onsuccess: null, onerror: null };
        this.requests.push(r);
        this.tasks.push(() => {
          if (this.aborted) { r.error = { name: "AbortError" }; r.onerror?.(); return; }
          this.ensure(); r.result = work(); r.onsuccess?.();
        });
        return r;
      },
      objectStore(store) {
        const cursor = (index, query) => {
          const r = { result: undefined, error: null, onsuccess: null, onerror: null };
          let keys = null, at = 0;
          const step = () => {
            if (tx.aborted) { r.error = { name: "AbortError" }; r.onerror?.(); return; }
            tx.ensure();
            keys ??= [...tx.working.get(store).values()]
              .filter(row => query === null || canonical(row[index]) === canonical(query.key))
              .map(row => clone(row.key)).sort((a, b) => canonical(a).localeCompare(canonical(b)));
            r.result = at < keys.length ? { primaryKey: keys[at], continue() { at++; tx.tasks.push(step); } } : null;
            r.onsuccess?.();
          };
          tx.requests.push(r); tx.tasks.push(step); return r;
        };
        return {
          get: key => tx.request(() => clone(tx.working.get(store).get(canonical(key)))),
          put: row => tx.request(() => { assert.equal(mode, "readwrite"); tx.writes++; tx.working.get(store).set(canonical(row.key), clone(row)); return clone(row.key); }),
          delete: key => tx.request(() => { assert.equal(mode, "readwrite"); tx.writes++; tx.working.get(store).delete(canonical(key)); }),
          openKeyCursor: query => cursor(null, query),
          index: index => ({ openKeyCursor: query => cursor(index, query) }),
        };
      },
      deliverOne() { const task = this.tasks.shift(); assert.ok(task); task(); },
      finish() {
        let steps = 0;
        while (this.tasks.length) { assert.ok(++steps < 10000); this.deliverOne(); }
        this.done = true;
        if (this.aborted) { this.onabort?.(); return; }
        if (mode === "readwrite" && this.working) db.tables = this.working;
        this.oncomplete?.();
      },
    };
    this.transactions.push(tx); return tx;
  }
  pending() { return this.transactions.find(tx => !tx.done); }
  grant() { const tx = this.pending(); assert.ok(tx); tx.finish(); return tx; }
}
function keyRange(t) {
  const previous = globalThis.IDBKeyRange;
  globalThis.IDBKeyRange = { only: key => ({ key }) };
  t.after(() => { if (previous === undefined) delete globalThis.IDBKeyRange; else globalThis.IDBKeyRange = previous; });
}
function direct() {
  const db = new FakeDB(), port = fixtures.nativeAdapter(db), events = [];
  let entered = 0;
  assert.equal(db.transactions.length, 0, "constructing the seam neither opens a DB nor starts a transaction");
  const observed = {
    entered: () => { entered++; },
    complete: () => events.push({ kind: "complete" }),
    abort: reason => events.push({ kind: "abort", reason }),
    unknown: reason => events.push({ kind: "unknown", reason }),
  };
  return { db, port, events, observed, entered: () => entered };
}
async function done(db, promise) { db.grant(); return await promise; }
async function setup(t) {
  keyRange(t);
  const db = new FakeDB(), clock = new Clock();
  let nonce = 0;
  const plane = fixtures.create(fixtures.nativeAdapter(db), { currentAdmission: () => admission },
    () => (++nonce).toString(16).padStart(64, "0"), clock);
  assert.equal((await done(db, plane.audit())).kind, "open");
  assert.equal((await done(db, plane.createContext())).kind, "context-created");
  const h = plane.admit(command).handle;
  assert.equal((await done(db, plane.prepare(h))).kind, "prepared");
  return { db, clock, plane, h };
}

for (const trigger of ["request-error", "validation-throw"]) test(
  "native adapter preserves first abort cause and waits for onabort: " + trigger,
  () => {
    const h = direct(); let callbacks = 0;
    h.port.run("readwrite", ["meta"], tx => {
      tx.get("meta", ["first"], () => {});
      tx.get("meta", ["queued-error"], () => {});
      tx.get("meta", ["queued-success"], () => { callbacks++; tx.put("meta", { mustNotWrite: true }); });
      if (trigger === "validation-throw") throw new Error("capacity");
    }, h.observed);
    const tx = h.db.pending(), firstCause = trigger === "request-error" ? "QuotaExceededError" : "capacity";
    if (trigger === "request-error") { tx.requests[0].error = { name: firstCause }; tx.requests[0].onerror(); }
    assert.equal(tx.abortCalls, 1); assert.deepEqual(h.events, []);
    tx.requests[1].error = { name: "AbortError" }; tx.requests[1].onerror();
    tx.error = { name: "AbortError" }; tx.onerror(); tx.requests[2].onsuccess();
    assert.equal(tx.abortCalls, 1); assert.equal(callbacks, 0); assert.equal(tx.writes, 0);
    assert.equal(h.entered(), trigger === "request-error" ? 1 : 0, "late events cannot re-enter after requested abort");
    assert.deepEqual(h.events, [], "no premature terminal result");
    tx.onabort();
    assert.deepEqual(h.events, [{ kind: "abort", reason: firstCause }]);
    tx.onerror(); tx.oncomplete(); h.db.onclose();
    assert.deepEqual(h.events, [{ kind: "abort", reason: firstCause }]);
  },
);

test("native connection loss before onabort stays unknown", () => {
  const h = direct();
  h.port.run("readwrite", ["meta"], tx => { tx.get("meta", ["first"], () => {}); }, h.observed);
  const tx = h.db.pending();
  tx.requests[0].error = { name: "QuotaExceededError" }; tx.requests[0].onerror();
  assert.deepEqual(h.events, []); h.db.onclose();
  assert.deepEqual(h.events, [{ kind: "unknown", reason: "connection-closed" }]);
  tx.onabort(); assert.deepEqual(h.events, [{ kind: "unknown", reason: "connection-closed" }]);
});

test("throwing FIRST abort request is unknown, not observed noncommit", () => {
  const h = direct();
  h.port.run("readwrite", ["meta"], tx => { tx.get("meta", ["first"], () => {}); }, h.observed);
  const tx = h.db.pending(); tx.firstAbortThrows = true;
  tx.requests[0].error = { name: "QuotaExceededError" }; tx.requests[0].onerror();
  assert.equal(tx.abortCalls, 1); assert.deepEqual(h.events, [{ kind: "unknown", reason: "abort-unavailable" }]);
  tx.onabort(); assert.deepEqual(h.events, [{ kind: "unknown", reason: "abort-unavailable" }]);
});

test("queued native apply timeout awaits abort and preserves exact prepared proposal/counters", async t => {
  const { db, clock, plane, h } = await setup(t), before = db.dump();
  let settled = false;
  const pending = plane.apply(h).then(value => { settled = true; return value; }), tx = db.pending();
  assert.equal(tx.requests.length, 1); assert.equal(tx.writes, 0);
  clock.advance(L.waitMs);
  assert.equal(tx.abortCalls, 1); assert.equal(settled, false); assert.equal(db.dump(), before);
  tx.finish(); // Delivers queued AbortError before the actual native abort event.
  const result = await pending;
  assert.equal(result.kind, "unavailable"); assert.equal(result.reason, "entry-timeout");
  assert.equal(tx.abortCalls, 1); assert.equal(tx.writes, 0); assert.equal(db.dump(), before);
  assert.equal((await done(db, plane.resolve(h))).kind, "prepared");
});

test("first native request event ends pre-entry deadline; later waiting is never stolen", async t => {
  const { db, clock, plane, h } = await setup(t);
  const pending = plane.apply(h), tx = db.pending(), timer = clock.timers.at(-1);
  assert.equal(timer.active, true); tx.deliverOne(); // global-row success, not transaction completion.
  assert.equal(timer.active, false);
  clock.advance(10 * L.waitMs); assert.equal(tx.abortCalls, 0);
  tx.finish(); assert.equal((await pending).kind, "committed");
});

test("coordinator and native admission share one original timer, not two ten-second windows", async t => {
  keyRange(t);
  const db = new FakeDB(), clock = new Clock();
  const plane = fixtures.create(fixtures.nativeAdapter(db), { currentAdmission: () => admission }, () => "1".repeat(64), clock);
  const first = plane.audit(), second = plane.audit();
  const firstTimer = clock.timers[0], secondTimer = clock.timers[1];
  assert.equal(clock.timers.length, 2); assert.equal(secondTimer.at, L.waitMs);
  clock.advance(3000); db.grant(); assert.equal((await first).kind, "open");
  const queuedNative = db.pending();
  assert.equal(firstTimer.active, false); assert.equal(secondTimer.active, true);
  assert.equal(clock.timers.length, 2, "dispatch must not install a replacement timer");
  clock.advance(L.waitMs - 3001); assert.equal(queuedNative.abortCalls, 0);
  clock.advance(1); assert.equal(queuedNative.abortCalls, 1);
  assert.equal(secondTimer.id, clock.timers[1].id); assert.equal(secondTimer.active, false);
  queuedNative.finish();
  assert.equal((await second).reason, "entry-timeout");
  assert.equal(queuedNative.abortCalls, 1);
  // Timer lateness in a blocked JS event loop is not measured or guaranteed by this scheduler.
});
