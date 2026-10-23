// SAVED, NOT EXECUTED by preparation author. Synthetic IDB semantics are not browser evidence.
import assert from "node:assert/strict";
import { test } from "node:test";
import { DATA_LIMITS as L, browserDataTransactionFixtures as fixtures } from "./browserDataTransactions.ts";

const stores = ["meta", "contexts", "records", "attempts", "outbox", "recovery"];
const canonical = value => {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  return "{" + Object.keys(value).sort().map(k => JSON.stringify(k) + ":" + canonical(value[k])).join(",") + "}";
};
const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const bytes = raw => raw.length * 2;
const A = ["account", "owner-A", "profile-A", null];
const B = ["account", "owner-B", "profile-B", "native-B"];
const admission = (context = A, epoch = 1, generation = "session-A") => canonical({ context, epoch, generation });
const command = (id = "x", desired = true, type = "movie", extra = {}, fixture = null) => canonical({
  version: 1, kind: "library", type, id, desired, seed: desired ? { type, id, name: id, ...extra } : null, fixture,
});
const data = row => JSON.parse(row.text);
function packed(row, next) {
  const base = { ...row, text: canonical(next), bytes: 0 };
  for (let i = 0; i < 8; i++) {
    const actual = bytes(canonical(base));
    if (actual === base.bytes) return base;
    base.bytes = actual;
  }
  throw new Error("fixture envelope did not stabilize");
}

class Clock {
  pending = new Set();
  later = (_ms, fn) => { this.pending.add(fn); return () => this.pending.delete(fn); };
  expire() { for (const fn of [...this.pending]) fn(); }
}
/** Only storage scheduling/atomic commit/abort. No production reducer, receipts or accounting here. */
class Database {
  tables = new Map(stores.map(store => [store, new Map()]));
  pending = [];
  behavior = [];
  attemptedWrites = 0;
  commits = 0;
  transactionKinds = [];
  expireRowLeases = false;
  legacy = new Map([
    ["vortx.web.library.v1", ' [ { "id":"legacy", "unknown":{"keep":true} } ] '],
    ["vortx.web.storage.v2.root", "preserve-old-root"],
    ["vortx.web.sync-intents.v1.foreign", '{"pending":"do-not-touch"}'],
  ]);
  constructor() {
    const row = fixtures.initialRow();
    this.tables.get("meta").set(canonical(row.key), clone(row));
  }
  rows(store) { return [...this.tables.get(store).values()].map(clone); }
  dump() { return canonical([...this.tables].map(([name, rows]) => [name, [...rows]])); }
  mode(next) { this.behavior.push(next); }
  port(identity = {}) {
    let closed = false;
    return {
      identity,
      close: () => { closed = true; },
      run: (mode, scopedStores, body, events) => {
        if (closed) { events.unknown("fixture-closed"); return () => {}; }
        assert.deepEqual([...scopedStores].sort(), [...stores].sort());
        const job = { mode, body, events, entered: false, behavior: this.behavior.shift() ?? "complete" };
        this.pending.push(job);
        return () => {
          if (job.entered) return;
          const i = this.pending.indexOf(job);
          if (i >= 0) { this.pending.splice(i, 1); events.abort("entry-timeout"); }
        };
      },
    };
  }
  markEntered() {
    const job = this.pending[0];
    if (job && !job.entered) { job.entered = true; job.events.entered(); }
  }
  grant() {
    this.markEntered();
    const job = this.pending.shift();
    if (!job) return false;
    this.transactionKinds.push(job.mode);
    const working = new Map([...this.tables].map(([store, rows]) => [store, new Map([...rows].map(([key, row]) => [key, clone(row)]))]));
    const requests = [];
    let aborted = null, requestsSeen = 0;
    const enqueue = fn => { requests.push(fn); };
    const tx = {
      abort: reason => { aborted ??= reason; },
      get: (store, key, receive) => enqueue(() => {
        const row = clone(working.get(store).get(canonical(key)));
        if (row === undefined || !this.expireRowLeases) { receive(row); return; }
        const lease = Proxy.revocable(row, {});
        try { receive(lease.proxy); } finally { lease.revoke(); }
      }),
      put: (store, row) => enqueue(() => {
        assert.equal(job.mode, "readwrite");
        this.attemptedWrites++;
        if (job.behavior === "quota-put") throw new Error("QuotaExceededError");
        if (store === "attempts") for (const existing of working.get(store).values()) {
          if (canonical(existing.key) !== canonical(row.key) && canonical(existing.nonceKey) === canonical(row.nonceKey))
            throw new Error("ConstraintError");
        }
        working.get(store).set(canonical(row.key), clone(row));
      }),
      delete: (store, key) => enqueue(() => {
        assert.equal(job.mode, "readwrite"); this.attemptedWrites++;
        if (job.behavior === "quota-put") throw new Error("QuotaExceededError");
        working.get(store).delete(canonical(key));
      }),
      keys: (store, index, match, receive, end) => {
        const keys = [...working.get(store).values()]
          .filter(row => match === null || canonical(row[index]) === canonical(match))
          .map(row => clone(row.key)).sort((a, b) => canonical(a).localeCompare(canonical(b)));
        let at = 0;
        const step = () => enqueue(() => {
          if (at === keys.length) { end(); return; }
          let advanced = false;
          receive(keys[at++], () => { assert.equal(advanced, false); advanced = true; step(); });
        });
        step();
      },
    };
    try {
      job.body(tx);
      while (!aborted && requests.length) {
        assert.ok(++requestsSeen < 100_000, "fixture request runaway");
        requests.shift()();
      }
    } catch (e) { aborted = e.message; }
    if (job.behavior === "abort-after-requests") aborted ??= "after-request-success";
    if (job.behavior === "abort-unknown") aborted ??= "unknown-abort";
    if (aborted) {
      if (job.behavior === "abort-unknown") job.events.unknown("lost-abort-delivery");
      else job.events.abort(aborted);
    } else {
      if (job.mode === "readwrite") { this.tables = working; this.commits++; }
      if (job.behavior === "commit-unknown") job.events.unknown("lost-completion-delivery");
      else job.events.complete();
    }
    return true;
  }
  flush() { let turns = 0; while (this.pending.length) { assert.ok(++turns < 1000); this.grant(); } }
}
function realm(db, start = admission(), nonceSeed = 0) {
  let current = start, nonce = nonceSeed;
  const clock = new Clock();
  const plane = fixtures.create(db.port(), { currentAdmission: () => current },
    () => (++nonce).toString(16).padStart(64, "0"), clock);
  return { plane, clock, set: next => { current = next; } };
}
async function finish(db, pending) { db.flush(); return await pending; }
async function setup(db = new Database(), start = admission(), nonceSeed = 0) {
  const r = realm(db, start, nonceSeed);
  assert.equal((await finish(db, r.plane.audit())).kind, "open");
  assert.equal((await finish(db, r.plane.createContext())).kind, "context-created");
  return { db, ...r };
}
function admitted(plane, raw = command()) {
  const result = plane.admit(raw); assert.equal(result.kind, "admitted", result.reason); return result.handle;
}
async function prepared(db, plane, raw = command()) {
  const h = admitted(plane, raw);
  assert.equal((await finish(db, plane.prepare(h))).kind, "prepared");
  return h;
}
async function committed(db, plane, raw = command()) {
  const h = await prepared(db, plane, raw), result = await finish(db, plane.apply(h));
  assert.ok(["committed", "unchanged"].includes(result.kind), result.reason);
  return { h, result };
}
const global = db => data(db.rows("meta")[0]);
const context = db => data(db.rows("contexts")[0]);

test("construction, audit, admission and read failures never initialize a context or touch legacy bytes", async () => {
  const db = new Database(), before = db.dump(), legacy = canonical([...db.legacy]), r = realm(db);
  assert.equal(db.dump(), before);
  assert.equal((await finish(db, r.plane.audit())).kind, "open");
  admitted(r.plane);
  assert.equal((await finish(db, r.plane.snapshot())).kind, "unavailable");
  assert.equal(db.dump(), before);
  assert.equal(canonical([...db.legacy]), legacy);
  assert.equal(db.attemptedWrites, 0);
});

test("request success then transaction abort is a definite aborted PREPARE, not durable acceptance", async () => {
  const { db, plane } = await setup(), before = db.dump(), h = admitted(plane);
  db.mode("abort-after-requests");
  const result = await finish(db, plane.prepare(h));
  assert.equal(result.kind, "prepare-aborted");
  assert.equal(db.dump(), before);
  assert.ok(db.attemptedWrites > 0);
  assert.strictEqual(await plane.prepare(h), result);
  assert.strictEqual(await plane.resolve(h), result);
});

