/**
 * UNWIRED candidate. Explicit factory only; no raw storage, account, network or import effects.
 * Contract: repair-20261018-web-storage-production-contract-addendum.md (7634fdf3...).
 * Native and deterministic ports execute this SAME callback-transaction state machine.
 */
export const DATA_DB_NAME = "vortx.web.data.transactions.v1";
export const DATA_LIMITS = Object.freeze({
  identifierUnits: 1024, contextUnits: 4096, keyUnits: 4096, depth: 32, nodes: 16384,
  contexts: 32, metadataBytes: 16 * 1024, records: 4096, recordBytes: 64 * 1024,
  liveBytes: 4 * 1024 * 1024, commandBytes: 128 * 1024, resultBytes: 4 * 1024,
  attemptBytes: 160 * 1024, attempts: 32, changedRows: 128, transactionBytes: 512 * 1024,
  pendingBytes: 2 * 1024 * 1024, outboxes: 32, outboxBytes: 128 * 1024,
  recoveryRows: 128, recoveryBytes: 2 * 1024 * 1024, recoveryRowBytes: 512 * 1024,
  intervals: 33, queued: 32, capturedBytes: 2 * 1024 * 1024, waitMs: 10_000,
  snapshotBytes: 4 * 1024 * 1024, discoveryBytes: 256 * 1024, readAttempts: 2,
  auditRows: 4321, auditBytes: 8 * 1024 * 1024, receiptBytes: 24 * 1024, safeInteger: Number.MAX_SAFE_INTEGER,
});
const L = DATA_LIMITS;
const STORES = ["meta", "contexts", "records", "attempts", "outbox", "recovery"] as const;
type Store = typeof STORES[number];
type J = null | boolean | number | string | J[] | { [key: string]: J };
type O = { [key: string]: J };
type Key = J[];
type Stored = { key: Key; context: Key; nonceKey: Key; sourceKey: Key; text: string; bytes: number };
type Mode = "readonly" | "readwrite";
type Index = "context" | "nonceKey" | "sourceKey";
type Handle = Readonly<{ kind: "operation" }>;
type Receipt = Readonly<{ kind: "terminal-receipt" }>;
type Reference = Handle;
type Discovered = Readonly<{ sequence: number; state: string; observed: boolean; handle: Handle; outcome?: DataResult }>;
export type DataResult = Readonly<{
  kind: string; reason?: string; handle?: Handle; receipt?: Receipt;
  revision?: number; state?: string; snapshot?: string; items?: readonly Discovered[];
}>;
type Admission = { raw: string; context: J[]; key: Key; epoch: number };
type State = {
  admission: Admission; commandRaw: string; nonce: string; sequence?: number;
  started: boolean; released: boolean; captured: number; terminal?: DataResult;
  databaseId: string; fixture: boolean;
};
type Proof = { key: Key; context: J[]; epoch: number; sequence: number; nonce: string; result: string; databaseId: string };

