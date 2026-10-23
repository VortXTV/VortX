/**
 * PREPARATION ONLY: unwired M1. No initializer, migration, cleanup, export or app callers.
 * Reads have no write side effects. All cooperating writes use the same origin Web Lock.
 * A finite chain and retained-record ceiling are NOT a sustained-playback retention policy.
 */
export const M1_NAMESPACE = "vortx.web.storage.m1.v3.";
export const M1_AUTHORITY = M1_NAMESPACE + "authority";
export const M1_RECORD = M1_NAMESPACE + "record.";
export const M1_LOCK = "vortx.web.storage.writer";
export const M1_LIMITS = Object.freeze({
  keyUnits: 4096, slots: 4096, authorityBytes: 16 * 1024,
  projectionBytes: 4 * 1024 * 1024, changedSlots: 128, batchBytes: 512 * 1024,
  chainBatches: 128, chainBytes: 2 * 1024 * 1024,
  retainedRecords: 512, retainedBytes: 8 * 1024 * 1024,
  readAttempts: 2, queuedJobs: 32, queuedBytes: 2 * 1024 * 1024,
  waitMs: 10_000, recoveryBytes: 2 * 1024 * 1024, enumerationSlots: 4096,
});
type Limits = { [K in keyof typeof M1_LIMITS]: number };
export interface M1Identity { readonly owner: string; readonly session: string; readonly native: string | null }
export interface M1Storage {
  readonly length: number;
  key(index: number): string | null;
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}
export interface M1Locks {
  run<T>(signal: AbortSignal, body: () => T): Promise<T>;
}
export interface M1Clock {
  now(): number;
  later(milliseconds: number, callback: () => void): () => void;
}
export interface M1Draft {
  get(key: string): string | null;
  keys(): readonly string[];
  set(key: string, value: string): void;
  remove(key: string): void;
  advanceEpoch(): void;
}
export interface M1SnapshotReceipt { readonly kind: "m1-snapshot" }
export interface M1CommitReceipt { readonly kind: "m1-commit"; readonly operation: string }
export interface M1Attempt { readonly kind: "m1-attempt"; readonly operation: string }
type Code = "uninitialized" | "unsupported_lock" | "busy" | "aborted" | "conflict" |
  "retired" | "invalid_receipt" | "invalid_attempt" | "invalid" | "future_version" |
  "over_budget" | "storage_unavailable" | "quota_exceeded" | "callback" |
  "async_callback" | "revoked_draft" | "id_collision" | "pending";
export type M1Read =
  | { state: "ready"; epoch: string; entries: ReadonlyArray<readonly [string, string]>; receipt: M1SnapshotReceipt }
  | { state: "blocked"; code: Code };
export type M1Outcome =
  | { state: "committed"; attempt: M1Attempt; receipt: M1CommitReceipt }
  | { state: "unchanged"; attempt: M1Attempt }
  | { state: "noncommit"; code: Code; attempt?: M1Attempt }
  | { state: "pending"; code: Code; attempt: M1Attempt };