test("lost PREPARE completion resolves SAME handle without a second allocation", async () => {
  const { db, plane } = await setup(), h = admitted(plane);
  db.mode("commit-unknown");
  assert.equal((await finish(db, plane.prepare(h))).kind, "pending");
  assert.equal(db.rows("attempts").length, 1);
  assert.equal((await finish(db, plane.prepare(h))).kind, "prepared");
  assert.equal(context(db).allocated, 1);
  assert.equal((await finish(db, plane.apply(h))).kind, "committed");
  assert.equal(context(db).allocated, 1);
});

test("reload before sequence delivery discovers existing references and never replays them", async () => {
  const { db, plane } = await setup(), h = admitted(plane);
  db.mode("commit-unknown"); await finish(db, plane.prepare(h));
  const fresh = realm(db, admission(), 100);
  assert.equal((await finish(db, fresh.plane.audit())).kind, "open");
  const before = db.dump(), discovered = await finish(db, fresh.plane.discover());
  assert.equal(discovered.kind, "discovered"); assert.equal(discovered.items.length, 1);
  assert.equal(discovered.items[0].state, "prepared"); assert.equal(db.dump(), before);
  const got = await finish(db, fresh.plane.apply(discovered.items[0].handle));
  assert.equal(got.kind, "committed"); assert.equal(context(db).allocated, 1);
  assert.equal((await fresh.plane.prepare(discovered.items[0].handle)).kind, "committed");
});

test("aborted provisional sequence occupied by rival never returns rival success", async () => {
  const { db, plane } = await setup(), h = admitted(plane);
  db.mode("abort-unknown"); assert.equal((await finish(db, plane.prepare(h))).kind, "pending");
  const rival = realm(db, admission(), 100); await finish(db, rival.plane.audit());
  await committed(db, rival.plane, command("rival"));
  assert.equal(context(db).allocated, 1);
  const result = await finish(db, plane.resolve(h));
  assert.equal(result.kind, "unavailable"); assert.equal(result.reason, "attempt-identity");
  assert.equal(db.rows("records").length, 1);
});

test("two queued applies deduplicate one prepared ID; cached terminal survives owner retirement", async () => {
  const { db, plane, set } = await setup(), h = await prepared(db, plane);
  const first = plane.apply(h), second = plane.apply(h);
  db.grant(); const result = await first;
  set(admission(B, 1, "B"));
  db.grant();
  assert.strictEqual(await second, result);
  assert.strictEqual(await plane.resolve(h), result);
  assert.equal(context(db).revision, 1); assert.equal(db.rows("records").length, 1);
});

test("two logical adds both survive and identical IDs of different type remain distinct", async () => {
  const { db, plane } = await setup(), rival = realm(db, admission(), 100);
  await finish(db, rival.plane.audit());
  const a = await prepared(db, plane, command("same", true, "movie"));
  const b = await prepared(db, rival.plane, command("same", true, "series"));
  const pa = plane.apply(a), pb = rival.plane.apply(b); db.flush(); await pa; await pb;
  const snap = await finish(db, plane.snapshot());
  assert.deepEqual(JSON.parse(snap.snapshot).records.map(r => r.title).sort(), [["movie", "same"], ["series", "same"]]);
});

for (const order of [[true, false], [false, true]]) test("explicit membership order " + order.join(" -> "), async () => {
  const { db, plane } = await setup(), first = await prepared(db, plane, command("x", order[0]));
  const second = await prepared(db, plane, command("x", order[1]));
  await finish(db, plane.apply(first)); await finish(db, plane.apply(second));
  assert.equal(data(db.rows("records")[0]).membership, order[1]);
  assert.equal(context(db).revision, 2);
});

test("absent remove creates intent; repeated desired membership is a no-op with unchanged data revision", async () => {
  const { db, plane } = await setup();
  const first = await committed(db, plane, command("x", false));
  assert.equal(first.result.kind, "committed"); assert.equal(first.result.revision, 1);
  const raw = db.rows("records")[0].text;
  const second = await committed(db, plane, command("x", false));
  assert.equal(second.result.kind, "unchanged"); assert.equal(second.result.revision, 1);
  assert.equal(context(db).allocated, 2); assert.equal(db.rows("records")[0].text, raw);
  assert.equal(db.rows("outbox").length, 0);
});

test("unknown JSON siblings/history survive remove, later add and technical retirement", async () => {
  const { db, plane } = await setup();
  const extra = JSON.parse('{"history":[{"at":4,"future":{"x":null}}],"unknown":{"__proto__":{"safe":"data"}}}');
  const added = await committed(db, plane, command("x", true, "movie", extra));
  const original = canonical(data(db.rows("records")[0]).entry);
  await finish(db, plane.observe(added.result.receipt));
  const removed = await committed(db, plane, command("x", false));
  await finish(db, plane.observe(removed.result.receipt));
  const again = await committed(db, plane, command("x", true, "movie", { name: "new seed is not a metadata edit" }));
  await finish(db, plane.observe(again.result.receipt));
  assert.equal(canonical(data(db.rows("records")[0]).entry), original);
  assert.equal(data(db.rows("records")[0]).membership, true);
  assert.equal(db.rows("attempts").length, 0);
});

test("one other same-owner consumer may observe while origin is suspended; stale handle cannot replay", async () => {
  const { db, plane } = await setup(), h = await prepared(db, plane);
  db.mode("commit-unknown"); assert.equal((await finish(db, plane.apply(h))).kind, "pending");
  const other = realm(db, admission(), 100); await finish(db, other.plane.audit());
  const found = await finish(db, other.plane.discover());
  assert.equal(found.items[0].outcome.kind, "committed");
  assert.equal((await finish(db, other.plane.observe(found.items[0].outcome.receipt))).kind, "details-retired");
  const before = db.dump(), resolved = await finish(db, plane.resolve(h));
  assert.equal(resolved.kind, "details-retired");
  assert.strictEqual(await plane.apply(h), resolved); assert.equal(db.dump(), before);
});

test("authentic terminal receipt only, and current other-owner ACK is rejected", async () => {
  const { db, plane, set } = await setup(), { result } = await committed(db, plane), before = db.dump();
  assert.equal((await plane.observe({ ...result.receipt })).reason, "foreign-receipt");
  assert.equal((await plane.apply({ kind: "operation" })).reason, "foreign-operation");
  set(admission(B, 1, "B"));
  assert.equal((await plane.observe(result.receipt)).reason, "owner-retired");
  assert.equal(db.dump(), before);
});

test("lost observation completion resolves retired details without mutating user data", async () => {
  const { db, plane } = await setup(), { result } = await committed(db, plane), saved = db.rows("records")[0].text;
  db.mode("commit-unknown"); assert.equal((await finish(db, plane.observe(result.receipt))).kind, "pending");
  assert.equal((await finish(db, plane.observe(result.receipt))).kind, "details-retired");
  assert.equal(db.rows("records")[0].text, saved); assert.equal(db.rows("attempts").length, 0);
});

test("quota/abort during apply preserves exact prepared proposal and reservation", async () => {
  const { db, plane } = await setup(), h = await prepared(db, plane), before = db.dump();
  db.mode("quota-put"); assert.equal((await finish(db, plane.apply(h))).kind, "unavailable");
  assert.equal(db.dump(), before);
  assert.equal((await finish(db, plane.resolve(h))).kind, "prepared");
  assert.equal((await finish(db, plane.apply(h))).kind, "committed");
});

test("quota during observation/retirement keeps old row, intervals and accounting; no rollback of saved result", async () => {
  const { db, plane } = await setup(), { h, result } = await committed(db, plane), before = db.dump();
  db.mode("quota-put"); assert.equal((await finish(db, plane.observe(result.receipt))).kind, "unavailable");
  assert.equal(db.dump(), before); assert.strictEqual(await plane.resolve(h), result);
  assert.equal((await finish(db, plane.observe(result.receipt))).kind, "details-retired");
});

test("retired intervals do not cover pending hole; later observation merges exact adjacent intervals", async () => {
  const { db, plane } = await setup(), hole = await prepared(db, plane, command("x", true));
  const later = await committed(db, plane, command("x", false));
  await finish(db, plane.observe(later.result.receipt));
  assert.deepEqual(context(db).retired, [[2, 2]]);
  assert.equal((await finish(db, plane.resolve(hole))).kind, "prepared");
  const result = await finish(db, plane.apply(hole)); await finish(db, plane.observe(result.receipt));
  assert.deepEqual(context(db).retired, [[1, 2]]);
});

test("epoch retirement preserves rejected proposal and observation never deletes it", async () => {
  const { db, plane, set } = await setup(), h = await prepared(db, plane);
  set(admission(A, 2, "session-A-next"));
  assert.equal((await finish(db, plane.advanceEpoch())).kind, "epoch-advanced");
  const result = await finish(db, plane.apply(h));
  assert.equal(result.kind, "rejected"); assert.equal(db.rows("records").length, 0);
  assert.equal((await finish(db, plane.observe(result.receipt))).kind, "observed");
  assert.equal(db.rows("attempts").length, 1); assert.equal(data(db.rows("attempts")[0]).state, "rejected");
});