/** Low-level transaction port, not a replacement storage model. Only fixture factory accepts it. */
export interface DataTransactionPort {
  readonly identity: object;
  run(mode: Mode, stores: readonly Store[], body: (tx: DataPortTransaction) => void,
      events: { entered(): void; complete(): void; abort(reason: string): void; unknown(reason: string): void }): () => void;
  close(): void;
}
export interface DataPortTransaction {
  get(store: Store, key: Key, receive: (row: unknown | undefined) => void): void;
  put(store: Store, row: unknown): void;
  delete(store: Store, key: Key): void;
  keys(store: Store, index: Index | null, equal: Key | null,
       receive: (key: Key, next: () => void) => void, end: () => void): void;
  abort(reason: string): void;
}
export interface DataClock { later(ms: number, body: () => void): () => void }
type Options = { currentAdmission(): string | null };
type Run<T> = { kind: "complete"; value: T } | { kind: "aborted" | "unknown"; reason: string };
type Job = { start(done: () => void): void; cancel(): void };
type Coordinator = { active: boolean; queue: Job[]; admissions: number; captured: number };
const coordinators = new WeakMap<object, Coordinator>();
const nativeIdentity = {};
const nativeClock: DataClock = { later(ms, body) { const id = setTimeout(body, ms); return () => clearTimeout(id); } };
const bytes = (text: string): number => 2 * text.length;
function fail(reason: string): never { throw new Error(reason); }
function invariant(value: unknown, reason: string): asserts value { if (!value) fail(reason); }
function integer(value: J | undefined, min = 0): number {
  invariant(typeof value === "number" && Number.isSafeInteger(value) && value >= min, "invalid-integer");
  return value;
}
function string(value: J | undefined): string { invariant(typeof value === "string", "invalid-string"); return value; }
function object(value: J | undefined): O {
  invariant(value !== null && typeof value === "object" && !Array.isArray(value), "invalid-object");
  return value;
}
function array(value: J | undefined): J[] { invariant(Array.isArray(value), "invalid-array"); return value; }
function exact(o: O, keys: string[]): void {
  const found = Object.keys(o).sort(), expected = [...keys].sort();
  invariant(found.length === expected.length && found.every((key, i) => key === expected[i]), "unknown-fields");
}
function increment(value: number): number { invariant(value < L.safeInteger, "integer-exhausted"); return value + 1; }
function canonical(value: J): string {
  let nodes = 0;
  function visit(v: J, depth: number): string {
    invariant(++nodes <= L.nodes && depth <= L.depth, "json-work-limit");
    if (v === null) return "null";
    if (typeof v === "string" || typeof v === "boolean") return JSON.stringify(v);
    if (typeof v === "number") { invariant(Number.isFinite(v), "nonfinite-number"); return JSON.stringify(v); }
    if (Array.isArray(v)) {
      const descriptors = Object.getOwnPropertyDescriptors(v);
      invariant(Object.keys(descriptors).length === v.length + 1, "array-properties");
      const parts: string[] = [];
      for (let i = 0; i < v.length; i++) {
        const descriptor = descriptors[String(i)];
        invariant(descriptor && "value" in descriptor && descriptor.enumerable, "array-hole-or-accessor");
        parts.push(visit(descriptor.value as J, depth + 1));
      }
      return "[" + parts.join(",") + "]";
    }
    const descriptors = Object.getOwnPropertyDescriptors(v);
    invariant(Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null, "invalid-prototype");
    return "{" + Object.keys(descriptors).sort().map(k => {
      const d = descriptors[k];
      invariant("value" in d && d.enumerable && typeof d.value !== "undefined", "invalid-property");
      return JSON.stringify(k) + ":" + visit(d.value as J, depth + 1);
    }).join(",") + "}";
  }
  return visit(value, 0);
}
function parse(raw: string, cap: number): J {
  invariant(typeof raw === "string" && bytes(raw) <= cap, "text-limit");
  const value: J = JSON.parse(raw);
  invariant(canonical(value) === raw, "noncanonical-json");
  return value;
}
function equal(a: J, b: J): boolean { return canonical(a) === canonical(b); }
function identity(value: J): J[] {
  const a = array(value);
  invariant(a.length === 4 && ["guest", "account"].includes(string(a[0])), "invalid-context");
  for (const s of a.slice(1)) invariant(s === null || (typeof s === "string" && s.length <= L.identifierUnits), "identifier-limit");
  invariant(a[0] !== "account" || (typeof a[1] === "string" && a[1].length > 0), "missing-owner");
  invariant(canonical(a).length <= L.contextUnits, "context-limit");
  return a;
}
function contextKey(id: J[]): Key {
  return [id[0], ...id.slice(1).map(v => v === null ? [0] : [1, v])];
}
function keyCheck(key: Key): void { invariant(canonical(key).length <= L.keyUnits, "key-limit"); }
function admission(raw: string): Admission {
  const a = object(parse(raw, L.metadataBytes));
  exact(a, ["context", "epoch", "generation"]);
  const id = identity(a.context);
  invariant(string(a.generation).length > 0 && string(a.generation).length <= L.identifierUnits, "generation-limit");
  const key = contextKey(id); keyCheck(key);
  return { raw, context: id, key, epoch: integer(a.epoch, 1) };
}
function attemptKey(a: Admission, sequence: number): Key { const key = [a.key, sequence]; keyCheck(key); return key; }
function libraryKey(id: J[], type: string, name: string): Key {
  invariant(type.length > 0 && name.length > 0 && type.length <= L.identifierUnits && name.length <= L.identifierUnits, "title-identity-limit");
  const key: Key = [contextKey(id), "library", type, name]; keyCheck(key); return key;
}
function command(raw: string, fixture: boolean): O {
  const o = object(parse(raw, L.commandBytes));
  return validateCommand(o, fixture);
}
function validateCommand(o: O, fixture: boolean): O {
  invariant(bytes(canonical(o)) <= L.commandBytes, "command-limit");
  exact(o, ["version", "kind", "type", "id", "desired", "seed", "fixture"]);
  invariant(o.version === 1 && o.kind === "library" && typeof o.desired === "boolean", "unsupported-command");
  for (const value of [o.type, o.id]) invariant(typeof value === "string" && value.length > 0 && value.length <= L.identifierUnits, "title-identity-limit");
  invariant(o.seed === null || (typeof o.seed === "object" && !Array.isArray(o.seed)), "invalid-seed");
  if (o.seed !== null) {
    const seed = object(o.seed);
    invariant(seed.type === o.type && seed.id === o.id, "seed-identity");
  }
  invariant(!o.desired || o.seed !== null, "missing-add-seed");
  if (o.fixture !== null) {
    invariant(fixture, "library-outbox-forbidden");
    const intent = object(o.fixture);
    exact(intent, ["kind", "marker", "version"]);
    invariant(intent.kind === "inert-fixture" && intent.version === 1, "fixture-shape");
    string(intent.marker);
  }
  return o;
}
function pack(key: Key, context: Key, data: O, nonceKey: Key = [], sourceKey: Key = []): Stored {
  for (const k of [key, context, nonceKey, sourceKey]) keyCheck(k);
  return packText(key, context, canonical(data), nonceKey, sourceKey);
}
function packText(key: Key, context: Key, text: string, nonceKey: Key = [], sourceKey: Key = []): Stored {
  for (const k of [key, context, nonceKey, sourceKey]) keyCheck(k);
  let count = 0;
  for (let pass = 0; pass < 8; pass++) {
    const row = { key, context, nonceKey, sourceKey, text, bytes: count };
    const actual = bytes(canonical(row));
    if (actual === count) return row;
    count = actual;
  }
  return fail("accounting-fixed-point");
}
function unpack(raw: unknown, cap: number): { row: Stored; data: O } {
  invariant(raw && typeof raw === "object" && !Array.isArray(raw), "invalid-row");
  const ds = Object.getOwnPropertyDescriptors(raw);
  const fields = Object.keys(ds).sort(), expected = ["bytes", "context", "key", "nonceKey", "sourceKey", "text"];
  invariant(fields.length === expected.length && fields.every((key, i) => key === expected[i]), "row-fields");
  for (const d of Object.values(ds)) invariant("value" in d, "row-accessor");
  const r = raw as Stored;
  invariant(typeof r.text === "string" && bytes(r.text) <= cap && Number.isSafeInteger(r.bytes) && r.bytes <= cap, "row-limit");
  for (const key of [r.key, r.context, r.nonceKey, r.sourceKey]) {
    invariant(Array.isArray(key), "invalid-key"); keyCheck(key);
  }
  const data = object(parse(r.text, cap));
  invariant(equal(pack(r.key, r.context, data, r.nonceKey, r.sourceKey), r), "row-accounting");
  invariant(data.version === 1, "unknown-version");
  return { row: r, data };
}
function cap(store: Store): number {
  return store === "records" ? L.recordBytes : store === "attempts" ? L.attemptBytes
    : store === "outbox" ? L.outboxBytes : store === "recovery" ? L.recoveryRowBytes : L.metadataBytes;
}
const META_KEY: Key = ["global"];
function emptyMeta(databaseId: string): O {
  return { version: 1, kind: "global", databaseId, contexts: 0, records: 0, attempts: 0, outbox: 0,
    recovery: 0, reservedRecords: 0, reservedOutbox: 0, liveBytes: 0, pendingBytes: L.metadataBytes, recoveryBytes: 0 };
}
function meta(data: O): O {
  exact(data, ["version", "kind", "databaseId", "contexts", "records", "attempts", "outbox", "recovery",
    "reservedRecords", "reservedOutbox", "liveBytes", "pendingBytes", "recoveryBytes"]);
  invariant(data.kind === "global" && /^[0-9a-f]{64}$/.test(string(data.databaseId)), "global-schema");
  for (const k of ["contexts", "records", "attempts", "outbox", "recovery", "reservedRecords", "reservedOutbox", "liveBytes", "pendingBytes", "recoveryBytes"]) integer(data[k]);
  invariant(integer(data.contexts) <= L.contexts && integer(data.records) + integer(data.reservedRecords) <= L.records
    && integer(data.attempts) <= L.attempts && integer(data.outbox) + integer(data.reservedOutbox) <= L.outboxes
    && integer(data.recovery) <= L.recoveryRows && integer(data.liveBytes) <= L.liveBytes
    && integer(data.pendingBytes) >= L.metadataBytes && integer(data.pendingBytes) <= L.pendingBytes
    && integer(data.recoveryBytes) <= L.recoveryBytes, "capacity");
  return data;
}
function context(data: O): O {
  exact(data, ["version", "kind", "identity", "epoch", "revision", "allocated", "retired"]);
  invariant(data.kind === "context", "context-kind"); identity(data.identity);
  integer(data.epoch, 1); integer(data.revision); integer(data.allocated);
  const spans = array(data.retired);
  invariant(spans.length <= L.intervals, "interval-limit");
  let previous = 0;
  for (const entry of spans) {
    const pair = array(entry);
    invariant(pair.length === 2, "interval-shape");
    const start = integer(pair[0], 1), end = integer(pair[1], start);
    invariant(start > previous && end <= integer(data.allocated), "interval-order"); previous = end;
  }
  return data;
}
function retired(ctx: O, seq: number): boolean {
  return array(ctx.retired).some(pair => { const p = array(pair); return integer(p[0]) <= seq && seq <= integer(p[1]); });
}
function terminal(a: O): boolean { return a.state !== "prepared"; }
function validateAttempt(a: O, allowFixture: boolean): O {
  exact(a, ["version", "kind", "identity", "epoch", "sequence", "nonce", "command", "state", "result", "observed"]);
  invariant(a.kind === "attempt" && ["prepared", "committed", "unchanged", "rejected"].includes(string(a.state)), "attempt-state");
  identity(a.identity); integer(a.epoch, 1); integer(a.sequence, 1);
  invariant(/^[0-9a-f]{64}$/.test(string(a.nonce)) && typeof a.observed === "boolean", "attempt-identity");
  validateCommand(object(a.command), allowFixture);
  if (!terminal(a)) invariant(a.result === null && a.observed === false, "prepared-result");
  else {
    const result = object(a.result); exact(result, ["state", "revision", "reason"]);
    invariant(result.state === a.state && (result.reason === null || typeof result.reason === "string"), "terminal-result");
    integer(result.revision); invariant(bytes(canonical(result)) <= L.resultBytes, "result-limit");
  }
  return a;
}
function validateRecord(r: O): O {
  exact(r, ["version", "kind", "identity", "title", "membership", "membershipRevision", "entry"]);
  invariant(r.kind === "library" && typeof r.membership === "boolean", "record-schema");
  identity(r.identity);
  const title = array(r.title); invariant(title.length === 2, "title-shape");
  libraryKey(identity(r.identity), string(title[0]), string(title[1]));
  integer(r.membershipRevision, 1);
  const entry = object(r.entry);
  invariant(entry.type === title[0] && entry.id === title[1], "entry-identity");
  return r;
}
function plus(m: O, field: string, delta: number): void {
  const previous = m[field] === undefined ? 0 : m[field];
  invariant(typeof previous === "number" && Number.isSafeInteger(previous), "invalid-delta");
  m[field] = previous + delta;
}
// Serialized row evidence plus scalar/delta bookkeeping, never a retained parsed metadata row.
function contextBookkeeping(data: O, text: string, admittedRaw: string): O {
  return { text, admission: admittedRaw, epoch: data.epoch, revision: data.revision, allocated: data.allocated,
    retired: array(data.retired).map(span => [...array(span)]) };
}
function terminalText(a: O): string {
  return canonical({ sequence: a.sequence, nonce: a.nonce, epoch: a.epoch, state: a.state, result: a.result });
}
function attemptText(s: State, state: string, result: O | null, observed = false): string {
  // commandRaw was canonicalized and validated at admission AND exact-row validation.
  return '{"command":' + s.commandRaw + ',"epoch":' + String(s.admission.epoch)
    + ',"identity":' + canonical(s.admission.context) + ',"kind":"attempt","nonce":' + JSON.stringify(s.nonce)
    + ',"observed":' + String(observed) + ',"result":' + canonical(result)
    + ',"sequence":' + String(s.sequence) + ',"state":' + JSON.stringify(state) + ',"version":1}';
}
function partition(ctx: O, live: number[]): void {
  const spans = array(ctx.retired).map(p => { const x = array(p); return [integer(x[0]), integer(x[1])]; });
  for (const seq of live) spans.push([seq, seq]);
  spans.sort((a, b) => a[0] - b[0]);
  let end = 0;
  for (const [first, last] of spans) { invariant(first === end + 1, "allocation-hole"); end = last; }
  invariant(end === integer(ctx.allocated), "allocation-hole");
}
function addRetired(ctx: O, seq: number): void {
  const spans = array(ctx.retired).map(p => { const a = array(p); return [integer(a[0]), integer(a[1])]; });
  spans.push([seq, seq]); spans.sort((a, b) => a[0] - b[0]);
  const result: J[] = [];
  for (const span of spans) {
    const tail = result.length ? array(result[result.length - 1]) : null;
    if (tail && integer(tail[1]) < L.safeInteger && span[0] === integer(tail[1]) + 1) tail[1] = span[1];
    else { invariant(!tail || span[0] > integer(tail[1]), "retired-overlap"); result.push(span); }
  }
  invariant(result.length <= L.intervals, "interval-limit"); ctx.retired = result;
}