type Epoch = [string, string];
type Row = [string, string, string];
type Change = [string, string | null];
type Authority = {
  version: 3; kind: "authority"; publication: string; operation: string;
  parent: string | null; checkpoint: string; head: string | null;
  generation: number; epochs: Epoch[];
};
type Checkpoint = {
  version: 3; kind: "checkpoint"; id: string; authority: Authority;
  provenance: "synthetic-m1"; rows: Row[];
};
type Batch = {
  version: 3; kind: "batch"; id: string; authority: Authority;
  previous: string; identity: M1Identity; sourceEpoch: string; nextEpoch: string;
  payload: string; changes: Change[];
};
type RecordValue = Checkpoint | Batch;
type Source = { authority: string; records: ReadonlyArray<readonly [string, string]> };
type View = {
  authority: Authority; source: Source; rows: Row[];
  batches: Batch[]; batchBytes: number; census: Map<string, string>; physicalBytes: number;
  names: Set<string>;
};
type Evidence = {
  before: Source; expected: string; key: string; raw: string;
  identity: M1Identity; payload: string; operation: string;
};
type CommitProof = Pick<Evidence, "expected" | "key" | "raw" | "identity" | "payload" | "operation">;
type AttemptState = { token: M1Attempt; identity: M1Identity; evidence?: Evidence; cost: number; outcome?: M1Outcome };
type Budget = { queued: number; queuedBytes: number; recovery: number };
const tabBudget: Budget = { queued: 0, queuedBytes: 0, recovery: 0 };
const bytes = (text: string): number => 2 * text.length;
class Fault extends Error {
  readonly code: Code;
  constructor(code: Code) { super(code); this.code = code; }
}
function fail(code: Code): never { throw new Fault(code); }
function errorCode(error: unknown): Code {
  if (error instanceof Fault) return error.code;
  if (error instanceof Error && (error.name === "QuotaExceededError" || error.name === "NS_ERROR_DOM_QUOTA_REACHED")) return "quota_exceeded";
  return "storage_unavailable";
}
function plain(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function shape(value: unknown, fields: readonly string[]): asserts value is Record<string, unknown> {
  if (!plain(value) || Object.keys(value).sort().join("\0") !== [...fields].sort().join("\0")) fail("invalid");
}
function text(value: unknown, max: number, empty = false): asserts value is string {
  if (typeof value !== "string" || (!empty && !value.length) || value.length > max) fail("invalid");
}
function identifier(value: unknown): asserts value is string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,80}$/.test(value)) fail("invalid");
}
function identity(value: unknown, limits: Limits): M1Identity {
  shape(value, ["owner", "session", "native"]);
  text(value.owner, limits.keyUnits); text(value.session, limits.keyUnits);
  if (value.native !== null) text(value.native, limits.keyUnits);
  const copy = Object.freeze({ owner: value.owner, session: value.session, native: value.native as string | null });
  context(copy, limits);
  return copy;
}
function context(who: Pick<M1Identity, "owner" | "native">, limits: Limits): string {
  const result = JSON.stringify([who.owner, who.native]);
  if (result.length > limits.keyUnits) fail("over_budget");
  return result;
}
function contextKey(value: unknown, limits: Limits): asserts value is string {
  text(value, limits.keyUnits);
  let parts: unknown;
  try { parts = JSON.parse(value); } catch { return fail("invalid"); }
  if (!Array.isArray(parts) || parts.length !== 2) fail("invalid");
  text(parts[0], limits.keyUnits);
  if (parts[1] !== null) text(parts[1], limits.keyUnits);
  if (JSON.stringify(parts) !== value) fail("invalid");
}
function epochRows(value: unknown, limits: Limits): Epoch[] {
  if (!Array.isArray(value) || value.length > limits.slots) fail("over_budget");
  let last: string | undefined;
  return value.map((entry) => {
    if (!Array.isArray(entry) || entry.length !== 2) fail("invalid");
    contextKey(entry[0], limits); identifier(entry[1]);
    if (last !== undefined && entry[0] <= last) fail("invalid");
    last = entry[0];
    return [entry[0], entry[1]];
  });
}
function version(value: Record<string, unknown>): void {
  if (value.version !== 3) fail(typeof value.version === "number" && value.version > 3 ? "future_version" : "invalid");
}
function authority(value: unknown, limits: Limits): Authority {
  if (plain(value)) version(value);
  shape(value, ["version", "kind", "publication", "operation", "parent", "checkpoint", "head", "generation", "epochs"]);
  if (value.kind !== "authority") fail("invalid");
  identifier(value.publication); identifier(value.operation); identifier(value.checkpoint);
  if (value.parent !== null) identifier(value.parent);
  if (value.head !== null) identifier(value.head);
  if (!Number.isSafeInteger(value.generation) || Number(value.generation) < 0) fail("invalid");
  const result: Authority = {
    version: 3, kind: "authority", publication: value.publication, operation: value.operation,
    parent: value.parent as string | null, checkpoint: value.checkpoint, head: value.head as string | null,
    generation: Number(value.generation), epochs: epochRows(value.epochs, limits),
  };
  if (bytes(JSON.stringify(result)) > limits.authorityBytes) fail("over_budget");
  return result;
}
function parse(raw: string, limit: number): unknown {
  if (bytes(raw) > limit) fail("over_budget");
  try { return JSON.parse(raw); } catch { return fail("invalid"); }
}
function parseAuthority(raw: string, limits: Limits): Authority {
  const result = authority(parse(raw, limits.authorityBytes), limits);
  if (JSON.stringify(result) !== raw) fail("invalid");
  return result;
}
function logicalKey(value: unknown, limits: Limits): asserts value is string {
  if (typeof value !== "string" || !value.length) fail("invalid");
  if (value.length > limits.keyUnits) fail("over_budget");
}
function projection(rows: Row[], epochs: Epoch[], limits: Limits): void {
  if (rows.length > limits.slots) fail("over_budget");
  if (bytes(JSON.stringify({ version: 3, rows, epochs })) > limits.projectionBytes) fail("over_budget");
}
function record(raw: string, limits: Limits): RecordValue {
  const value = parse(raw, Math.max(limits.projectionBytes, limits.batchBytes));
  if (!plain(value)) fail("invalid");
  version(value);
  if (value.kind === "checkpoint") {
    if (bytes(raw) > limits.projectionBytes) fail("over_budget");
    shape(value, ["version", "kind", "id", "authority", "provenance", "rows"]);
    identifier(value.id);
    const a = authority(value.authority, limits);
    if (value.provenance !== "synthetic-m1" || a.parent !== null || a.head !== null || a.generation !== 0 ||
        a.checkpoint !== value.id || a.operation !== value.id || a.publication !== value.id) fail("invalid");
    if (!Array.isArray(value.rows) || value.rows.length > limits.slots) fail("over_budget");
    let previous: string | undefined;
    const scopes = new Set(a.epochs.map(([scope]) => scope));
    const rows: Row[] = value.rows.map((row) => {
      if (!Array.isArray(row) || row.length !== 3) fail("invalid");
      contextKey(row[0], limits); logicalKey(row[1], limits); text(row[2], limits.projectionBytes / 2, true);
      const slot = JSON.stringify([row[0], row[1]]);
      if (!scopes.has(row[0]) || (previous !== undefined && slot <= previous)) fail("invalid");
      previous = slot;
      return [row[0], row[1], row[2]];
    });
    projection(rows, a.epochs, limits);
    const result: Checkpoint = { version: 3, kind: "checkpoint", id: value.id, authority: a, provenance: "synthetic-m1", rows };
    if (JSON.stringify(result) !== raw) fail("invalid");
    return result;
  }
  if (value.kind !== "batch") fail("invalid");
  if (bytes(raw) > limits.batchBytes) fail("over_budget");
  shape(value, ["version", "kind", "id", "authority", "previous", "identity", "sourceEpoch", "nextEpoch", "payload", "changes"]);
  identifier(value.id); identifier(value.sourceEpoch); identifier(value.nextEpoch);
  text(value.previous, limits.authorityBytes / 2); text(value.payload, limits.batchBytes / 2, true);
  const a = authority(value.authority, limits), prior = parseAuthority(value.previous, limits), who = identity(value.identity, limits);
  if (a.operation !== value.id || a.publication !== value.id || a.head !== value.id || a.parent !== prior.publication ||
      a.generation !== prior.generation + 1 || a.checkpoint !== prior.checkpoint) fail("invalid");
  if (!Array.isArray(value.changes) || !value.changes.length || value.changes.length > limits.changedSlots) fail("over_budget");
  let previous: string | undefined;
  const changes: Change[] = value.changes.map((change) => {
    if (!Array.isArray(change) || change.length !== 2) fail("invalid");
    logicalKey(change[0], limits);
    if (change[1] !== null) text(change[1], limits.batchBytes / 2, true);
    if (previous !== undefined && change[0] <= previous) fail("invalid");
    previous = change[0];
    return [change[0], change[1]];
  });
  const scope = context(who, limits), epochs = new Map(prior.epochs);
  if (epochs.get(scope) !== value.sourceEpoch) fail("invalid");
  if (value.nextEpoch !== value.sourceEpoch && value.nextEpoch !== value.id) fail("invalid");
  epochs.set(scope, value.nextEpoch);
  if (JSON.stringify([...epochs].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)) !== JSON.stringify(a.epochs)) fail("invalid");
  const result: Batch = {
    version: 3, kind: "batch", id: value.id, authority: a, previous: value.previous,
    identity: who, sourceEpoch: value.sourceEpoch, nextEpoch: value.nextEpoch,
    payload: value.payload, changes,
  };
  if (JSON.stringify(result) !== raw) fail("invalid");
  return result;
}
function sameIdentity(a: M1Identity, b: M1Identity): boolean {
  return a.owner === b.owner && a.session === b.session && a.native === b.native;
}
function sameSource(a: Source, b: Source): boolean {
  return a.authority === b.authority && a.records.length === b.records.length &&
    a.records.every(([key, raw], index) => b.records[index][0] === key && b.records[index][1] === raw);
}
function sortedRows(values: Map<string, Row>): Row[] {
  return [...values].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([, row]) => row);
}
function slot(scope: string, key: string): string { return JSON.stringify([scope, key]); }
function differences(original: Map<string, string>, next: Map<string, string>): Change[] {
  return [...new Set([...original.keys(), ...next.keys()])].sort()
    .filter((key) => original.get(key) !== next.get(key)).map((key) => [key, next.get(key) ?? null]);
}
function census(storage: M1Storage, limits: Limits): { raws: Map<string, string>; size: number; names: Set<string> } {
  const length = storage.length;
  if (!Number.isSafeInteger(length) || length < 0) fail("invalid");
  if (length > limits.enumerationSlots) fail("over_budget");
  const raws = new Map<string, string>(), names = new Set<string>(); let size = 0;
  for (let index = 0; index < length; index++) {
    const key = storage.key(index);
    if (key === null || names.has(key)) fail("conflict");
    names.add(key);
    if (!key.startsWith(M1_NAMESPACE)) continue;
    if (key !== M1_AUTHORITY) {
      if (!key.startsWith(M1_RECORD)) fail("invalid");
      identifier(key.slice(M1_RECORD.length));
    }
    const raw = storage.getItem(key);
    if (raw === null) fail("conflict");
    size += bytes(key) + bytes(raw);
    if (raws.size + 1 > limits.retainedRecords || size > limits.retainedBytes) fail("over_budget");
    raws.set(key, raw);
  }
  if (storage.length !== length) fail("conflict");
  return { raws, size, names };
}
function stableCensus(storage: M1Storage, all: ReturnType<typeof census>): boolean {
  if (storage.length !== all.names.size) return false;
  const seen = new Set<string>();
  for (let index = 0; index < all.names.size; index++) {
    const key = storage.key(index);
    if (key === null || seen.has(key) || !all.names.has(key)) return false;
    seen.add(key);
    if (key.startsWith(M1_NAMESPACE) && storage.getItem(key) !== all.raws.get(key)) return false;
  }
  return storage.length === all.names.size;
}
function stable(storage: M1Storage, source: Source): boolean {
  for (const [key, raw] of source.records) if (storage.getItem(key) !== raw) return false;
  return storage.getItem(M1_AUTHORITY) === source.authority;
}
function readOnce(storage: M1Storage, limits: Limits): View {
  const initial = storage.getItem(M1_AUTHORITY);
  if (initial === null) fail("uninitialized");
  const a = parseAuthority(initial, limits), all = census(storage, limits);
  if (all.raws.get(M1_AUTHORITY) !== initial) fail("conflict");
  // Orphans count toward retention and future/damaged records cannot be silently ignored.
  const decoded = new Map<string, RecordValue>();
  for (const [key, raw] of all.raws) if (key !== M1_AUTHORITY) {
    const r = record(raw, limits);
    if (key !== M1_RECORD + r.id) fail("invalid");
    decoded.set(key, r);
  }
  const backwards: Batch[] = [], seen = new Set<string>();
  let cursor = a, chainBytes = 0;
  while (cursor.head !== null) {
    if (seen.has(cursor.head)) fail("invalid");
    seen.add(cursor.head);
    if (seen.size > limits.chainBatches) fail("over_budget");
    const key = M1_RECORD + cursor.head, raw = all.raws.get(key), r = decoded.get(key);
    if (!raw || !r || r.kind !== "batch" || JSON.stringify(r.authority) !== JSON.stringify(cursor)) fail("invalid");
    chainBytes += bytes(raw);
    if (chainBytes > limits.chainBytes) fail("over_budget");
    backwards.push(r); cursor = parseAuthority(r.previous, limits);
  }
  const checkpointKey = M1_RECORD + a.checkpoint, checkpoint = decoded.get(checkpointKey);
  if (!checkpoint || checkpoint.kind !== "checkpoint" || seen.has(checkpoint.id) ||
      JSON.stringify(checkpoint.authority) !== JSON.stringify(cursor)) fail("invalid");
  const values = new Map(checkpoint.rows.map((row) => [slot(row[0], row[1]), row] as const));
  const batches = backwards.reverse();
  const sources: Array<readonly [string, string]> = [[checkpointKey, all.raws.get(checkpointKey)!]];
  let previous = checkpoint.authority;
  for (const batch of batches) {
    if (batch.previous !== JSON.stringify(previous)) fail("invalid");
    const scope = context(batch.identity, limits);
    for (const [key, value] of batch.changes) {
      const previousValue = values.get(slot(scope, key));
      if (value === null ? previousValue === undefined : previousValue?.[2] === value) fail("invalid");
      if (value === null) values.delete(slot(scope, key)); else values.set(slot(scope, key), [scope, key, value]);
    }
    projection(sortedRows(values), batch.authority.epochs, limits);
    sources.push([M1_RECORD + batch.id, all.raws.get(M1_RECORD + batch.id)!]);
    previous = batch.authority;
  }
  const rows = sortedRows(values);
  projection(rows, a.epochs, limits);
  const source = { authority: initial, records: sources };
  if (!stableCensus(storage, all) || !stable(storage, source)) fail("conflict");
  return { authority: a, source, rows, batches, batchBytes: chainBytes, census: all.raws, physicalBytes: all.size, names: all.names };
}
function readView(storage: M1Storage, limits: Limits): View {
  for (let attempt = 0; attempt < limits.readAttempts; attempt++) {
    try { return readOnce(storage, limits); }
    catch (error) { if (!(error instanceof Fault) || error.code !== "conflict" || attempt + 1 === limits.readAttempts) throw error; }
  }
  return fail("conflict");
}
/** No navigator/localStorage access occurs at import or factory construction. */
export function platformM1Locks(): M1Locks {
  return { async run<T>(signal: AbortSignal, body: () => T): Promise<T> {
    const locks = typeof navigator === "undefined" ? undefined : navigator.locks;
    if (!locks || typeof locks.request !== "function") fail("unsupported_lock");
    let entered = false;
    try {
      return await locks.request(M1_LOCK, { mode: "exclusive", signal }, (lock) => {
        if (!lock) return fail("unsupported_lock");
        entered = true;
        return body();
      });
    } catch (error) {
      if (entered || error instanceof Fault) throw error;
      if (signal.aborted) return fail("aborted");
      return fail("unsupported_lock");
    }
  } };
}
const platformClock: M1Clock = {
  now: () => Date.now(),
  later: (milliseconds, callback) => { const timer = setTimeout(callback, milliseconds); return () => clearTimeout(timer); },
};
function freshId(): string {
  if (typeof crypto === "undefined" || typeof crypto.randomUUID !== "function") return fail("storage_unavailable");
  return crypto.randomUUID();
}
interface Dependencies {
  storage: () => M1Storage;
  current: () => M1Identity;
  locks: M1Locks;
  clock: M1Clock;
  id: () => string;
}
function makePlane(deps: Dependencies, limits: Limits, budget: Budget) {
  const snapshots = new WeakMap<M1SnapshotReceipt, { identity: M1Identity; epoch: string; source: Source }>();
  const attempts = new WeakMap<M1Attempt, AttemptState>();
  const commits = new WeakMap<M1CommitReceipt, CommitProof>();
  const pending = new Set<AttemptState>(); // Only unresolved bounded evidence has a strong retention root.
  function live(who: M1Identity): boolean {
    try { return sameIdentity(identity(deps.current(), limits), who); } catch { return false; }
  }
  function capture(): M1Read {
    try {
      const who = identity(deps.current(), limits), view = readView(deps.storage(), limits);
      const scope = context(who, limits), epoch = new Map(view.authority.epochs).get(scope);
      if (!epoch || !live(who)) fail("retired");
      const receipt: M1SnapshotReceipt = Object.freeze({ kind: "m1-snapshot" });
      snapshots.set(receipt, { identity: who, epoch, source: view.source });
      const entries = Object.freeze(view.rows.filter(([owner]) => owner === scope)
        .map(([, key, value]) => Object.freeze([key, value] as const)));
      return { state: "ready", epoch, entries, receipt };
    } catch (error) { return { state: "blocked", code: errorCode(error) }; }
  }
  function finish(state: AttemptState, outcome: M1Outcome): M1Outcome {
    budget.recovery -= state.cost; state.cost = 0; state.evidence = undefined;
    pending.delete(state); state.outcome = Object.freeze(outcome);
    return state.outcome;
  }
  function unresolved(state: AttemptState, code: Code = "pending"): M1Outcome {
    if (state.outcome) return state.outcome;
    pending.add(state);
    return { state: "pending", code, attempt: state.token };
  }
  function acknowledge(state: AttemptState): M1Outcome {
    const evidence = state.evidence!;
    const receipt: M1CommitReceipt = Object.freeze({ kind: "m1-commit", operation: state.token.operation });
    // Historical proof reuses immutable strings; do not retain the unfinished before Source.
    commits.set(receipt, { expected: evidence.expected, key: evidence.key, raw: evidence.raw,
      identity: evidence.identity, payload: evidence.payload, operation: evidence.operation });
    return finish(state, { state: "committed", attempt: state.token, receipt });
  }
  function determine(state: AttemptState, noncommitCode: Code = "conflict"): M1Outcome {
    const evidence = state.evidence!;
    try {
      const view = readView(deps.storage(), limits);
      const published = view.batches.find((batch) => batch.id === evidence.operation);
      if (published) {
        const raw = view.source.records.find(([key]) => key === evidence.key)?.[1];
        if (raw === evidence.raw && JSON.stringify(published.authority) === evidence.expected &&
            published.payload === evidence.payload && sameIdentity(published.identity, evidence.identity)) {
          return acknowledge(state);
        }
        return unresolved(state, "invalid");
      }
      // A staged orphan is deliberately irrelevant. Never infer publication from record existence.
      if (sameSource(view.source, evidence.before)) return finish(state, { state: "noncommit", code: noncommitCode, attempt: state.token });
      return unresolved(state);
    } catch (error) { return state.outcome ?? unresolved(state, errorCode(error)); }
  }
  async function queued<T>(cost: number, signal: AbortSignal | undefined, work: () => T): Promise<T> {
    if (budget.queued + 1 > limits.queuedJobs || budget.queuedBytes + cost > limits.queuedBytes) fail("over_budget");
    if (signal?.aborted) fail("aborted");
    budget.queued++; budget.queuedBytes += cost;
    let entered = false, counted = true, timedOut = false;
    const controller = new AbortController(), deadline = deps.clock.now() + limits.waitMs;
    const leaveQueue = () => {
      if (counted) { counted = false; budget.queued--; budget.queuedBytes -= cost; }
    };
    const abort = () => { if (!entered) controller.abort(); };
    signal?.addEventListener("abort", abort, { once: true });
    const cancelTimer = deps.clock.later(limits.waitMs, () => { if (!entered) { timedOut = true; controller.abort(); } });
    try {
      return await deps.locks.run(controller.signal, () => {
        // Also handles a provider granting an already-aborted request before promise rejection.
        if (signal?.aborted || controller.signal.aborted || deps.clock.now() >= deadline) fail(timedOut || deps.clock.now() >= deadline ? "busy" : "aborted");
        entered = true; cancelTimer(); leaveQueue();
        return work();
      });
    } catch (error) {
      if (!entered && timedOut) fail("busy");
      if (!entered && (signal?.aborted || controller.signal.aborted)) fail("aborted");
      throw error;
    } finally { cancelTimer(); signal?.removeEventListener("abort", abort); leaveQueue(); }
  }
  async function submit(payload: string, callback: (draft: M1Draft, capturedPayload: string) => unknown,
    options: { expected?: M1SnapshotReceipt; signal?: AbortSignal } = {}): Promise<M1Outcome> {
    let state: AttemptState | undefined;
    try {
      if (typeof payload !== "string" || typeof callback !== "function") fail("invalid");
      if (bytes(payload) > limits.queuedBytes) fail("over_budget");
      const who = identity(deps.current(), limits), storage = deps.storage();
      // Admission reads only the descriptor epoch. Logical collection reads happen after lock entry.
      const raw = storage.getItem(M1_AUTHORITY);
      if (raw === null) fail("uninitialized");
      const admitted = parseAuthority(raw, limits), scope = context(who, limits);
      const epoch = new Map(admitted.epochs).get(scope);
      if (!epoch || !live(who)) fail("retired");
      const expected = options.expected === undefined ? undefined : snapshots.get(options.expected);
      if (options.expected !== undefined && (!expected || !sameIdentity(expected.identity, who))) fail("invalid_receipt");
      const operation = deps.id(); identifier(operation);
      const token: M1Attempt = Object.freeze({ kind: "m1-attempt", operation });
      state = { token, identity: who, cost: 0 }; attempts.set(token, state);
      const job = state;
      const capturedCost = bytes(JSON.stringify({ identity: who, epoch, payload,
        expected: expected?.source ?? null, operation }));
      return await queued(capturedCost, options.signal, () => {
        if (!live(who)) fail("retired");
        const view = readView(storage, limits);
        if (new Map(view.authority.epochs).get(scope) !== epoch) fail("retired");
        if (expected && !sameSource(expected.source, view.source)) fail("conflict");
        const original = new Map(view.rows.filter(([owner]) => owner === scope).map(([, key, value]) => [key, value]));
        const next = new Map(original);
        let open = true, bump = false;
        const access = (key?: string) => { if (!open) fail("revoked_draft"); if (key !== undefined) logicalKey(key, limits); };
        const edit = (key: string, value: string | null) => {
          access(key);
          if (value !== null) text(value, limits.projectionBytes / 2, true);
          if ((next.get(key) ?? null) === value) return;
          if (value !== null && bytes(value) > limits.batchBytes) fail("over_budget");
          const candidate = new Map(next);
          if (value === null) candidate.delete(key); else candidate.set(key, value);
          if (view.rows.length - original.size + candidate.size > limits.slots) fail("over_budget");
          const delta = differences(original, candidate);
          if (delta.length > limits.changedSlots || bytes(JSON.stringify(delta)) > limits.batchBytes) fail("over_budget");
          const projected = new Map(view.rows.map((row) => [slot(row[0], row[1]), row] as const));
          for (const [name, item] of delta) {
            if (item === null) projected.delete(slot(scope, name)); else projected.set(slot(scope, name), [scope, name, item]);
          }
          projection(sortedRows(projected), view.authority.epochs, limits);
          if (value === null) next.delete(key); else next.set(key, value);
        };
        const draft: M1Draft = Object.freeze({
          get: (key: string) => { access(key); return next.get(key) ?? null; },
          keys: () => { access(); return Object.freeze([...next.keys()].sort()); },
          set: (key: string, value: string) => { access(key); if (typeof value !== "string") fail("invalid"); edit(key, value); },
          remove: (key: string) => edit(key, null),
          advanceEpoch: () => { access(); bump = true; },
        });
        let returned: unknown;
        try {
          returned = callback(draft, payload);
          open = false;
          if (returned !== null && (typeof returned === "object" || typeof returned === "function") &&
              typeof (returned as { then?: unknown }).then === "function") fail("async_callback");
        } catch (error) {
          if (error instanceof Fault) throw error;
          return finish(job, { state: "noncommit", code: "callback", attempt: token });
        } finally { open = false; }
        const changes = differences(original, next);
        if (!live(who)) fail("retired");
        if (!stableCensus(storage, { raws: view.census, size: view.physicalBytes, names: view.names }) || !stable(storage, view.source)) fail("conflict");
        if (!changes.length) return finish(job, { state: "unchanged", attempt: token });
        if (changes.length > limits.changedSlots || view.batches.length + 1 > limits.chainBatches) fail("over_budget");
        const nextEpoch = bump ? operation : epoch, epochs = new Map(view.authority.epochs);
        epochs.set(scope, nextEpoch);
        const a: Authority = {
          version: 3, kind: "authority", publication: operation, operation, parent: view.authority.publication,
          checkpoint: view.authority.checkpoint, head: operation, generation: view.authority.generation + 1,
          epochs: [...epochs].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0),
        };
        const candidate: Batch = {
          version: 3, kind: "batch", id: operation, authority: a, previous: view.source.authority,
          identity: who, sourceEpoch: epoch, nextEpoch, payload, changes,
        };
        const batchRaw = JSON.stringify(candidate), authorityRaw = JSON.stringify(a), key = M1_RECORD + operation;
        record(batchRaw, limits); parseAuthority(authorityRaw, limits);
        const values = new Map(view.rows.map((row) => [slot(row[0], row[1]), row] as const));
        for (const [name, value] of changes) {
          if (value === null) values.delete(slot(scope, name)); else values.set(slot(scope, name), [scope, name, value]);
        }
        projection(sortedRows(values), a.epochs, limits);
        if (view.batchBytes + bytes(batchRaw) > limits.chainBytes) fail("over_budget");
        if (view.census.has(key) || storage.getItem(key) !== null) fail("id_collision");
        const stagedBytes = view.physicalBytes + bytes(key) + bytes(batchRaw);
        const retained = Math.max(stagedBytes, stagedBytes + bytes(authorityRaw) - bytes(view.source.authority));
        if (view.census.size + 1 > limits.retainedRecords || retained > limits.retainedBytes || storage.length + 1 > limits.enumerationSlots) fail("over_budget");
        const evidence: Evidence = { before: view.source, expected: authorityRaw, key, raw: batchRaw,
          identity: who, payload, operation };
        const recoveryCost = bytes(JSON.stringify(evidence));
        if (budget.recovery + recoveryCost > limits.recoveryBytes) fail("over_budget");
        budget.recovery += recoveryCost; job.cost = recoveryCost; job.evidence = evidence;
        let publicationAttempted = false;
        try {
          storage.setItem(key, batchRaw);
          if (storage.getItem(key) !== batchRaw) fail("conflict");
          record(batchRaw, limits); // Validate precisely the bytes just read back, not a truncated shape.
          if (!live(who) || !stable(storage, view.source)) fail("retired");
          publicationAttempted = true;
          storage.setItem(M1_AUTHORITY, authorityRaw);
          return determine(job);
        } catch (error) {
          if (publicationAttempted) return determine(job, errorCode(error));
          return finish(job, { state: "noncommit", code: errorCode(error), attempt: token });
        }
      });
    } catch (error) {
      if (state?.outcome) return state.outcome;
      if (state?.evidence) return unresolved(state, errorCode(error));
      if (state) return finish(state, { state: "noncommit", code: errorCode(error), attempt: state.token });
      return { state: "noncommit", code: errorCode(error) };
    }
  }
  async function resolve(token: M1Attempt, signal?: AbortSignal): Promise<M1Outcome> {
    const state = attempts.get(token);
    if (!state) return { state: "noncommit", code: "invalid_attempt" };
    if (state.outcome) return state.outcome;
    if (!state.evidence) return { state: "noncommit", code: "busy", attempt: token };
    if (!live(state.identity)) return unresolved(state, "retired");
    try {
      return await queued(bytes(JSON.stringify({ operation: token.operation, identity: state.identity })), signal, () => {
        if (!live(state.identity)) return unresolved(state, "retired");
        return determine(state);
      });
    } catch (error) { return state.outcome ?? unresolved(state, errorCode(error)); }
  }
  function permitsEffect(receipt: M1CommitReceipt): boolean {
    const proof = commits.get(receipt);
    if (!proof || !live(proof.identity)) return false;
    try {
      const view = readView(deps.storage(), limits), a = view.authority;
      const published = view.batches.find((batch) => batch.id === proof.operation);
      const raw = view.source.records.find(([key]) => key === proof.key)?.[1];
      if (!published || receipt.operation !== proof.operation || raw !== proof.raw ||
          JSON.stringify(published.authority) !== proof.expected || published.payload !== proof.payload ||
          !sameIdentity(published.identity, proof.identity)) return false;
      const captured = parseAuthority(proof.expected, limits), scope = context(proof.identity, limits);
      return live(proof.identity) && new Map(a.epochs).get(scope) === new Map(captured.epochs).get(scope);
    } catch { return false; }
  }
  return Object.freeze({
    capture, submit, resolve, permitsEffect,
    status: (): { state: "ready" | "blocked"; code?: Code } => {
      const result = capture(); return result.state === "ready" ? { state: "ready" } : { state: "blocked", code: result.code };
    },
  });
}
export function createBrowserStoragePlaneM1(current: () => M1Identity) {
  return makePlane({ storage: () => localStorage, current, locks: platformM1Locks(), clock: platformClock, id: freshId }, M1_LIMITS, tabBudget);
}
/** Saved fixtures only. Production construction cannot override caps, clock, storage or lock adapter. */
export function createStoragePlaneM1ForFixtures(deps: Dependencies, reductions: Partial<Limits> = {}) {
  const limits = { ...M1_LIMITS, ...reductions };
  for (const key of Object.keys(limits) as (keyof Limits)[]) {
    if (!Number.isSafeInteger(limits[key]) || limits[key] < 1 || limits[key] > M1_LIMITS[key]) fail("invalid");
  }
  return makePlane(deps, limits, { queued: 0, queuedBytes: 0, recovery: 0 });
}