test("Library rejects outbox intent; sealed fixture insertion is atomic and blocks retirement", async () => {
  const { db, plane } = await setup();
  const raw = command("x", true, "movie", {}, { version: 1, kind: "inert-fixture", marker: "never-send" });
  assert.equal(plane.admit(raw).reason, "library-outbox-forbidden");
  const accepted = plane.fixtureAdmit(raw); assert.equal(accepted.kind, "admitted");
  await finish(db, plane.prepare(accepted.handle));
  const before = db.dump(); db.mode("abort-after-requests");
  assert.equal((await finish(db, plane.apply(accepted.handle))).kind, "unavailable"); assert.equal(db.dump(), before);
  const result = await finish(db, plane.apply(accepted.handle)); assert.equal(result.kind, "committed");
  assert.equal(db.rows("outbox").length, 1);
  assert.equal((await finish(db, plane.observe(result.receipt))).kind, "observed");
  assert.equal(db.rows("attempts").length, 1);
  const reload = realm(db, admission(), 100); assert.equal((await finish(db, reload.plane.audit())).kind, "open");
});

test("shared 2 MiB pending reservation binds at 12 ordinary prepares; refusal does not prevent resolution", async () => {
  const { db, plane } = await setup(), handles = [];
  for (let i = 0; i < 12; i++) handles.push(await prepared(db, plane, command("x" + i)));
  assert.equal(global(db).pendingBytes, L.metadataBytes + 12 * L.attemptBytes);
  const before = db.dump(), h = admitted(plane, command("overflow"));
  const result = await finish(db, plane.prepare(h)); assert.equal(result.kind, "prepare-aborted");
  assert.equal(result.reason, "capacity"); assert.equal(db.dump(), before);
  assert.equal((await finish(db, plane.resolve(handles[0]))).kind, "prepared");
  const saved = await finish(db, plane.apply(handles[0])); await finish(db, plane.observe(saved.receipt));
  assert.equal((await finish(db, plane.discover())).items.length, 11);
});

test("realm captures at most 32 unprepared handles; close releases their queue ownership", async () => {
  const { db, plane } = await setup();
  const handles = Array.from({ length: 32 }, (_, i) => admitted(plane, command(String(i))));
  assert.equal(plane.admit(command("33")).reason, "admission-capacity");
  plane.close();
  assert.equal((await plane.prepare(handles[0])).kind, "prepare-aborted");
  assert.equal(db.rows("attempts").length, 0);
});

test("canonical command byte boundary is exact UTF-16; next representable +2 bytes is rejected", async () => {
  const { plane } = await setup();
  const base = JSON.parse(command("x", true, "movie", { pad: "" }));
  const count = (L.commandBytes - bytes(canonical(base))) / 2;
  assert.ok(Number.isInteger(count) && count > 0);
  base.seed.pad = "x".repeat(count);
  const at = canonical(base); assert.equal(bytes(at), L.commandBytes);
  assert.equal(plane.admit(at).kind, "admitted");
  base.seed.pad += "x"; assert.equal(bytes(canonical(base)), L.commandBytes + 2);
  assert.equal(plane.admit(canonical(base)).reason, "text-limit");
});

test("noncanonical, future, excessive-depth and malformed commands are rejected before durable work", async () => {
  const { db, plane } = await setup(), before = db.dump();
  assert.equal(plane.admit(" " + command()).reason, "noncanonical-json");
  const future = JSON.parse(command()); future.version = 2;
  assert.equal(plane.admit(canonical(future)).reason, "unsupported-command");
  const deep = JSON.parse(command()); let nested = 0; for (let i = 0; i < 33; i++) nested = [nested];
  deep.seed.future = nested;
  assert.equal(plane.admit(canonical(deep)).reason, "json-work-limit");
  assert.equal(plane.admit('{"x":1,"x":2}').reason, "noncanonical-json");
  assert.equal(db.dump(), before);
});

test("reads/discovery never mutate; allocated missing row, future envelope and unavailable port fail closed", async () => {
  const { db, plane } = await setup(), h = await prepared(db, plane), before = db.dump();
  await finish(db, plane.snapshot()); await finish(db, plane.discover()); await finish(db, plane.resolve(h));
  assert.equal(db.dump(), before);
  db.tables.get("attempts").clear();
  assert.equal((await finish(db, plane.resolve(h))).reason, "missing-allocated-attempt");
  assert.equal((await finish(db, plane.discover())).reason, "not-open");
  assert.equal(plane.admit(command("new")).reason, "not-open");
  const holes = realm(db); assert.equal((await finish(db, holes.plane.audit())).reason, "allocation-hole");
  const row = db.rows("meta")[0], next = data(row); next.version = 99;
  db.tables.get("meta").set(canonical(row.key), packed(row, next));
  const fresh = realm(db); assert.equal((await finish(db, fresh.plane.audit())).reason, "unknown-version");
  fresh.plane.close(); assert.equal((await fresh.plane.discover()).kind, "unavailable");
});

test("observed technical receipts do not impose M1's 128-chain cap on one retained user record", async () => {
  const { db, plane } = await setup();
  for (let i = 0; i < 130; i++) {
    const { result } = await committed(db, plane, command("same", i % 2 === 0));
    assert.equal((await finish(db, plane.observe(result.receipt))).kind, "details-retired");
  }
  assert.equal(db.rows("records").length, 1); assert.equal(db.rows("attempts").length, 0);
  assert.deepEqual(context(db).retired, [[1, 130]]);
  assert.equal(global(db).pendingBytes, L.metadataBytes);
  // Synthetic correctness schedule only: no browser capacity, performance or GC claim.
});

test("live nonce collision refuses allocation even for identical payload; same handle remains aborted", async () => {
  const { db, plane } = await setup(); await prepared(db, plane);
  const sameNonce = realm(db); await finish(db, sameNonce.plane.audit());
  const h = admitted(sameNonce.plane), before = db.dump();
  const result = await finish(db, sameNonce.plane.prepare(h));
  assert.equal(result.reason, "nonce-collision"); assert.equal(db.dump(), before);
  assert.strictEqual(await sameNonce.plane.prepare(h), result);
  assert.equal(context(db).allocated, 1);
});

test("exact payload mismatch fails closed without replay or retirement", async () => {
  const { db, plane } = await setup(), h = await prepared(db, plane);
  const row = db.rows("attempts")[0], altered = data(row); altered.command.desired = false;
  db.tables.get("attempts").set(canonical(row.key), packed(row, altered));
  const before = db.dump();
  assert.equal((await finish(db, plane.apply(h))).reason, "attempt-identity");
  assert.equal(db.dump(), before); assert.equal(plane.admit(command("fresh")).reason, "not-open");
});

test("queued timeout does not steal a held transaction or erase an admitted command", async () => {
  const { db, plane, clock } = await setup(), h = admitted(plane);
  const held = plane.snapshot(), queued = plane.prepare(h), before = db.dump();
  assert.equal(db.pending.length, 1); db.markEntered(); clock.expire();
  const refused = await queued; assert.equal(refused.kind, "prepare-aborted");
  assert.equal(refused.reason, "entry-timeout"); assert.equal(db.pending.length, 1);
  assert.equal(db.dump(), before); assert.equal((await finish(db, held)).kind, "snapshot");
  assert.strictEqual(await plane.prepare(h), refused); assert.equal(context(db).allocated, 0);
});

test("exactly 32 active/queued read operations; the next fails without a native transaction", async () => {
  const { db, plane } = await setup(), before = db.dump();
  const reads = Array.from({ length: L.queued }, () => plane.snapshot());
  assert.equal((await plane.snapshot()).reason, "queue-limit");
  assert.equal(db.pending.length, 1); db.flush();
  for (const result of await Promise.all(reads)) assert.equal(result.kind, "snapshot");
  assert.equal(db.dump(), before);
});

test("32 retained terminal rows count even without pending proposals; row 33 refuses atomically", async () => {
  const { db, plane } = await setup();
  for (let i = 0; i < L.attempts; i++) await committed(db, plane, command("same"));
  assert.equal(global(db).attempts, L.attempts); assert.equal(context(db).revision, 1);
  const before = db.dump(), h = admitted(plane, command("same"));
  assert.equal((await finish(db, plane.prepare(h))).reason, "capacity");
  assert.equal(db.dump(), before); assert.equal(context(db).allocated, L.attempts);
  assert.equal((await finish(db, plane.discover())).items.length, L.attempts);
});

test("context 32 fits reserved metadata accounting; context 33 does not replace any owner", async () => {
  const { db, plane, set } = await setup();
  for (let i = 1; i < L.contexts; i++) {
    set(admission(["account", "owner-" + i, null, null], 1, "g" + i));
    assert.equal((await finish(db, plane.createContext())).kind, "context-created");
  }
  assert.equal(global(db).contexts, L.contexts);
  assert.equal(global(db).liveBytes, L.contexts * L.metadataBytes);
  const before = db.dump(); set(admission(["account", "overflow", null, null]));
  assert.equal((await finish(db, plane.createContext())).reason, "capacity"); assert.equal(db.dump(), before);
});