class Work {
  used = 0; written = 0; reads = 0;
  readonly tx: DataPortTransaction;
  readonly readCap: number;
  readonly invalid: () => void;
  constructor(tx: DataPortTransaction, readCap: number, invalid: () => void) { this.tx = tx; this.readCap = readCap; this.invalid = invalid; }
  read(store: Store, key: Key, receive: (data: O | undefined, row?: Stored) => void | (() => void)): void {
    this.tx.get(store, key, raw => {
      // decode's frame (and its full parsed row) ends before the next-phase closure runs.
      const next = this.decode(store, key, raw, receive);
      next?.();
    });
  }
  private decode(store: Store, key: Key, raw: unknown, receive: (data: O | undefined, row?: Stored) => void | (() => void)): void | (() => void) {
    if (raw === undefined) return receive(undefined);
    let decoded: { data: O; row: Stored };
    try { decoded = unpack(raw, cap(store)); } catch (error) { this.invalid(); throw error; }
    const { data, row } = decoded;
    invariant(++this.reads <= L.auditRows, "read-count-limit");
    invariant(equal(row.key, key), "wrong-key");
    this.used += row.bytes; invariant(this.used <= this.readCap, "read-work-limit");
    return receive(data, row);
  }
  put(store: Store, row: Stored): void {
    invariant(row.bytes <= cap(store), "row-limit");
    this.written += row.bytes; invariant(this.written <= L.transactionBytes, "transaction-limit");
    this.tx.put(store, row);
  }
  scan(store: Store, index: Index | null, match: Key | null, maximum: number,
       each: (key: Key, next: () => void) => void, end: () => void): void {
    let visited = 0;
    this.tx.keys(store, index, match, (key, next) => {
      keyCheck(key); invariant(++visited <= maximum, "cursor-limit"); each(key, next);
    }, end);
  }
}

export type BrowserDataTransactions = ReturnType<typeof createCore>;
const expectedRefusals = new Set([
  "capacity", "future-attempt-limit", "future-outbox-limit", "future-record-limit", "row-limit",
  "transaction-limit", "json-work-limit", "integer-exhausted", "interval-limit", "key-limit",
  "nonce-collision", "admission-retired", "owner-retired", "epoch-retired", "epoch-step", "not-open",
  "QuotaExceededError", "AbortError", "after-request-success", "entry-timeout",
]);
function createCore(port: DataTransactionPort, options: Options, random: () => string, clock: DataClock, fixture: boolean) {
  let closed = false, databaseId = "", ready = false;
  const operations = new WeakMap<object, State>(), receipts = new WeakMap<object, Proof>();
  const admitted = new Set<State>();
  const ownedJobs = new Set<Job>();
  let c = coordinators.get(port.identity);
  if (!c) { c = { active: false, queue: [], admissions: 0, captured: 0 }; coordinators.set(port.identity, c); }
  const coordinator = c;
  function now(): Admission { const raw = options.currentAdmission(); invariant(raw !== null, "admission-unavailable"); return admission(raw); }
  function same(a: Admission, epoch = true): boolean {
    const current = now();
    return equal(current.context, a.context) && (!epoch || current.raw === a.raw);
  }
  function release(s: State): void {
    if (s.released) return; s.released = true;
    admitted.delete(s);
    coordinator.admissions--; coordinator.captured -= s.captured;
  }
  function pump(): void {
    if (coordinator.active || !coordinator.queue.length) return;
    const job = coordinator.queue.shift()!; coordinator.active = true;
    job.start(() => { coordinator.active = false; pump(); });
  }
  function transaction<T>(mode: Mode, readCap: number, body: (w: Work, finish: (v: T) => void) => void): Promise<Run<T>> {
    if (closed) return Promise.resolve({ kind: "unknown", reason: "closed" });
    if (coordinator.queue.length + Number(coordinator.active) >= L.queued) return Promise.resolve({ kind: "aborted", reason: "queue-limit" });
    return new Promise(resolve => {
      let settled = false, entered = false, dispatched = false;
      let cancelNative: (() => void) | undefined;
      const finish = (result: Run<T>, done?: () => void) => {
        if (settled) return; settled = true; ownedJobs.delete(job); cancelWait(); resolve(result); done?.();
      };
      const job: Job = {
        cancel() {
          if (entered || settled) return;
          if (dispatched) { cancelNative?.(); return; } // Await the native abort event; never invent noncommit.
          const i = coordinator.queue.indexOf(job); if (i >= 0) coordinator.queue.splice(i, 1);
          finish({ kind: "aborted", reason: "entry-timeout" });
        },
        start(done) {
          if (settled) { done(); return; }
          dispatched = true; // The ORIGINAL deadline continues until the first native request event.
          let value!: T, hasValue = false;
          try {
            cancelNative = port.run(mode, STORES, tx => {
              if (mode === "readwrite") invariant(ready, "not-open");
              body(new Work(tx, readCap, () => { ready = false; }), result => { invariant(!hasValue, "double-result"); hasValue = true; value = result; });
            }, {
              entered: () => { if (!settled) { entered = true; cancelWait(); } },
              complete: () => finish(hasValue ? { kind: "complete", value } : { kind: "unknown", reason: "missing-result" }, done),
              abort: reason => {
                if (!expectedRefusals.has(reason)) ready = false; // Detected corruption requires a new explicit open/audit.
                finish({ kind: "aborted", reason }, done);
              },
              unknown: reason => finish({ kind: "unknown", reason }, done),
            });
          } catch { finish({ kind: "unknown", reason: "port-unavailable" }, done); }
        },
      };
      const cancelWait = clock.later(L.waitMs, () => job.cancel());
      ownedJobs.add(job); coordinator.queue.push(job); pump();
    });
  }
  function header(w: Work, a: Admission, next: (m: O, ctx: O) => void): void {
    w.read("meta", META_KEY, (data, row) => {
      invariant(data && row, "missing-global"); meta(data);
      invariant(data.databaseId === databaseId, "database-incarnation");
      const m: O = { text: row.text };
      return () => w.read("contexts", a.key, (data, row) => {
        invariant(data && row, "missing-context"); context(data);
        const live = now();
        invariant(equal(data.identity, a.context), "context-identity");
        invariant(equal(live.context, a.context) && live.epoch === data.epoch, "admission-retired");
        const ctx = contextBookkeeping(data, row.text, live.raw);
        return () => next(m, ctx);
      });
    });
  }
  function contextWrite(ctx: O, a: Admission): Stored {
    const value: O = ctx.text === null
      ? { version: 1, kind: "context", identity: a.context, epoch: a.epoch, revision: 0, allocated: 0, retired: [] }
      : object(parse(string(ctx.text), L.metadataBytes));
    for (const field of ["epoch", "revision", "allocated", "retired"]) value[field] = ctx[field];
    context(value); return pack(a.key, a.key, value);
  }
  function globalWrite(m: O): Stored {
    const value = object(parse(string(m.text), L.metadataBytes));
    for (const field of Object.keys(m)) if (field !== "text") {
      invariant(typeof m[field] === "number", "invalid-delta"); plus(value, field, m[field]);
    }
    meta(value); return pack(META_KEY, [], value);
  }
  function saveHeader(w: Work, m: O, ctx: O, a: Admission): void {
    const live = now(); invariant(equal(live.context, a.context) && live.epoch === ctx.epoch && live.raw === ctx.admission, "admission-retired");
    // Each serializer returns before the next row is parsed. Call only after a decode frame.
    w.put("contexts", contextWrite(ctx, a));
    w.put("meta", globalWrite(m));
  }
  function issue(s: State, attempt: O): DataResult {
    const result = object(attempt.result);
    const token: Receipt = Object.freeze({ kind: "terminal-receipt" });
    const proof: Proof = {
      key: attemptKey(s.admission, integer(attempt.sequence)), context: s.admission.context,
      epoch: integer(attempt.epoch), sequence: integer(attempt.sequence), nonce: string(attempt.nonce),
      result: canonical(result), databaseId: s.databaseId,
    };
    invariant(bytes(canonical(proof)) <= L.receiptBytes, "receipt-evidence-limit");
    receipts.set(token, proof);
    const value: DataResult = Object.freeze({ kind: string(attempt.state), revision: integer(result.revision),
      ...(typeof result.reason === "string" ? { reason: result.reason } : {}), receipt: token });
    s.terminal = value; release(s); return value;
  }
  function identify(s: State, a: O): void {
    validateAttempt(a, fixture);
    invariant(a.sequence === s.sequence && a.nonce === s.nonce && equal(a.identity, s.admission.context)
      && a.epoch === s.admission.epoch && canonical(a.command) === s.commandRaw, "attempt-identity");
  }
  function outcome<T>(run: Run<T>): DataResult {
    return Object.freeze({ kind: run.kind === "unknown" ? "pending" : "unavailable", reason: run.kind === "complete" ? "unexpected-result" : run.reason });
  }
  function authenticate(handle: Reference): State {
    const s = operations.get(handle); invariant(s, "foreign-operation"); return s;
  }
  function admitInternal(raw: string, allowFixture: boolean): DataResult {
    try {
      invariant(ready && !closed, "not-open"); const a = now(), cmd = command(raw, allowFixture);
      libraryKey(a.context, string(cmd.type), string(cmd.id));
      const nonce = random(); invariant(/^[0-9a-f]{64}$/.test(nonce), "randomness-unavailable");
      const captured = bytes(raw) + bytes(canonical({ admission: a.raw, context: a.context, key: a.key,
        epoch: a.epoch, nonce, databaseId, sequence: L.safeInteger }));
      invariant(captured <= L.attemptBytes, "admission-evidence-limit");
      invariant(coordinator.admissions < L.queued && coordinator.captured + captured <= L.capturedBytes, "admission-capacity");
      const h: Handle = Object.freeze({ kind: "operation" });
      const state: State = { admission: a, commandRaw: raw, nonce, started: false,
        released: false, captured, databaseId, fixture: allowFixture };
      operations.set(h, state); admitted.add(state);
      coordinator.admissions++; coordinator.captured += captured;
      return Object.freeze({ kind: "admitted", handle: h });
    } catch (e) { return Object.freeze({ kind: "unavailable", reason: errorReason(e) }); }
  }
  async function resolve(handle: Reference): Promise<DataResult> {
    let s: State;
    try { s = authenticate(handle); } catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    if (s.terminal) return s.terminal;
    if (s.sequence === undefined) return { kind: "pending", reason: "sequence-unavailable" };
    const run = await transaction<{ state: "retired" | "attempt"; text?: string }>("readonly", L.transactionBytes, (w, finish) => {
      invariant(same(s.admission, false), "owner-retired");
      header(w, s.admission, (_m, ctx) => {
        const seq = s.sequence!;
        if (retired(ctx, seq)) { finish({ state: "retired" }); return; }
        w.read("attempts", attemptKey(s.admission, seq), data => {
          invariant(data, seq <= integer(ctx.allocated) ? "missing-allocated-attempt" : "unallocated-unknown");
          identify(s, data); finish({ state: "attempt", text: terminal(data) ? terminalText(data) : "" });
        });
      });
    });
    if (s.terminal) return s.terminal;
    if (run.kind !== "complete") return outcome(run);
    if (run.value.state === "retired") {
      const result = Object.freeze({ kind: "details-retired" }); s.terminal = result; release(s); return result;
    }
    if (run.value.text) return issue(s, object(parse(run.value.text, L.metadataBytes)));
    release(s); return Object.freeze({ kind: "prepared", handle });
  }
  function preparedEnvelope(s: State, seq: number): { row: Stored; withOutbox: boolean } {
    const cmd = command(s.commandRaw, s.fixture);
    const a: O = { version: 1, kind: "attempt", identity: s.admission.context, epoch: s.admission.epoch,
      sequence: seq, nonce: s.nonce, command: cmd, state: "prepared", result: null, observed: false };
    for (const state of ["committed", "unchanged", "rejected"]) {
      a.state = state; a.result = { state, revision: L.safeInteger, reason: "epoch-retired" };
      invariant(pack(attemptKey(s.admission, seq), s.admission.key, a, [s.admission.key, s.nonce]).bytes <= L.attemptBytes, "future-attempt-limit");
    }
    a.state = "prepared"; a.result = null;
    const withOutbox = cmd.fixture !== null;
    if (withOutbox) invariant(pack([s.admission.key, seq, "fixture"], s.admission.key,
      { version: 1, kind: "inert-outbox", identity: s.admission.context, sequence: seq, nonce: s.nonce,
        intent: cmd.fixture, state: "inert" }, [], attemptKey(s.admission, seq)).bytes <= L.outboxBytes, "future-outbox-limit");
    const seed = cmd.seed ?? { type: cmd.type, id: cmd.id };
    invariant(pack(libraryKey(s.admission.context, string(cmd.type), string(cmd.id)), s.admission.key,
      { version: 1, kind: "library", identity: s.admission.context, title: [cmd.type, cmd.id],
        membership: cmd.desired, membershipRevision: L.safeInteger, entry: seed }).bytes <= L.recordBytes, "future-record-limit");
    return { row: pack(attemptKey(s.admission, seq), s.admission.key, a, [s.admission.key, s.nonce]), withOutbox };
  }
  async function prepare(handle: Handle): Promise<DataResult> {
    let s: State;
    try { s = authenticate(handle); } catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    if (s.terminal) return s.terminal;
    if (s.started) return resolve(handle);
    s.started = true;
    const run = await transaction<boolean>("readwrite", L.transactionBytes, (w, finish) => {
      invariant(same(s.admission), "admission-retired");
      header(w, s.admission, (m, ctx) => {
        invariant(ctx.epoch === s.admission.epoch, "epoch-retired");
        let collision = false;
        w.scan("attempts", "nonceKey", [s.admission.key, s.nonce], 1, (_key, next) => { collision = true; next(); }, () => {
          invariant(!collision, "nonce-collision");
          const seq = increment(integer(ctx.allocated));
          s.sequence = seq; // BEFORE any allocation/attempt write can publish.
          const { row, withOutbox } = preparedEnvelope(s, seq);
          ctx.allocated = seq; plus(m, "attempts", 1); plus(m, "reservedRecords", 1);
          plus(m, "liveBytes", L.recordBytes); plus(m, "pendingBytes", L.attemptBytes + (withOutbox ? L.outboxBytes : 0));
          if (withOutbox) plus(m, "reservedOutbox", 1);
          invariant(same(s.admission), "admission-retired");
          w.put("attempts", row);
          saveHeader(w, m, ctx, s.admission); finish(true);
        });
      });
    });
    release(s);
    if (s.terminal) return s.terminal;
    if (run.kind === "complete") return Object.freeze({ kind: "prepared", handle });
    if (run.kind === "aborted") { s.terminal = Object.freeze({ kind: "prepare-aborted", reason: run.reason }); return s.terminal; }
    return Object.freeze({ kind: "pending", reason: run.reason });
  }
  function finishAfterHeader<T>(w: Work, m: O, ctx: O, a: Admission, finish: (value: T) => void, value: T): () => void {
    return () => { saveHeader(w, m, ctx, a); finish(value); };
  }
  type Intent = { type: string; id: string; desired: boolean; seed: string; fixture: string };
  function intent(a: O): Intent {
    const cmd = object(a.command);
    return { type: string(cmd.type), id: string(cmd.id), desired: cmd.desired === true,
      seed: canonical(cmd.seed), fixture: canonical(cmd.fixture) };
  }
  function applyRecord(w: Work, s: State, m: O, ctx: O, finish: (value: string | null) => void, cmd: Intent): () => void {
    // This continuation's environment contains no decoded attempt row.
    return () => {
      const key = attemptKey(s.admission, s.sequence!);
      const recordKey = libraryKey(s.admission.context, cmd.type, cmd.id);
      w.read("records", recordKey, (old, oldRow) => {
        if (old) {
          validateRecord(old);
          invariant(equal(old.identity, s.admission.context) && equal(old.title, [cmd.type, cmd.id])
            && integer(old.membershipRevision) <= integer(ctx.revision), "record-identity");
        }
        let state = "rejected", reason: J = "epoch-retired";
        if (ctx.epoch === s.admission.epoch && now().raw === s.admission.raw) {
          const changed = !old || old.membership !== cmd.desired;
          state = changed ? "committed" : "unchanged"; reason = null;
          if (changed) {
            const revision = increment(integer(ctx.revision));
            // Mutate the sole decoded row, or construct one when the read was absent.
            const next: O = old ?? { version: 1, kind: "library", identity: s.admission.context,
              title: [cmd.type, cmd.id], membership: cmd.desired, membershipRevision: revision,
              entry: cmd.seed === "null" ? { type: cmd.type, id: cmd.id } : parse(cmd.seed, L.commandBytes) };
            next.membership = cmd.desired; next.membershipRevision = revision;
            const row = pack(recordKey, s.admission.key, next);
            w.put("records", row); ctx.revision = revision;
            plus(m, "liveBytes", row.bytes - (oldRow?.bytes ?? 0));
            if (!old) plus(m, "records", 1);
          }
        }
        const result: O = { state, revision: integer(ctx.revision), reason };
        const final = packText(key, s.admission.key, attemptText(s, state, result), [s.admission.key, s.nonce]);
        const withOutbox = cmd.fixture !== "null";
        plus(m, "pendingBytes", final.bytes - L.attemptBytes - (withOutbox ? L.outboxBytes : 0));
        plus(m, "liveBytes", -L.recordBytes); plus(m, "reservedRecords", -1);
        if (withOutbox) {
          plus(m, "reservedOutbox", -1);
          if (state === "committed") {
            const text = '{"identity":' + canonical(s.admission.context) + ',"intent":' + cmd.fixture
              + ',"kind":"inert-outbox","nonce":' + JSON.stringify(s.nonce) + ',"sequence":' + String(s.sequence)
              + ',"state":"inert","version":1}';
            const event = packText([s.admission.key, s.sequence!, "fixture"], s.admission.key, text, [], key);
            w.put("outbox", event); plus(m, "pendingBytes", event.bytes); plus(m, "outbox", 1);
          }
        }
        w.put("attempts", final);
        const proof = canonical({ sequence: s.sequence!, nonce: s.nonce, epoch: s.admission.epoch, state, result });
        return finishAfterHeader(w, m, ctx, s.admission, finish, proof);
      });
    };
  }
  async function apply(handle: Reference): Promise<DataResult> {
    let s: State;
    try { s = authenticate(handle); } catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    if (s.terminal) return s.terminal;
    if (s.sequence === undefined) return { kind: "pending", reason: "not-prepared" };
    const run = await transaction<string | null>("readwrite", L.transactionBytes, (w, finish) => {
      invariant(same(s.admission, false), "owner-retired");
      header(w, s.admission, (m, ctx) => {
        if (retired(ctx, s.sequence!)) { finish(null); return; }
        w.read("attempts", attemptKey(s.admission, s.sequence!), a => {
          invariant(a, "missing-allocated-attempt"); identify(s, a);
          if (terminal(a)) { finish(terminalText(a)); return; }
          return applyRecord(w, s, m, ctx, finish, intent(a));
        });
      });
    });
    if (s.terminal) return s.terminal;
    if (run.kind !== "complete") return outcome(run);
    if (!run.value) { const result = Object.freeze({ kind: "details-retired" }); s.terminal = result; release(s); return result; }
    return issue(s, object(parse(run.value, L.metadataBytes)));
  }
  type Observation = { type: string; id: string; desired: boolean; revision: number; rejected: boolean; previousBytes: number; text: string; bytes: number };
  function observeRecord(w: Work, a: Admission, p: Proof, m: O, ctx: O, finish: (value: string) => void, saved: Observation): () => void {
    return () => {
      let dependency = false;
      w.scan("outbox", "sourceKey", p.key, L.outboxes, (_key, next) => { dependency = true; next(); }, () => {
        w.read("records", libraryKey(a.context, saved.type, saved.id), record => {
          let covered = false;
          if (record) {
            validateRecord(record);
            invariant(equal(record.identity, a.context) && equal(record.title, [saved.type, saved.id]), "record-identity");
            const r = integer(record.membershipRevision), current = integer(ctx.revision);
            invariant(r <= current, "future-record");
            covered = record.membership === saved.desired || r > saved.revision;
          }
          if (!dependency && covered && !saved.rejected) {
            addRetired(ctx, p.sequence);
            w.tx.delete("attempts", p.key); plus(m, "attempts", -1); plus(m, "pendingBytes", -saved.previousBytes);
            return finishAfterHeader(w, m, ctx, a, finish, "details-retired");
          }
          plus(m, "pendingBytes", saved.bytes - saved.previousBytes);
          w.put("attempts", packText(p.key, a.key, saved.text, [a.key, p.nonce]));
          return finishAfterHeader(w, m, ctx, a, finish, "observed");
        });
      });
    };
  }
  async function observe(receipt: Receipt): Promise<DataResult> {
    const p = receipts.get(receipt);
    if (!p) return { kind: "unavailable", reason: "foreign-receipt" };
    let a: Admission;
    try { a = now(); invariant(equal(a.context, p.context) && p.databaseId === databaseId, "owner-retired"); }
    catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    const run = await transaction<string>("readwrite", L.transactionBytes, (w, finish) => {
      invariant(same(a), "admission-retired");
      header(w, a, (m, ctx) => {
        if (retired(ctx, p.sequence)) { finish("details-retired"); return; }
        w.read("attempts", p.key, (attempt, previous) => {
          invariant(attempt && previous, "missing-allocated-attempt"); validateAttempt(attempt, fixture);
          invariant(terminal(attempt) && attempt.sequence === p.sequence && attempt.nonce === p.nonce
            && attempt.epoch === p.epoch && equal(attempt.identity, p.context)
            && canonical(attempt.result) === p.result, "receipt-mismatch");
          attempt.observed = true;
          const row = pack(p.key, a.key, attempt, [a.key, p.nonce]);
          invariant(row.bytes <= previous.bytes, "observation-grew");
          const cmd = object(attempt.command);
          return observeRecord(w, a, p, m, ctx, finish, {
            type: string(cmd.type), id: string(cmd.id), desired: cmd.desired === true,
            revision: integer(object(attempt.result).revision), rejected: attempt.state === "rejected",
            previousBytes: previous.bytes, text: row.text, bytes: row.bytes,
          });
        });
      });
    });
    return run.kind === "complete" ? Object.freeze({ kind: run.value }) : outcome(run);
  }
  async function discover(): Promise<DataResult> {
    let a: Admission;
    try { a = now(); invariant(ready, "not-open"); } catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    type PendingItem = { item: Discovered; state: State; terminal?: string };
    const run = await transaction<PendingItem[]>("readonly", L.pendingBytes + 2 * L.metadataBytes, (w, finish) => {
      invariant(same(a), "admission-retired");
      header(w, a, (_m, ctx) => {
        const items: PendingItem[] = [], live: number[] = [];
        let summaryBytes = 0;
        w.scan("attempts", "context", a.key, L.attempts, (key, next) => {
          w.read("attempts", key, data => {
            invariant(data, "missing-cursor-row"); validateAttempt(data, fixture);
            invariant(equal(data.identity, a.context) && equal(key, [a.key, data.sequence]), "attempt-context");
            const summary: O = { sequence: data.sequence, state: data.state, observed: data.observed };
            summaryBytes += bytes(canonical(summary)); invariant(summaryBytes <= L.discoveryBytes, "discovery-summary-limit");
            const h: Handle = Object.freeze({ kind: "operation" }), cmd = object(data.command);
            const state: State = { admission: { ...a, epoch: integer(data.epoch) }, commandRaw: canonical(cmd),
              nonce: string(data.nonce), sequence: integer(data.sequence), started: true, released: true,
              captured: 0, databaseId, fixture: cmd.fixture !== null };
            operations.set(h, state);
            items.push({ item: { sequence: integer(data.sequence), state: string(data.state), observed: data.observed === true, handle: h }, state,
              ...(terminal(data) ? { terminal: terminalText(data) } : {}) });
            live.push(integer(data.sequence)); next();
          });
        }, () => { partition(ctx, live); finish(items); });
      });
    });
    if (run.kind !== "complete") return outcome(run);
    try { invariant(same(a), "admission-retired"); } catch { return { kind: "unavailable", reason: "admission-retired" }; }
    const items = run.value.map(({ item, state, terminal: saved }) => Object.freeze({ ...item, ...(saved ? { outcome: issue(state, object(parse(saved, L.metadataBytes))) } : {}) }));
    return Object.freeze({ kind: "discovered", items: Object.freeze(items) });
  }
  async function snapshot(): Promise<DataResult> {
    let a: Admission;
    try { a = now(); invariant(ready, "not-open"); } catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    const run = await transaction<{ text: string; revision: number }>("readonly", L.liveBytes + L.metadataBytes, (w, finish) => {
      invariant(same(a), "admission-retired");
      header(w, a, (_m, ctx) => {
        invariant(ctx.epoch === a.epoch, "epoch-retired");
        const records: string[] = []; let size = 0;
        w.scan("records", "context", a.key, L.records, (key, next) => {
          w.read("records", key, data => {
            invariant(data, "missing-cursor-row"); validateRecord(data);
            invariant(equal(data.identity, a.context) && integer(data.membershipRevision) <= integer(ctx.revision), "record-context");
            const text = canonical(data); size += bytes(text) + 2;
            invariant(size <= L.snapshotBytes, "snapshot-limit"); records.push(text); next();
          });
        }, () => {
          const text = '{"context":' + canonical(a.context) + ',"epoch":' + String(ctx.epoch) + ',"records":['
            + records.join(",") + '],"revision":' + String(ctx.revision) + "}";
          invariant(bytes(text) <= L.snapshotBytes, "snapshot-limit");
          finish({ text, revision: integer(ctx.revision) });
        });
      });
    });
    if (run.kind !== "complete") return outcome(run);
    try { invariant(same(a), "admission-retired"); } catch { return { kind: "unavailable", reason: "admission-retired" }; }
    return Object.freeze({ kind: "snapshot", snapshot: run.value.text, revision: run.value.revision });
  }
  async function createContext(): Promise<DataResult> {
    let a: Admission;
    try { a = now(); invariant(ready, "not-open"); } catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    const run = await transaction<string>("readwrite", L.transactionBytes, (w, finish) => {
      invariant(same(a), "admission-retired");
      w.read("meta", META_KEY, (data, row) => {
        invariant(data && row, "missing-global"); meta(data); invariant(data.databaseId === databaseId, "database-incarnation");
        const m: O = { text: row.text };
        return () => w.read("contexts", a.key, existing => {
          if (existing) { context(existing); invariant(equal(existing.identity, a.context) && existing.epoch === a.epoch, "existing-context"); finish("context-existing"); return; }
          const ctx: O = { text: null, admission: a.raw, epoch: a.epoch, revision: 0, allocated: 0, retired: [] };
          plus(m, "contexts", 1); plus(m, "liveBytes", L.metadataBytes);
          return finishAfterHeader(w, m, ctx, a, finish, "context-created");
        });
      });
    });
    return run.kind === "complete" ? { kind: run.value } : outcome(run);
  }
  async function advanceEpoch(): Promise<DataResult> {
    let a: Admission;
    try { a = now(); invariant(ready, "not-open"); } catch (e) { return { kind: "unavailable", reason: errorReason(e) }; }
    const run = await transaction<string>("readwrite", L.transactionBytes, (w, finish) => {
      invariant(same(a), "admission-retired");
      w.read("meta", META_KEY, (data, row) => {
        invariant(data && row, "missing-global"); meta(data); invariant(data.databaseId === databaseId, "database-incarnation");
        const m: O = { text: row.text };
        return () => w.read("contexts", a.key, (existing, row) => {
          invariant(existing && row, "missing-context"); context(existing);
          invariant(equal(existing.identity, a.context), "context-identity");
          if (existing.epoch === a.epoch) { finish("epoch-existing"); return; }
          invariant(increment(integer(existing.epoch)) === a.epoch, "epoch-step");
          const ctx = contextBookkeeping(existing, row.text, a.raw); ctx.epoch = a.epoch;
          return finishAfterHeader(w, m, ctx, a, finish, "epoch-advanced");
        });
      });
    });
    return run.kind === "complete" ? { kind: run.value } : outcome(run);
  }
  async function audit(): Promise<DataResult> {
    const run = await transaction<string>("readonly", L.auditBytes, (w, finish) => {
      const totals: O = emptyMeta("0".repeat(64));
      const contexts = new Map<string, O>(), sequences = new Map<string, number[]>();
      let actualText: string | undefined, count = 0;
      function storeAt(index: number): void {
        if (index === STORES.length) {
          invariant(actualText, "missing-global");
          const actual = object(parse(actualText, L.metadataBytes));
          for (const [id, ctx] of contexts) partition(ctx, sequences.get(id) ?? []);
          for (const id of sequences.keys()) invariant(contexts.has(id), "orphan-context");
          for (const field of Object.keys(totals)) if (!["databaseId", "version", "kind"].includes(field))
            invariant(actual[field] === totals[field], "accounting-mismatch");
          finish(string(actual.databaseId)); return;
        }
        const store = STORES[index], maximum = store === "meta" ? 1 : store === "contexts" ? L.contexts
          : store === "records" ? L.records : store === "attempts" ? L.attempts : store === "outbox" ? L.outboxes : L.recoveryRows;
        w.scan(store, null, null, maximum, (key, next) => {
          invariant(++count <= L.auditRows, "audit-count");
          w.read(store, key, (data, row) => {
            invariant(data && row, "missing-cursor-row");
            if (store !== "outbox") invariant(equal(row.sourceKey, []), "unexpected-source-index");
            if (store !== "attempts") invariant(equal(row.nonceKey, []), "unexpected-nonce-index");
            if (store === "meta") { invariant(equal(key, META_KEY) && equal(row.context, []), "global-key"); meta(data); actualText = row.text; }
            if (store === "contexts") {
              context(data); const ck = contextKey(identity(data.identity));
              invariant(equal(key, ck) && equal(row.context, ck), "context-index");
              contexts.set(canonical(ck), { revision: data.revision, allocated: data.allocated,
                retired: array(data.retired).map(span => [...array(span)]) });
              plus(totals, "contexts", 1); plus(totals, "liveBytes", L.metadataBytes);
            }
            if (store === "records") {
              validateRecord(data); const ck = contextKey(identity(data.identity)), title = array(data.title);
              invariant(equal(row.context, ck) && equal(key, libraryKey(identity(data.identity), string(title[0]), string(title[1]))), "record-index");
              invariant(contexts.has(canonical(ck)) && integer(data.membershipRevision) <= integer(contexts.get(canonical(ck))!.revision), "record-context");
              plus(totals, "records", 1); plus(totals, "liveBytes", row.bytes);
            }
            if (store === "attempts") {
              validateAttempt(data, fixture); const ck = contextKey(identity(data.identity)), id = canonical(ck);
              invariant(equal(key, [ck, data.sequence]) && equal(row.context, ck) && equal(row.nonceKey, [ck, data.nonce]), "attempt-index");
              const seq = sequences.get(id) ?? []; seq.push(integer(data.sequence)); sequences.set(id, seq);
              plus(totals, "attempts", 1);
              if (terminal(data)) plus(totals, "pendingBytes", row.bytes);
              else {
                const fixtureIntent = object(data.command).fixture !== null;
                plus(totals, "pendingBytes", L.attemptBytes + (fixtureIntent ? L.outboxBytes : 0));
                plus(totals, "liveBytes", L.recordBytes); plus(totals, "reservedRecords", 1);
                if (fixtureIntent) plus(totals, "reservedOutbox", 1);
              }
            }
            if (store === "outbox") {
              invariant(fixture, "fixture-row-in-native-db");
              exact(data, ["version", "kind", "identity", "sequence", "nonce", "intent", "state"]);
              const ck = contextKey(identity(data.identity)); integer(data.sequence, 1);
              invariant(data.kind === "inert-outbox" && data.state === "inert" && equal(row.context, ck)
                && equal(row.sourceKey, [ck, data.sequence]) && equal(key, [ck, data.sequence, "fixture"]), "outbox-schema");
              const intent = object(data.intent); exact(intent, ["version", "kind", "marker"]);
              invariant(intent.version === 1 && intent.kind === "inert-fixture", "outbox-version"); string(intent.marker);
              invariant(sequences.get(canonical(ck))?.includes(integer(data.sequence)), "outbox-dependency");
              plus(totals, "outbox", 1); plus(totals, "pendingBytes", row.bytes);
              const sourceKey = [ck, data.sequence], expectedNonce = string(data.nonce), expectedIntent = canonical(intent);
              return () => w.read("attempts", sourceKey, source => {
                invariant(source, "outbox-source-missing"); validateAttempt(source, fixture);
                invariant(source.state === "committed" && source.nonce === expectedNonce
                  && canonical(object(source.command).fixture) === expectedIntent, "outbox-source-mismatch");
                return next;
              });
            }
            if (store === "recovery") fail("recovery-not-supported-in-first-unit");
            return next;
          });
        }, () => storeAt(index + 1));
      }
      storeAt(0);
    });
    if (run.kind !== "complete") return outcome(run);
    databaseId = run.value; ready = true; return Object.freeze({ kind: "open" });
  }
  return Object.freeze({
    audit, createContext, advanceEpoch, admit: (raw: string) => admitInternal(raw, false), prepare, resolve, apply, observe, discover, snapshot,
    close() {
      closed = true; ready = false;
      for (const job of [...ownedJobs]) job.cancel();
      for (const state of [...admitted]) {
        if (!state.started) state.terminal = Object.freeze({ kind: "prepare-aborted", reason: "closed-before-prepare" });
        release(state);
      }
      port.close();
    },
    // This capability is removed from the public native factory's returned object.
    fixtureAdmit: fixture ? (raw: string) => admitInternal(raw, true) : undefined,
  });
}
function errorReason(error: unknown): string { return error instanceof Error ? error.message : "unknown-error"; }