test("fixture reservations bind at seven while ordinary Library remains outbox-free", async () => {
  const { db, plane } = await setup();
  for (let i = 0; i < 7; i++) {
    const result = plane.fixtureAdmit(command(String(i), true, "movie", {}, { version: 1, kind: "inert-fixture", marker: "inert" }));
    assert.equal((await finish(db, plane.prepare(result.handle))).kind, "prepared");
  }
  assert.equal(global(db).pendingBytes, L.metadataBytes + 7 * (L.attemptBytes + L.outboxBytes));
  const before = db.dump(), eighth = plane.fixtureAdmit(command("8", true, "movie", {}, { version: 1, kind: "inert-fixture", marker: "inert" }));
  assert.equal((await finish(db, plane.prepare(eighth.handle))).reason, "capacity");
  assert.equal(db.dump(), before); assert.equal(db.rows("outbox").length, 0);
});

test("fixture no-op releases its outbox reservation without creating an outbox row", async () => {
  const { db, plane } = await setup(); await committed(db, plane);
  const h = plane.fixtureAdmit(command("x", true, "movie", {}, { version: 1, kind: "inert-fixture", marker: "inert" })).handle;
  await finish(db, plane.prepare(h));
  const result = await finish(db, plane.apply(h));
  assert.equal(result.kind, "unchanged"); assert.equal(result.revision, 1);
  assert.equal(db.rows("outbox").length, 0); assert.equal(global(db).reservedOutbox, 0);
});

test("safe sequence exhaustion never wraps or erases its retired interval", async () => {
  const { db, plane } = await setup(), row = db.rows("contexts")[0], value = data(row);
  value.allocated = L.safeInteger; value.retired = [[1, L.safeInteger]];
  db.tables.get("contexts").set(canonical(row.key), packed(row, value));
  const fresh = realm(db, admission(), 100); assert.equal((await finish(db, fresh.plane.audit())).kind, "open");
  const before = db.dump(), h = admitted(fresh.plane);
  assert.equal((await finish(db, fresh.plane.prepare(h))).reason, "integer-exhausted");
  assert.equal(db.dump(), before); assert.equal(db.rows("attempts").length, 0);
  // Old plane is deliberately unused after this synthetic fixture injection.
  plane.close();
});

test("safe revision exhaustion preserves prepared work; an absent remove cannot become an implicit no-op", async () => {
  const { db } = await setup(), row = db.rows("contexts")[0], value = data(row);
  value.revision = L.safeInteger; db.tables.get("contexts").set(canonical(row.key), packed(row, value));
  const fresh = realm(db, admission(), 100); await finish(db, fresh.plane.audit());
  const h = await prepared(db, fresh.plane, command("absent", false)), before = db.dump();
  assert.equal((await finish(db, fresh.plane.apply(h))).reason, "integer-exhausted");
  assert.equal(db.dump(), before); assert.equal((await finish(db, fresh.plane.resolve(h))).kind, "prepared");
});

test("identifier cap is exact and closed JSON node count rejects the first extra node", async () => {
  const { plane } = await setup();
  assert.equal(plane.admit(command("x".repeat(L.identifierUnits))).kind, "admitted");
  assert.equal(plane.admit(command("x".repeat(L.identifierUnits + 1))).reason, "title-identity-limit");
  const value = JSON.parse(command("nodes", true, "movie", { values: [] }));
  const nodes = v => v && typeof v === "object" ? 1 + Object.values(v).reduce((n, child) => n + nodes(child), 0) : 1;
  value.seed.values = Array(L.nodes - nodes(value)).fill(0);
  assert.equal(nodes(value), L.nodes); assert.equal(plane.admit(canonical(value)).kind, "admitted");
  value.seed.values.push(0); assert.equal(nodes(value), L.nodes + 1);
  assert.equal(plane.admit(canonical(value)).reason, "json-work-limit");
});

test("two consumers share global reservation capacity across distinct contexts", async () => {
  const { db, plane } = await setup(), other = realm(db, admission(B, 1, "B"), 100);
  await finish(db, other.plane.audit()); await finish(db, other.plane.createContext());
  for (let i = 0; i < 6; i++) {
    await prepared(db, plane, command("A-" + i));
    await prepared(db, other.plane, command("B-" + i));
  }
  assert.equal(global(db).attempts, 12);
  const before = db.dump(), h = admitted(other.plane, command("B-overflow"));
  assert.equal((await finish(db, other.plane.prepare(h))).reason, "capacity"); assert.equal(db.dump(), before);
  assert.equal((await finish(db, plane.discover())).items.length, 6);
  assert.equal((await finish(db, other.plane.discover())).items.length, 6);
});

test("pre-entry owner retirement refuses the operation without attributing it to the replacement owner", async () => {
  const { db, plane, set } = await setup(), h = admitted(plane), before = db.dump();
  const held = plane.snapshot(), queued = plane.prepare(h);
  db.grant(); await held; set(admission(B, 1, "B")); db.grant();
  const result = await queued; assert.equal(result.kind, "prepare-aborted");
  assert.equal(db.dump(), before); assert.strictEqual(await plane.prepare(h), result);
});

test("audit rejects an orphan cursor entry instead of returning an empty discovery snapshot", async () => {
  const { db } = await setup();
  const row = db.rows("contexts")[0], orphan = data(row); orphan.identity = B;
  // A mismatching schema/index tuple is corruption, not an invitation to normalize it.
  db.tables.get("contexts").set(canonical(row.key), packed(row, orphan));
  const fresh = realm(db); assert.equal((await finish(db, fresh.plane.audit())).reason, "context-index");
  assert.equal((await fresh.plane.discover()).kind, "unavailable");
});

test("serialized callback handoffs never access an expired native row lease", async () => {
  const { db, plane } = await setup(); db.expireRowLeases = true;
  const first = await committed(db, plane, command("x", true, "movie", { history: [{ unknown: [1, null, "keep"] }] }));
  assert.equal((await finish(db, plane.observe(first.result.receipt))).kind, "details-retired");
  const second = await committed(db, plane, command("x", false));
  assert.equal((await finish(db, plane.observe(second.result.receipt))).kind, "details-retired");
  assert.equal((await finish(db, plane.snapshot())).kind, "snapshot");
  assert.equal((await finish(db, plane.discover())).items.length, 0);
  const fresh = realm(db, admission(), 100);
  assert.equal((await finish(db, fresh.plane.audit())).kind, "open");
  // A native-row access-lifetime regression only, NOT parsed-object GC, heap or RSS measurement.
});

test("2 MiB realm capture binds before 32 full-size command handles", async () => {
  const { db, plane } = await setup(), value = JSON.parse(command("large", true, "movie", { pad: "" }));
  value.seed.pad = "x".repeat((L.commandBytes - bytes(canonical(value))) / 2);
  const raw = canonical(value); assert.equal(bytes(raw), L.commandBytes);
  for (let i = 0; i < 15; i++) assert.equal(plane.admit(raw).kind, "admitted");
  assert.equal(plane.admit(raw).reason, "admission-capacity");
  assert.equal(db.rows("attempts").length, 0); assert.equal(context(db).allocated, 0);
});

test("same-epoch generation retirement preserves the proposal without applying it", async () => {
  const { db, plane, set } = await setup(), h = await prepared(db, plane);
  set(admission(A, 1, "new-surface-generation"));
  const result = await finish(db, plane.apply(h));
  assert.equal(result.kind, "rejected"); assert.equal(db.rows("records").length, 0);
  assert.equal((await finish(db, plane.observe(result.receipt))).kind, "observed");
  assert.equal(db.rows("attempts").length, 1); assert.equal(context(db).revision, 0);
});

test("oversized native value is refused after its one unavoidable clone, never clipped", async () => {
  const { db, plane } = await setup(); await committed(db, plane);
  const row = db.rows("records")[0];
  row.text = "x".repeat(L.recordBytes / 2 + 1); row.bytes = L.recordBytes + 2;
  db.tables.get("records").set(canonical(row.key), row);
  const before = db.dump(), fresh = realm(db);
  assert.equal((await finish(db, fresh.plane.audit())).reason, "row-limit");
  assert.equal(fresh.plane.admit(command("next")).reason, "not-open");
  assert.equal(db.dump(), before);
});


test("G2 same-owner/binding/epoch recovery discovers G1 proposal then explicitly applies its SAME operation", async () => {
  const { db, plane } = await setup(), original = await prepared(db, plane, command("recover", true, "movie", { history: ["keep"] }));
  const stored = data(db.rows("attempts")[0]), savedCommand = canonical(stored.command), allocated = context(db).allocated;
  const fresh = realm(db, admission(A, 1, "G2-recovery"), 100);
  assert.equal((await finish(db, fresh.plane.audit())).kind, "open");
  const before = db.dump(), writes = db.attemptedWrites;
  const found = await finish(db, fresh.plane.discover());
  assert.equal(found.kind, "discovered"); assert.equal(found.items.length, 1);
  assert.equal(found.items[0].state, "prepared"); assert.notStrictEqual(found.items[0].handle, original);
  assert.equal(db.dump(), before); assert.equal(db.attemptedWrites, writes);
  assert.equal(db.rows("records").length, 0); assert.equal(context(db).allocated, allocated);
  // A separate explicit recovery-consumer decision: discovery did not run this step.
  const result = await finish(db, fresh.plane.apply(found.items[0].handle));
  assert.equal(result.kind, "committed"); assert.equal(result.revision, 1);
  const terminal = data(db.rows("attempts")[0]);
  assert.equal(terminal.sequence, stored.sequence); assert.equal(terminal.nonce, stored.nonce);
  assert.equal(terminal.epoch, stored.epoch); assert.equal(canonical(terminal.command), savedCommand);
  assert.equal(context(db).allocated, allocated); assert.equal(db.rows("records").length, 1);
});

test("renewed recovery admission cannot execute an old-epoch proposal; rejection preserves exact command", async () => {
  const { db, plane, set } = await setup();
  await prepared(db, plane, command("old-epoch", true, "movie", { history: [{ neverDiscard: true }] }));
  const original = data(db.rows("attempts")[0]), savedCommand = canonical(original.command);
  set(admission(A, 2, "G2-security-retirement"));
  assert.equal((await finish(db, plane.advanceEpoch())).kind, "epoch-advanced");
  const fresh = realm(db, admission(A, 2, "G2-recovery"), 100);
  assert.equal((await finish(db, fresh.plane.audit())).kind, "open");
  const before = db.dump(), writes = db.attemptedWrites;
  const found = await finish(db, fresh.plane.discover());
  assert.equal(found.items.length, 1); assert.equal(found.items[0].state, "prepared");
  assert.equal(db.dump(), before); assert.equal(db.attemptedWrites, writes);
  const result = await finish(db, fresh.plane.apply(found.items[0].handle));
  assert.equal(result.kind, "rejected"); assert.equal(result.reason, "epoch-retired");
  const kept = data(db.rows("attempts")[0]);
  assert.equal(kept.sequence, original.sequence); assert.equal(kept.nonce, original.nonce);
  assert.equal(kept.epoch, 1); assert.equal(canonical(kept.command), savedCommand);
  assert.equal(context(db).epoch, 2); assert.equal(context(db).allocated, 1); assert.equal(context(db).revision, 0);
  assert.equal(db.rows("records").length, 0); assert.equal(db.rows("outbox").length, 0);
  assert.equal((await finish(db, fresh.plane.observe(result.receipt))).kind, "observed");
  assert.equal(db.rows("attempts").length, 1); assert.equal(canonical(data(db.rows("attempts")[0]).command), savedCommand);
});


// Boundary matrix B01–B14. These are SAVED fixtures, not executed preparation evidence.
// Corpus helpers serialize envelopes/counters only. Every audit/read/admit/mutation below
// invokes the imported production module; no operation, receipt or retirement model lives here.
const ck = id => [id[0], ...id.slice(1).map(x => x === null ? [0] : [1, x])];
const rk = (id, name = "x", type = "movie") => [ck(id), "library", type, name];
const envelope = (key, ctx, value, nonceKey = [], sourceKey = []) =>
  packed({ key, context: ctx, nonceKey, sourceKey, text: "", bytes: 0 }, value);
const contextRow = (id = A, overrides = {}) => envelope(ck(id), ck(id), {
  version: 1, kind: "context", identity: id, epoch: 1, revision: 1, allocated: 0, retired: [], ...overrides,
});
const recordRow = (name = "x", pad = "", id = A) => envelope(rk(id, name), ck(id), {
  version: 1, kind: "library", identity: id, title: ["movie", name], membership: true,
  membershipRevision: 1, entry: { type: "movie", id: name, pad },
});
const attemptRow = (sequence = 1, overrides = {}, id = A) => {
  const value = { version: 1, kind: "attempt", identity: id, epoch: 1, sequence,
    nonce: sequence.toString(16).padStart(64, "0"), command: JSON.parse(command()),
    state: "rejected", result: { state: "rejected", revision: 0, reason: "epoch-retired" },
    observed: false, ...overrides };
  return envelope([ck(id), sequence], ck(id), value, [ck(id), value.nonce]);
};
const outboxRow = source => {
  const a = data(source), key = ck(a.identity);
  return envelope([key, a.sequence, "fixture"], key, {
    version: 1, kind: "inert-outbox", identity: a.identity, sequence: a.sequence,
    nonce: a.nonce, intent: a.command.fixture, state: "inert",
  }, [], [key, a.sequence]);
};
function fit(make, measure, target, atom = "x", maximum = target) {
  let low = 0, high = maximum;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (measure(make(atom.repeat(middle))) <= target) low = middle; else high = middle - 1;
  }
  let pad = atom.repeat(low), value = make(pad);
  // ASCII tail handles the next representable +2-byte step after escaped content.
  while (measure(value) < target) { pad += "x"; value = make(pad); }
  assert.equal(measure(value), target, "fixture target must be exact, never rounded");
  return { value, pad };
}
function fullContext(atom) {
  // Three stored identity occurrences have different escaping; epoch/revision digits
  // provide a one-unit framing adjustment without adding an unknown metadata field.
  for (let digits = 0; digits < 16; digits++) {
    const revision = 10 ** digits;
    let low = 0, high = L.identifierUnits;
    const make = pad => contextRow(["account", pad, null, null], { revision });
    while (low < high) {
      const mid = Math.ceil((low + high) / 2);
      if (make(atom.repeat(mid)).bytes <= L.metadataBytes) low = mid; else high = mid - 1;
    }
    for (let trim = 0; trim <= Math.min(low, 8); trim++) for (let tail = 0; tail < 20; tail++) {
      const pad = atom.repeat(low - trim) + "x".repeat(tail);
      if (pad.length <= L.identifierUnits && make(pad).bytes === L.metadataBytes) return { value: make(pad), pad };
    }
  }
  assert.fail("no exact context-envelope fixture found");
}
function corpus({ contexts = [contextRow()], records = [], attempts = [], outbox = [], recovery = [] } = {}) {
  const db = new Database(), initial = db.rows("meta")[0], m = data(initial);
  for (const [store, rows] of Object.entries({ contexts, records, attempts, outbox, recovery })) {
    db.tables.set(store, new Map(rows.map(row => [canonical(row.key), clone(row)])));
  }
  const preparedRows = attempts.filter(row => data(row).state === "prepared");
  const reservedOutbox = preparedRows.filter(row => data(row).command.fixture !== null).length;
  Object.assign(m, {
    contexts: contexts.length, records: records.length, attempts: attempts.length, outbox: outbox.length,
    recovery: recovery.length, reservedRecords: preparedRows.length, reservedOutbox,
    liveBytes: contexts.length * L.metadataBytes + records.reduce((n, row) => n + row.bytes, 0)
      + preparedRows.length * L.recordBytes,
    pendingBytes: L.metadataBytes + attempts.reduce((n, row) => n + (data(row).state === "prepared"
      ? L.attemptBytes + (data(row).command.fixture === null ? 0 : L.outboxBytes) : row.bytes), 0)
      + outbox.reduce((n, row) => n + row.bytes, 0),
    recoveryBytes: recovery.reduce((n, row) => n + row.bytes, 0),
  });
  db.tables.get("meta").set(canonical(initial.key), packed(initial, m));
  return db;
}
function recordTotal(total, count = Math.ceil(total / L.recordBytes), id = A) {
  assert.ok(count > 0 && total % 2 === 0);
  let remaining = total;
  return Array.from({ length: count }, (_, i) => {
    const target = i === count - 1 ? remaining : Math.floor(total / count / 2) * 2;
    const row = fit(pad => recordRow("r" + i, pad, id), row => row.bytes, target).value;
    assert.ok(row.bytes <= L.recordBytes); remaining -= row.bytes; return row;
  });
}
function trackReads(db, transform = (_store, row) => row) {
  const stats = { gets: [], keys: [] }, original = db.port.bind(db);
  db.port = identity => {
    const port = original(identity);
    return { ...port, run: (mode, scope, body, events) => port.run(mode, scope, tx => body({
      ...tx,
      get: (store, key, receive) => tx.get(store, key, row => {
        stats.gets.push(store); receive(transform(store, row));
      }),
      keys: (store, index, match, receive, end) => tx.keys(store, index, match, (key, next) => {
        stats.keys.push(store); receive(key, next);
      }, end),
    }), events) };
  };
  return stats;
}
async function opened(db, raw = admission()) {
  const r = realm(db, raw, 1000);
  assert.equal((await finish(db, r.plane.audit())).kind, "open");
  return r;
}
async function readOnly(db, operation) {
  const before = db.dump(), writes = db.attemptedWrites;
  const value = await finish(db, operation());
  assert.equal(db.dump(), before); assert.equal(db.attemptedWrites, writes);
  return value;
}
const captureEvidence = (raw, id, epoch, nonce, databaseId = "0".repeat(64)) =>
  bytes(canonical({ admission: raw, context: id, key: ck(id), epoch, nonce,
    databaseId, sequence: L.safeInteger }));