function nativeNonce(): string {
  const data = new Uint8Array(32); globalThis.crypto.getRandomValues(data);
  return Array.from(data, x => x.toString(16).padStart(2, "0")).join("");
}
function nativePort(db: IDBDatabase): DataTransactionPort {
  let closed = false;
  const active = new Set<() => void>();
  const shut = () => { if (closed) return; closed = true; db.close(); for (const unknown of [...active]) unknown(); };
  db.onversionchange = shut; db.onclose = shut;
  return {
    identity: nativeIdentity,
    close: shut,
    run(mode, stores, body, events) {
      if (closed) { events.unknown("connection-closed"); return () => {}; }
      let transaction: IDBTransaction;
      try { transaction = mode === "readwrite" ? db.transaction([...stores], mode, { durability: "strict" }) : db.transaction([...stores], mode); }
      catch { events.unknown("transaction-unavailable"); return () => {}; }
      let ended = false, abortRequested = false, entered = false, reason = "transaction-aborted";
      const finish = (kind: "complete" | "abort" | "unknown", unknownReason = "connection-closed") => {
        if (ended) return; ended = true; active.delete(unknown);
        if (kind === "complete") events.complete(); else if (kind === "abort") events.abort(reason); else events.unknown(unknownReason);
      };
      const unknown = () => finish("unknown"); active.add(unknown);
      const abort = (why: string) => {
        if (ended || abortRequested) return;
        abortRequested = true; reason = why; // Preserve first cause across queued AbortError events.
        try { transaction.abort(); } catch { finish("unknown", "abort-unavailable"); }
        // A successful abort request waits for onabort; request errors are not terminal proof.
      };
      const firstRequestEvent = (): boolean => {
        if (ended || abortRequested) return false;
        if (!entered) { entered = true; events.entered(); }
        return true;
      };
      const guard = (f: () => unknown) => {
        if (ended || abortRequested) return;
        try { const result = f(); if (result && typeof (result as { then?: unknown }).then === "function") abort("async-transaction-callback"); }
        catch (e) { abort(errorReason(e)); }
      };
      transaction.oncomplete = () => finish("complete");
      transaction.onabort = () => finish("abort");
      transaction.onerror = () => { if (!ended && !abortRequested) reason = transaction.error?.name ?? "request-failed"; };
      const onRequest = <T>(request: IDBRequest<T>, receive: (result: T) => void, cursor = false) => {
        request.onsuccess = () => {
          if (!firstRequestEvent()) return;
          if (!cursor) { request.onsuccess = null; request.onerror = null; }
          guard(() => receive(request.result));
        };
        request.onerror = () => { if (firstRequestEvent()) abort(request.error?.name ?? "request-failed"); };
      };
      const tx: DataPortTransaction = {
        abort,
        get(store, key, receive) { guard(() => onRequest(transaction.objectStore(store).get(key as IDBValidKey), receive)); },
        put(store, row) { guard(() => onRequest(transaction.objectStore(store).put(row), () => {})); },
        delete(store, key) { guard(() => onRequest(transaction.objectStore(store).delete(key as IDBValidKey), () => {})); },
        keys(store, index, match, receive, end) {
          guard(() => {
            const source = index ? transaction.objectStore(store).index(index) : transaction.objectStore(store);
            const request = source.openKeyCursor(match === null ? null : IDBKeyRange.only(match as IDBValidKey));
            onRequest(request, cursor => {
              if (!cursor) { end(); return; }
              let advanced = false;
              receive(cursor.primaryKey as Key, () => {
                invariant(!advanced, "cursor-double-advance"); advanced = true; cursor.continue();
              });
            }, true);
          });
        },
      };
      guard(() => body(tx));
      return () => { if (!entered) abort("entry-timeout"); };
    },
  };
}