test("B01 — identifier/context/composite/admission framing and nonce ingress use literal units", async () => {
  const { plane, set, db } = await setup(), before = db.dump();
  for (const field of [1, 2, 3]) {
    const id = [...A]; id[field] = "x".repeat(L.identifierUnits); set(admission(id));
    assert.equal(plane.admit(command()).kind, "admitted");
    id[field] += "x"; set(admission(id)); assert.equal(plane.admit(command()).reason, "identifier-limit");
  }
  const keyed = fit(pad => ["account", '"'.repeat(1024), "p".repeat(1000), pad],
    id => canonical(rk(id)).length, L.keyUnits, "x", 1024).value;
  set(admission(keyed)); assert.equal(plane.admit(command()).kind, "admitted");
  const tooKeyed = [...keyed]; tooKeyed[3] += "x"; set(admission(tooKeyed));
  assert.equal(plane.admit(command()).reason, "key-limit");
  const atContext = fit(pad => ["account", '"'.repeat(1024), "p".repeat(1024), pad],
    id => canonical(id).length, L.contextUnits, "x", 1024).value;
  set(admission(atContext)); assert.equal(plane.admit(command()).reason, "key-limit");
  atContext[3] += "x"; set(admission(atContext)); assert.equal(plane.admit(command()).reason, "context-limit");
  const framed = fit(pad => admission(["account", pad, "p".repeat(1000), null], 1, "\u0000".repeat(1024)),
    bytes, L.metadataBytes, "x", 1024);
  set(framed.value); assert.equal(plane.admit(command()).kind, "admitted");
  const oneMore = JSON.parse(framed.value); oneMore.context[1] += "x";
  set(canonical(oneMore)); assert.equal(plane.admit(command()).reason, "text-limit");
  for (const generation of ["", "x".repeat(1025)]) {
    set(admission(A, 1, generation)); assert.equal(plane.admit(command()).reason, "generation-limit");
  }
  for (const nonce of ["f".repeat(63), "f".repeat(65), "F".repeat(64), "g".repeat(64)]) {
    const p = fixtures.create(db.port(), { currentAdmission: () => admission() }, () => nonce, new Clock());
    await finish(db, p.audit()); assert.equal(p.admit(command()).reason, "randomness-unavailable"); p.close();
  }
  assert.equal(db.dump(), before); assert.equal(db.attemptedWrites, 2); // setup context only
});

test("B02 — exact depth/node admission is distinct from stricter full-envelope PREPARE", async () => {
  for (const shape of ["depth", "nodes"]) {
    const { db, plane } = await setup(), value = JSON.parse(command("shape", true, "movie", { extension: null }));
    if (shape === "depth") { let nested = 0; for (let i = 0; i < 30; i++) nested = [nested]; value.seed.extension = nested; }
    else {
      const count = v => v && typeof v === "object" ? 1 + Object.values(v).reduce((n, child) => n + count(child), 0) : 1;
      value.seed.extension = []; value.seed.extension = Array(L.nodes - count(value)).fill(0);
      assert.equal(count(value), L.nodes);
    }
    const h = admitted(plane, canonical(value)), before = db.dump();
    assert.equal((await finish(db, plane.prepare(h))).reason, "json-work-limit");
    assert.equal(db.dump(), before);
    if (shape === "depth") value.seed.extension = [value.seed.extension]; else value.seed.extension.push(0);
    assert.equal(plane.admit(canonical(value)).reason, "json-work-limit");
  }
  const { plane, db } = await setup(), before = db.dump();
  for (const raw of [null, {}, [], 1, "null", "[]", '{"x":1e400}', '{"x":-0}', '{"x":1,"x":2}']) {
    assert.equal(plane.admit(raw).kind, "unavailable");
  }
  assert.equal(db.dump(), before);
});

test("B03 — exact full context metadata envelope and first +2 bytes; global schema cannot be padded", async () => {
  const made = fullContext('"');
  assert.ok(data(made.value).identity[1].length <= L.identifierUnits);
  const db = corpus({ contexts: [made.value] }), id = data(made.value).identity;
  const r = await opened(db, admission(id));
  assert.equal((await readOnly(db, () => r.plane.discover())).kind, "discovered");
  const overflow = packed(made.value, { ...data(made.value), allocated: 10 });
  assert.equal(overflow.bytes, L.metadataBytes + 2); // one extra serialized integer digit, before partition validation
  const bad = corpus({ contexts: [overflow] }), fresh = realm(bad, admission(data(overflow).identity));
  assert.equal((await readOnly(bad, () => fresh.plane.audit())).reason, "row-limit");
  const initial = fixtures.initialRow(), padded = data(initial); padded.extra = "x".repeat(20);
  const unknown = new Database(); unknown.tables.get("meta").set(canonical(initial.key), packed(initial, padded));
  assert.equal((await readOnly(unknown, () => realm(unknown).plane.audit())).reason, "unknown-fields");
});

test("B04 — 64 KiB record includes index/text framing; readers and later writes preserve a refused full row", async () => {
  for (const delta of [0, 2]) {
    const row = fit(pad => recordRow("full", pad), r => r.bytes, L.recordBytes + delta).value;
    const db = corpus({ records: [row] }), r = realm(db);
    const audit = await readOnly(db, () => r.plane.audit());
    if (delta) { assert.equal(audit.reason, "row-limit"); continue; }
    assert.equal(audit.kind, "open"); assert.equal((await readOnly(db, () => r.plane.snapshot())).kind, "snapshot");
    const h = await prepared(db, r.plane, command("full", false)), before = db.dump();
    // true -> false adds two serialized bytes; no clipping or deletion to create headroom.
    assert.equal((await finish(db, r.plane.apply(h))).reason, "row-limit");
    assert.equal(db.dump(), before); assert.equal((await finish(db, r.plane.resolve(h))).kind, "prepared");
  }
  const { db, plane } = await setup(), value = JSON.parse(command("future", true, "movie", { pad: "" }));
  value.seed.pad = "x".repeat(L.recordBytes / 2); const h = admitted(plane, canonical(value)), before = db.dump();
  assert.equal((await finish(db, plane.prepare(h))).reason, "future-record-limit"); assert.equal(db.dump(), before);
});

test("B05 — complete attempt and terminal-result bytes cover durable readers, not only command ingress", async () => {
  for (const target of ["attempt", "result"]) for (const delta of [0, 2]) {
    const desired = (target === "attempt" ? L.attemptBytes : L.resultBytes) + delta;
    let row;
    if (target === "attempt") {
      row = fit(pad => attemptRow(1, { command: JSON.parse(command("wide", true, "movie", { pad })) }),
        value => value.bytes, desired, '"').value;
      assert.ok(bytes(canonical(data(row).command)) <= L.commandBytes);
    } else {
      const result = fit(pad => ({ state: "rejected", revision: 0, reason: pad }), value => bytes(canonical(value)), desired).value;
      row = attemptRow(1, { result });
    }
    const db = corpus({ contexts: [contextRow(A, { allocated: 1 })], attempts: [row] }), r = realm(db);
    const check = await readOnly(db, () => r.plane.audit());
    if (delta) { assert.equal(check.reason, target === "attempt" ? "row-limit" : "result-limit"); continue; }
    assert.equal(check.kind, "open");
    const discovered = await readOnly(db, () => r.plane.discover());
    assert.equal(discovered.kind, "discovered"); assert.equal(discovered.items[0].outcome.kind, "rejected");
    assert.equal((await readOnly(db, () => r.plane.resolve(discovered.items[0].handle))).kind, "rejected");
  }
  // Synthetic validator corpus, not a claim that a 160 KiB seed passes future-record PREPARE.
});

test("B06 — fixture outbox framing reaches 128 KiB; 32 dependency-held sources remain charged", async () => {
  for (const delta of [0, 2]) {
    const make = pad => attemptRow(1, { state: "committed", result: { state: "committed", revision: 1, reason: null },
      command: JSON.parse(command("x", true, "movie", {}, { version: 1, kind: "inert-fixture", marker: pad })) });
    const source = fit(make, row => outboxRow(row).bytes, L.outboxBytes + delta).value, event = outboxRow(source);
    assert.ok(source.bytes <= L.attemptBytes && bytes(canonical(data(source).command)) <= L.commandBytes);
    const db = corpus({ contexts: [contextRow(A, { allocated: 1 })], records: [recordRow()], attempts: [source], outbox: [event] });
    const r = realm(db), result = await readOnly(db, () => r.plane.audit());
    assert.equal(delta ? result.reason : result.kind, delta ? "row-limit" : "open");
  }
  const attempts = Array.from({ length: 32 }, (_, i) => attemptRow(i + 1, {
    state: "committed", observed: true, result: { state: "committed", revision: 1, reason: null },
    command: JSON.parse(command("x", true, "movie", {}, { version: 1, kind: "inert-fixture", marker: "hold" })),
  }));
  const db = corpus({ contexts: [contextRow(A, { allocated: 32 })], records: [recordRow()], attempts, outbox: attempts.map(outboxRow) });
  const r = await opened(db), before = db.dump(), h = admitted(r.plane, command("new"));
  assert.equal((await finish(db, r.plane.prepare(h))).reason, "capacity"); assert.equal(db.dump(), before);
  assert.equal((await readOnly(db, () => r.plane.discover())).items.length, 32);
  assert.equal(global(db).pendingBytes, L.metadataBytes + [...attempts, ...attempts.map(outboxRow)].reduce((n, row) => n + row.bytes, 0));
});

test("B07 — 4096 record values and 32 attempt values; overflow sentinel is never fetched as a value", async () => {
  for (const store of ["records", "attempts"]) {
    const maximum = store === "records" ? L.records : L.attempts;
    const rows = Array.from({ length: maximum }, (_, i) => store === "records" ? recordRow("r" + i) : attemptRow(i + 1));
    const db = corpus({ contexts: [contextRow(A, { allocated: store === "attempts" ? maximum : 0 })], [store]: rows });
    const stats = trackReads(db), r = await opened(db);
    const read = () => store === "records" ? r.plane.snapshot() : r.plane.discover();
    assert.equal((await readOnly(db, read)).kind, store === "records" ? "snapshot" : "discovered");
    const extra = store === "records" ? recordRow("overflow") : attemptRow(maximum + 1);
    db.tables.get(store).set(canonical(extra.key), extra); stats.gets.length = 0; stats.keys.length = 0;
    assert.equal((await readOnly(db, read)).reason, "cursor-limit");
    assert.equal(stats.gets.filter(x => x === store).length, maximum);
    assert.equal(stats.keys.filter(x => x === store).length, maximum + 1);
    assert.equal((await readOnly(db, () => r.plane.discover())).reason, "not-open");
  }
});

test("B08 — 4 MiB live bytes and record-slot reservations: exact, +2, and rollback", async () => {
  for (const delta of [0, 2]) {
    const db = corpus({ records: recordTotal(L.liveBytes - L.metadataBytes + delta) }), r = realm(db);
    assert.equal(global(db).liveBytes, L.liveBytes + delta);
    const result = await readOnly(db, () => r.plane.audit());
    if (delta) { assert.equal(result.reason, "capacity"); continue; }
    assert.equal(result.kind, "open"); assert.equal((await readOnly(db, () => r.plane.snapshot())).kind, "snapshot");
    const before = db.dump(), h = admitted(r.plane);
    assert.equal((await finish(db, r.plane.prepare(h))).reason, "capacity"); assert.equal(db.dump(), before);
  }
  const db = corpus({ records: recordTotal(L.liveBytes - L.metadataBytes - L.recordBytes) }), r = await opened(db);
  const h = await prepared(db, r.plane, command("reserved")); assert.equal(global(db).liveBytes, L.liveBytes);
  const before = db.dump(); db.mode("abort-after-requests");
  assert.equal((await finish(db, r.plane.apply(h))).kind, "unavailable"); assert.equal(db.dump(), before);
  assert.equal((await finish(db, r.plane.apply(h))).kind, "committed"); assert.ok(global(db).liveBytes < L.liveBytes);
  const slots = corpus({ records: Array.from({ length: 4095 }, (_, i) => recordRow("s" + i)) }), s = await opened(slots);
  const sh = await prepared(slots, s.plane, command("last"));
  assert.equal(global(slots).records + global(slots).reservedRecords, 4096);
  assert.equal((await finish(slots, s.plane.apply(sh))).kind, "committed"); assert.equal(global(slots).records, 4096);
  const saved = slots.dump(), extra = admitted(s.plane, command("last", false));
  assert.equal((await finish(slots, s.plane.prepare(extra))).reason, "capacity"); assert.equal(slots.dump(), saved);
  const full = fullContext('"'), id = data(full.value).identity;
  const wideRecords = recordTotal(L.liveBytes - L.metadataBytes, undefined, id);
  const fullHeader = corpus({ contexts: [full.value], records: wideRecords }), wide = await opened(fullHeader, admission(id));
  const prospective = canonical({ context: id, epoch: 1, records: wideRecords.map(data), revision: data(full.value).revision });
  assert.ok(bytes(prospective) < L.snapshotBytes);
  assert.equal(global(fullHeader).liveBytes, L.liveBytes);
  // CONTRACT assertion: source8ba278 predicts RED (read-work-limit), not an accepted refusal.
  // No execution has occurred. A separately reviewed read-budget correction is required.
  const snapshot = await readOnly(fullHeader, () => wide.plane.snapshot());
  assert.equal(snapshot.kind, "snapshot", snapshot.reason);
  assert.ok(bytes(snapshot.snapshot) <= L.snapshotBytes);
});

test("B09 — exact shared 2 MiB reservation includes rejected proposals, not just active rows", async () => {
  const preparedRows = Array.from({ length: 12 }, (_, i) => attemptRow(i + 1, { state: "prepared", result: null }));
  const make = pad => attemptRow(13, { command: JSON.parse(command("x", true, "movie", {},
    { version: 1, kind: "inert-fixture", marker: pad })) });
  const target = L.pendingBytes - L.metadataBytes - 12 * L.attemptBytes;
  for (const delta of [0, 2]) {
    const rejected = fit(make, row => row.bytes, target + delta).value;
    const db = corpus({ contexts: [contextRow(A, { allocated: 13 })], attempts: [...preparedRows, rejected] }), r = realm(db);
    assert.equal(global(db).pendingBytes, L.pendingBytes + delta);
    const audited = await readOnly(db, () => r.plane.audit());
    if (delta) { assert.equal(audited.reason, "capacity"); continue; }
    assert.equal(audited.kind, "open");
    const found = await readOnly(db, () => r.plane.discover()), h = found.items.find(x => x.sequence === 1).handle;
    const before = db.dump(); db.mode("abort-after-requests");
    assert.equal((await finish(db, r.plane.apply(h))).kind, "unavailable"); assert.equal(db.dump(), before);
    const result = await finish(db, r.plane.apply(h)); assert.equal(result.kind, "committed");
    assert.ok(global(db).pendingBytes < L.pendingBytes); assert.equal(db.rows("attempts").length, 13);
    const proposal = db.rows("attempts").find(row => data(row).sequence === 13).text;
    await finish(db, r.plane.observe(result.receipt));
    assert.equal(db.rows("attempts").find(row => data(row).sequence === 13).text, proposal);
  }
});

test("B10 — 33 retired intervals separated by 32 retained holes; no numeric high-water scan", async () => {
  const spans = Array.from({ length: 33 }, (_, i) => [2 * i + 1, 2 * i + 1]);
  const attempts = Array.from({ length: 32 }, (_, i) => attemptRow(2 * i + 2));
  const db = corpus({ contexts: [contextRow(A, { allocated: 65, retired: spans })], attempts }), r = await opened(db);
  assert.equal((await readOnly(db, () => r.plane.discover())).items.length, 32);
  for (const fault of ["interval+1", "hole", "overlap"]) {
    const ctx = data(db.rows("contexts")[0]);
    if (fault === "interval+1") { ctx.retired = Array.from({ length: 34 }, (_, i) => [i + 1, i + 1]); ctx.allocated = 34; }
    if (fault === "hole") ctx.allocated = 66;
    if (fault === "overlap") ctx.retired[1] = [1, 3];
    const bad = corpus({ contexts: [contextRow(A, ctx)], attempts: fault === "interval+1" ? [] : attempts });
    const result = await readOnly(bad, () => realm(bad).plane.audit());
    assert.equal(result.reason, fault === "interval+1" ? "interval-limit" : fault === "hole" ? "allocation-hole" : "interval-order");
  }
});