/** Opens only when explicitly called; allowCreate is a lifecycle decision, never a pure read. */
export async function openBrowserDataTransactions(options: Options & { allowCreate: boolean }): Promise<
  { kind: "open"; plane: Omit<BrowserDataTransactions, "fixtureAdmit" | "audit"> } | { kind: "unavailable"; reason: string }
> {
  let db: IDBDatabase | undefined;
  try {
    db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = globalThis.indexedDB.open(DATA_DB_NAME, 1);
      let abandoned = false;
      request.onblocked = () => { abandoned = true; reject(new Error("upgrade-blocked")); };
      request.onerror = () => reject(request.error ?? new Error("open-failed"));
      request.onupgradeneeded = event => {
        try {
          invariant(options.allowCreate && event.oldVersion === 0, "creation-not-authorized");
          for (const store of STORES) {
            const objectStore = request.result.createObjectStore(store, { keyPath: "key" });
            objectStore.createIndex("context", "context");
            objectStore.createIndex("nonceKey", "nonceKey", { unique: store === "attempts" });
            objectStore.createIndex("sourceKey", "sourceKey");
          }
          request.transaction!.objectStore("meta").put(pack(META_KEY, [], emptyMeta(nativeNonce())));
        } catch { request.transaction?.abort(); }
      };
      request.onsuccess = () => { if (abandoned) request.result.close(); else resolve(request.result); };
    });
    invariant([...db.objectStoreNames].sort().join("|") === [...STORES].sort().join("|"), "unknown-schema");
    const schema = db.transaction([...STORES], "readonly");
    for (const name of STORES) {
      const store = schema.objectStore(name);
      invariant(store.keyPath === "key" && !store.autoIncrement
        && [...store.indexNames].sort().join("|") === "context|nonceKey|sourceKey", "unknown-schema");
      for (const indexName of ["context", "nonceKey", "sourceKey"]) {
        const index = store.index(indexName);
        invariant(index.keyPath === indexName && !index.multiEntry
          && index.unique === (name === "attempts" && indexName === "nonceKey"), "unknown-index");
      }
    }
    const plane = createCore(nativePort(db), options, nativeNonce, nativeClock, false);
    const checked = await plane.audit();
    if (checked.kind !== "open") { plane.close(); return { kind: "unavailable", reason: checked.reason ?? "audit-failed" }; }
    const { fixtureAdmit: _fixture, audit: _audit, ...publicPlane } = plane;
    return { kind: "open", plane: Object.freeze(publicPlane) };
  } catch (e) { db?.close(); return { kind: "unavailable", reason: errorReason(e) }; }
}

/** Synthetic ports only. The fixture outbox capability is absent from the native factory. */
export const browserDataTransactionFixtures = Object.freeze({
  /** Test-only exposure of the SAME adapter; the injected DB object is never opened here. */
  nativeAdapter(db: IDBDatabase): DataTransactionPort { return nativePort(db); },
  initialRow(databaseId = "0".repeat(64)): unknown { return pack(META_KEY, [], emptyMeta(databaseId)); },
  create(port: DataTransactionPort, options: Options, random: () => string, clock: DataClock): BrowserDataTransactions {
    return createCore(port, options, random, clock, true);
  },
});