test("B11 — last safe epoch/sequence/revision; no-op at max revision does not spend another revision", async () => {
  const db = corpus({ contexts: [contextRow(A, { epoch: L.safeInteger - 1, revision: L.safeInteger,
    allocated: L.safeInteger - 1, retired: [[1, L.safeInteger - 1]] })], records: [recordRow()] });
  const r = await opened(db, admission(A, L.safeInteger - 1));
  r.set(admission(A, L.safeInteger)); assert.equal((await finish(db, r.plane.advanceEpoch())).kind, "epoch-advanced");
  assert.equal((await finish(db, r.plane.advanceEpoch())).kind, "epoch-existing");
  const h = await prepared(db, r.plane); assert.equal(context(db).allocated, L.safeInteger);
  const result = await finish(db, r.plane.apply(h)); assert.equal(result.kind, "unchanged");
  assert.equal(result.revision, L.safeInteger);
  const before = db.dump(), next = admitted(r.plane);
  assert.equal((await finish(db, r.plane.prepare(next))).reason, "integer-exhausted"); assert.equal(db.dump(), before);
  r.set(admission(A, L.safeInteger + 1)); assert.equal(r.plane.admit(command()).reason, "invalid-integer");
});

test("B12 — exact 2 MiB realm evidence and next +2 bytes, independent of 32-handle ceiling", async () => {
  // Fresh admission does NOT read a durable context; discovery's16KiB-context
  // domination proof cannot replace this independent per-handle boundary.
  for (const delta of [0, 2]) {
    const { db, plane, set } = await setup();
    const id = ["account", '"'.repeat(1024), '"'.repeat(993), null];
    const generation = "\u0000".repeat(683), rawAdmission = admission(id, 1, generation);
    assert.equal(canonical(id).length, 4056);
    assert.equal(canonical(ck(id)).length, 4063);
    assert.equal(canonical(rk(id, "x", "movie")).length, 4087);
    assert.equal(rawAdmission.length, 8192);
    assert.ok(id.slice(1).every(value => value === null || value.length <= L.identifierUnits));
    assert.ok(generation.length > 0 && generation.length <= L.identifierUnits);
    assert.ok(canonical(id).length <= L.contextUnits && canonical(rk(id, "x", "movie")).length <= L.keyUnits);
    assert.equal(bytes(rawAdmission), L.metadataBytes);
    const nonce = "0".repeat(63) + "1";
    const overhead = captureEvidence(rawAdmission, id, 1, nonce);
    assert.equal(overhead, 42538);
    assert.ok(overhead > L.attemptBytes - L.commandBytes);
    const raw = fit(pad => command("x", true, "movie", { pad }), bytes, L.attemptBytes - overhead + delta).value;
    assert.equal(bytes(raw), 121302 + delta);
    assert.ok(bytes(raw) <= L.commandBytes);
    assert.equal(bytes(raw) + overhead, L.attemptBytes + delta);
    assert.ok(bytes(raw) + overhead < L.capturedBytes); // Shared budget cannot mask this private bound.
    assert.equal(JSON.parse(raw).id, "x"); assert.equal(JSON.parse(raw).type, "movie");
    // setup has made no admissions; its first nonce is the exact64-hex value above.
    // Only renew the provider: no context adoption, PREPARE or durable allocation.
    set(rawAdmission);
    const before = db.dump(), writes = db.attemptedWrites, result = plane.admit(raw);
    assert.equal(result.kind, delta ? "unavailable" : "admitted");
    if (delta) assert.equal(result.reason, "admission-evidence-limit");
    else assert.equal(result.handle.kind, "operation");
    assert.equal(db.dump(), before); assert.equal(db.attemptedWrites, writes);
    assert.equal(db.rows("contexts").length, 1);
    assert.equal(db.rows("attempts").length, 0); assert.equal(context(db).allocated, 0);
    plane.close();
  }
  for (const delta of [0, 2]) {
    const { db, plane } = await setup(), nonce = "0".repeat(63) + "1";
    const overhead = captureEvidence(admission(), A, 1, nonce);
    const full = fit(pad => command("large", true, "movie", { pad }), bytes, L.commandBytes).value;
    for (let i = 0; i < 15; i++) assert.equal(plane.admit(full).kind, "admitted");
    const remaining = L.capturedBytes - 15 * (bytes(full) + overhead);
    const last = fit(pad => command("tail", true, "movie", { pad }), bytes, remaining - overhead + delta).value;
    const accepted = plane.admit(last);
    assert.equal(delta ? accepted.reason : accepted.kind, delta ? "admission-capacity" : "admitted");
    if (!delta) assert.equal(plane.admit(command()).reason, "admission-capacity");
    assert.equal(db.rows("attempts").length, 0); assert.equal(context(db).allocated, 0);
    plane.close();
  }
});

test("B13 — discovery renewal evidence and aggregate read/output bounds include escaped current admission", async () => {
  for (const atom of ['"', "\\", "\u0000"]) {
    const saved = fullContext(atom);
    const id = data(saved.value).identity;
    let generation = "";
    while (generation.length < L.identifierUnits && bytes(admission(id, 1, generation + "\u0000")) <= L.metadataBytes) generation += "\u0000";
    while (generation.length < L.identifierUnits && bytes(admission(id, 1, generation + "x")) <= L.metadataBytes) generation += "x";
    const raw = admission(id, 1, generation);
    assert.ok(generation.length > 0 && bytes(raw) <= L.metadataBytes);
    const cmd = fit(pad => command("wide", true, "movie", {}, { version: 1, kind: "inert-fixture", marker: pad }),
      bytes, L.commandBytes).value;
    const source = attemptRow(1, { command: JSON.parse(cmd) }, id);
    assert.ok(source.bytes <= L.attemptBytes);
    const ctx = packed(saved.value, { ...data(saved.value), allocated: 1 });
    assert.ok(ctx.bytes <= L.metadataBytes);
    const db = corpus({ contexts: [ctx], attempts: [source] }), r = await opened(db, raw), before = db.dump();
    const evidence = bytes(cmd) + captureEvidence(raw, id, 1, data(source).nonce);
    assert.ok(evidence <= L.attemptBytes, "fresh recovery handle must fit the unchanged 160 KiB evidence cap");
    const found = await readOnly(db, () => r.plane.discover());
    assert.equal(found.kind, "discovered"); assert.equal(found.items.length, 1); assert.equal(db.dump(), before);
    assert.equal((await r.plane.resolve(found.items[0].handle)).kind, "rejected");
    // Bound derivation: context row supplies Q(C)+2K; generation Q(G)<=7*1024+6.
    const conservativeMetadataUnits = L.metadataBytes / 2 + 7 * L.identifierUnits + 6 + 3 + 512;
    assert.ok(2 * conservativeMetadataUnits + L.commandBytes < L.attemptBytes);
    assert.ok(evidence <= 2 * conservativeMetadataUnits + L.commandBytes);
    const receiptUnits = Math.ceil((2 * (L.metadataBytes / 2) + 6) / 3) + 2 * (L.resultBytes / 2) + 2 + 512;
    assert.ok(2 * receiptUnits < L.receiptBytes);
  }
  // Closed schema domination, not live heap measurements or a malicious-clone guarantee.
  assert.ok(L.attemptBytes + L.recordBytes + L.outboxBytes + 2 * L.metadataBytes < L.transactionBytes);
  assert.ok(1 + 32 + 4096 + 32 + 32 + 32 < L.auditRows); // second read of each outbox source included
});

test("B14 — all stored framing is untrusted; archive first row and malformed envelopes never repair themselves", async () => {
  for (const fault of ["advertised-bytes", "text-size", "unknown-version", "noncanonical", "accessor", "extra-field", "recovery"]) {
    const db = corpus({ records: [recordRow()] }), base = db.rows("records")[0];
    let transformed = false;
    if (fault === "advertised-bytes") base.bytes -= 2;
    if (fault === "text-size") base.text = "x".repeat(L.recordBytes / 2 + 1);
    if (fault === "unknown-version") Object.assign(base, packed(base, { ...data(base), version: 2 }));
    if (fault === "noncanonical") base.text = " " + base.text;
    if (fault === "extra-field") base.foreign = "keep";
    if (fault === "recovery") {
      const row = envelope(["foreign-recovery"], [], { version: 1, preserved: "raw bytes are not disposable" });
      db.tables.get("recovery").set(canonical(row.key), row);
    } else db.tables.get("records").set(canonical(base.key), base);
    if (fault === "accessor") trackReads(db, (store, row) => {
      if (store !== "records" || !row) return row;
      const copy = { ...row }; Object.defineProperty(copy, "text", { enumerable: true, get() { transformed = true; return row.text; } });
      return copy;
    });
    const r = realm(db), result = await readOnly(db, () => r.plane.audit());
    const expected = { "advertised-bytes": "row-accounting", "text-size": "row-limit", "unknown-version": "unknown-version",
      noncanonical: "noncanonical-json", accessor: "row-accessor", "extra-field": "row-fields", recovery: "recovery-not-supported-in-first-unit" };
    assert.equal(result.reason, expected[fault]); assert.equal(transformed, false);
    assert.equal(r.plane.admit(command("fresh")).reason, "not-open");
  }
});
