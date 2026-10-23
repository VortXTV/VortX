// VortX login + sync client (the webapp port of the website/app vault).
//
// ZERO-KNOWLEDGE MODEL
// --------------------
// Email + password + username, end to end encrypted. The password derives the account key on THIS
// device (PBKDF2-SHA256, 210k iterations), so the server (api.vortx.tv) and any future self-hosted
// node only ever see:
//   - an "auth verifier" (a one-iteration PBKDF2 of the master key, used to prove you know the
//     password without revealing it or the master key),
//   - "wrapped keys" (the random per-account data key, AES-GCM-encrypted under the master key and,
//     separately, under a recovery key), and
//   - opaque ciphertext (the synced backup document).
// The plaintext password, master key, recovery code, and data key NEVER leave this tab. The server
// cannot read the synced data: it stores only ciphertext and the wrapped keys, which are useless
// without the password (or the recovery code).
//
// INTEROP: the crypto here is byte-for-byte identical to the Apple app's CryptoKit code, the Tauri
// desktop client, and the website (vortx-site/src/lib/vault.ts), and is verified by the Worker's
// cloudflare/e2e-test.mjs. The API base, the iteration count, the PBKDF2 / AES-GCM parameters, and
// the wire shapes must stay in lockstep across all of them, so accounts created on one surface sign
// in on every other. Do NOT change API, ITERS, the KDF, or the seal/open framing in isolation.

const API = "https://api.vortx.tv";
const ITERS = 210_000;
const te = new TextEncoder();
const td = new TextDecoder();
const enc = (s: string): Uint8Array => te.encode(s);

/** base64-encode raw bytes (used for salts, wrapped keys, verifiers, ciphertext on the wire). */
function b64(u8: Uint8Array): string {
  let s = "";
  for (const b of u8) s += String.fromCharCode(b);
  return btoa(s);
}
/** base64-decode back to raw bytes. */
function unb64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** PBKDF2-SHA256 -> 256-bit key. The single key-stretching primitive: master key (password+kdfSalt),
 *  recovery key (recoveryCode+kdfSalt), and the 1-iteration auth/rec verifiers all go through here. */
async function pbkdf2(ikm: Uint8Array, salt: Uint8Array, iters: number): Promise<Uint8Array> {
  const km = await crypto.subtle.importKey("raw", ikm as BufferSource, "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt: salt as BufferSource, iterations: iters, hash: "SHA-256" },
    km,
    256,
  );
  return new Uint8Array(bits);
}

/** AES-GCM seal: random 12-byte IV prepended to the ciphertext (iv||ct), base64. The wrap/encrypt
 *  framing every surface agrees on. */
async function seal(key: Uint8Array, pt: Uint8Array): Promise<string> {
  const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, k, pt as BufferSource));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv, 0);
  out.set(ct, 12);
  return b64(out);
}

/** AES-GCM open: split iv||ct, decrypt. Returns null on any failure (wrong key, tamper), so callers
 *  can treat "could not unlock" as a clean, expected outcome rather than a thrown crypto error. */
async function open(key: Uint8Array, ciphertext: string): Promise<Uint8Array | null> {
  try {
    const comb = unb64(ciphertext);
    const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["decrypt"]);
    return new Uint8Array(
      await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: comb.subarray(0, 12) as BufferSource },
        k,
        comb.subarray(12) as BufferSource,
      ),
    );
  } catch {
    return null;
  }
}

// --- Sync-document sealing with version binding (rollback protection). Mirrors the app
//     (VortXSyncCrypto.sealDocument/openDocument) and vortx-site vault.ts byte-for-byte: the sync `document`
//     (ONLY, never the wrapped keys) binds (accountId, version) as AES-GCM additionalData, so a storage
//     backend that lacks the data key still cannot replay an old ciphertext under a fabricated higher version
//     (silent account rollback). A "v2." prefix marks the new format; legacy (bare base64, no AAD) docs still
//     open. The Worker stores `document` opaquely and already echoes the authentic version, so it needs no
//     change. MIGRATION: ship dual-READ on EVERY client first (app, vortx-site dashboard, AND this webapp),
//     then flip WRITE_SYNC_DOC_V2 to true IN LOCKSTEP across all three plus the app's writeSyncDocV2 once
//     every client can read v2 - a v2 doc is unreadable by an older client. ---
const DOC_V2_PREFIX = "v2.";
const WRITE_SYNC_DOC_V2 = false;
/** AAD binding a sync document to its account + version. IDENTICAL construction on every surface. */
function documentAAD(accountId: string, version: number): Uint8Array {
  return enc(`vortx/sync-doc/v2\n${accountId}\n${version}`);
}
/** Seal the sync doc. writeV2 binds (accountId, version) and marks "v2."; otherwise legacy no-AAD format. */
async function sealDocument(dataKey: Uint8Array, pt: Uint8Array, accountId: string, version: number, writeV2: boolean): Promise<string> {
  if (!writeV2) return seal(dataKey, pt);
  const k = await crypto.subtle.importKey("raw", dataKey as BufferSource, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: documentAAD(accountId, version) as BufferSource }, k, pt as BufferSource));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv, 0);
  out.set(ct, 12);
  return DOC_V2_PREFIX + b64(out);
}
/** Open a sync doc of either format. A "v2." blob MUST authenticate against (accountId, version); a replay
 *  under a different version or a stripped/forged prefix fails the GCM tag and returns null. */
async function openDocument(dataKey: Uint8Array, stored: string, accountId: string, version: number): Promise<Uint8Array | null> {
  if (!stored.startsWith(DOC_V2_PREFIX)) return open(dataKey, stored);
  try {
    const comb = unb64(stored.slice(DOC_V2_PREFIX.length));
    const k = await crypto.subtle.importKey("raw", dataKey as BufferSource, "AES-GCM", false, ["decrypt"]);
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: comb.subarray(0, 12) as BufferSource, additionalData: documentAAD(accountId, version) as BufferSource }, k, comb.subarray(12) as BufferSource));
  } catch {
    return null;
  }
}

// H-1 downgrade ratchet + H-2 version high-water floor, per account, in localStorage (mirrors the app).
// H-1: once this account has been seen as v2, a bare-legacy blob is tamper (a legacy blob authenticates at
// ANY version, so a downgrade replay would otherwise defeat the version binding). H-2: a pulled doc whose
// version is below the highest this device has seen for the account is a stale replay and must not become a
// merge base. Both are keyed by accountId so they follow the signed-in account; dormant until v2 exists.
function sawV2(accountId: string): boolean {
  return localStorage.getItem("vortx.sawV2." + accountId) === "1";
}
function markSawV2(accountId: string): void {
  localStorage.setItem("vortx.sawV2." + accountId, "1");
}
function syncFloor(accountId: string): number {
  return Number(localStorage.getItem("vortx.syncVer." + accountId) || "0");
}
function bumpSyncFloor(accountId: string, version: number): void {
  if (version > syncFloor(accountId)) localStorage.setItem("vortx.syncVer." + accountId, String(version));
}

// A destructive reset retains the account ID but mints a different key. Only a successful reset
// authorizes a separate ratchet namespace. Ordinary login/QR/recovery never lower legacy floors.
const resetSyncGenerationProofs = new Map<string, string>();
async function syncGenerationID(session: Session): Promise<string> {
  const domain = enc("vortx/reset-sync-generation/v1\n" + session.account.id + "\n");
  const material = new Uint8Array(domain.length + session.dataKey.length);
  material.set(domain); material.set(session.dataKey, domain.length);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", material));
  return session.account.id + ".key." + Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
function syncGenerationProofText(session: Session, generation: string): string {
  return "vortx/accepted-reset-sync-generation/v1\n" + session.account.id + "\n" + generation;
}
async function authorizeResetSyncGeneration(session: Session): Promise<void> {
  const generation = await syncGenerationID(session);
  const proof = await seal(session.dataKey, enc(syncGenerationProofText(session, generation)));
  resetSyncGenerationProofs.set(generation, proof);
  try { localStorage.setItem("vortx.syncGeneration.v1." + generation, proof); } catch { /* this tab retains the accepted proof */ }
}
async function syncRatchetAccount(session: Session): Promise<string> {
  const generation = await syncGenerationID(session);
  let proof = resetSyncGenerationProofs.get(generation);
  try { proof = localStorage.getItem("vortx.syncGeneration.v1." + generation) ?? proof; } catch { /* use this tab's accepted proof */ }
  if (!proof) return session.account.id;
  const plaintext = await open(session.dataKey, proof);
  return plaintext && td.decode(plaintext) === syncGenerationProofText(session, generation) ? generation : session.account.id;
}

// Exported ONLY for the in-repo crypto test (vault.crypto.test.mjs) so it exercises the REAL functions rather
// than a re-implementation. Not part of the app's public API; do not import elsewhere.
export const __syncCryptoTestHooks = { documentAAD, sealDocument, openDocument, DOC_V2_PREFIX, sawV2, markSawV2, syncFloor, bumpSyncFloor };

interface ApiResult {
  status: number;
  // The server replies with assorted JSON shapes per endpoint; callers narrow what they read.
  data: Record<string, unknown> | null;
}

/** Thin fetch wrapper for the JSON API. Adds the bearer token + content-type when relevant, and
 *  decodes the JSON body (skipping it on 204 / non-JSON responses). */
async function api(
  path: string,
  opts: { method?: string; body?: unknown; token?: string; headers?: Record<string, string>; signal?: AbortSignal } = {},
): Promise<ApiResult> {
  const headers: Record<string, string> = { ...opts.headers };
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  if (opts.token) headers.authorization = "Bearer " + opts.token;
  const controller = new AbortController();
  const cancel = () => controller.abort();
  opts.signal?.addEventListener("abort", cancel, { once: true });
  if (opts.signal?.aborted) controller.abort();
  const deadline = setTimeout(cancel, 15_000);
  try {
    const res = await fetch(API + path, {
      method: opts.method ?? "GET",
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      signal: controller.signal,
    });
    let data: Record<string, unknown> | null = null;
    if (res.status !== 204 && res.headers.get("content-type")?.includes("json")) {
      data = (await res.json()) as Record<string, unknown>;
    }
    return { status: res.status, data };
  } finally { clearTimeout(deadline); opts.signal?.removeEventListener("abort", cancel); }
}

/** A human-friendly but strong (128-bit) recovery code: VX-XXXX-XXXX-XXXX-XXXX-XXXX in Crockford
 *  base32. This is the only way back into encrypted data if the password is lost and no device is
 *  signed in; it is generated on-device and shown to the user exactly once. */
function makeRecoveryCode(): string {
  const A = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let bits = "";
  for (const b of bytes) bits += b.toString(2).padStart(8, "0");
  let out = "";
  for (let i = 0; i < bits.length; i += 5) out += A[parseInt(bits.slice(i, i + 5).padEnd(5, "0"), 2)];
  return "VX-" + (out.match(/.{1,4}/g) ?? []).join("-");
}

// --- Public types -------------------------------------------------------------------------------

export interface Account {
  id: string;
  email: string;
  username: string;
  usernameChangedAt?: number;
  twoFactorEnabled?: boolean;
}
/** A live session: the bearer token, the account fields, and the decrypted data key (kept only in
 *  memory + localStorage on this device; it unlocks only THIS account's synced blob). */
export interface Session {
  token: string;
  account: Account;
  dataKey: Uint8Array;
}

// --- Session authority and persistence -----------------------------------------------------------
// One realm authority. No storage mutation at import or inspection; all cooperating durable writers
// share this lock. It is not an atomic transaction across storage areas or a fence for old clients.
const SESSION_KEY = "vortx.session.v1";
const DATAKEY_KEY = "vortx.dk.v2";
const LEGACY_DATAKEY_KEY = "vortx.dk.v1";
const SESSION_LOCK = "vortx.session.writer";
type Pair = { raw: string | null; key: string | null; legacy: string | null };
type Inspection = { kind: "empty" | "owned" | "blocked" | "unavailable"; pair?: Pair; session?: Session; legacy?: boolean };
export type AuthSurface = Readonly<{ readonly surface: unique symbol }>;
export type AuthAttempt = Readonly<{ readonly attempt: unique symbol }>;
export type AuthEffect = Readonly<{ readonly effect: unique symbol }>;
export type AuthKind = "login" | "register" | "recover" | "reset" | "reset-send" | "refresh" | "approve" | "restore";
export type AuthResult = Readonly<{ status: "persisted" | "memory-only" | "not-persisted" | "retired" | "unavailable" | "uncertain"; effect?: AuthEffect }>;
type RemoteOutcome = "not-sent" | "rejected" | "unknown" | "accepted";
type Operation = {
  kind: AuthKind; surface?: AuthSurface; revision: number; before: Pair; priorOwner: Session | null; priorMode: typeof ownerMode; controller: AbortController;
  candidate?: Session; recoveryCode?: string; staged?: Pair; requestEvidence?: string; material?: { dataKey: Uint8Array; request: string };
  remote: RemoteOutcome; invoked: boolean; dispatched: boolean; used: boolean; result?: AuthResult; proofReady: boolean;
};
const surfaces = new WeakMap<AuthSurface, { live: boolean }>();
const operations = new WeakMap<AuthAttempt, Operation>();
const effects = new WeakMap<AuthEffect, { revision: number; surface?: AuthSurface }>();
const ownerListeners = new Set<(origin?: AuthAttempt) => void>();
let owner: Session | null = null;
let ownerMode: "guest" | "persisted" | "memory" | "blocked" = "guest";
let authorityRevision = 0, authorityStarted = false, observerStarted = false;
let explicitlyRetired = false, ownerPair: Pair | undefined;
let activeAttempt: AuthAttempt | undefined, commitBusy = false;
let retainedOperation: Operation | undefined;
// An uncertain local commit keeps its exact candidate/predecessor; never evict it to make room.
let uncertainCommit: Operation | undefined;
let uncertainRevision = -1;
let logoutEvidence: { pair: Pair; revision: number } | undefined;

function cloneAccount(account: Account): Account {
  // Transport/storage metadata is JSON. Copy nested unknown fields, never keep caller-owned references.
  const value = JSON.parse(JSON.stringify(account)) as Account;
  if (!value || typeof value !== "object" || Array.isArray(value) || typeof value.id !== "string" || !value.id) throw new Error("Invalid account response.");
  return value;
}
function copySession(session: Session): Session {
  if (typeof session.token !== "string" || !session.token || !(session.dataKey instanceof Uint8Array) || session.dataKey.length !== 32) throw new Error("Invalid account response.");
  return { token: session.token, account: cloneAccount(session.account), dataKey: session.dataKey.slice() };
}
function matchesSession(a: Session | null, b: Session | null): boolean {
  return !!a && !!b && a.token === b.token && a.account.id === b.account.id &&
    a.dataKey.length === b.dataKey.length && a.dataKey.every((byte, index) => byte === b.dataKey[index]);
}
function pairEqual(a: Pair | undefined, b: Pair | undefined): boolean {
  return !!a && !!b && a.raw === b.raw && a.key === b.key && a.legacy === b.legacy;
}
function encodedSessionKey(session: Session, previous?: Pair): string {
  const extras = previous?.key && previous.raw ? JSON.parse(previous.key) : {};
  return JSON.stringify({ ...extras, schemaVersion: 2, accountId: session.account.id, token: session.token, dataKey: b64(session.dataKey) });
}
function inspectSession(): Inspection {
  try {
    const raw = localStorage.getItem(SESSION_KEY);
    const key = sessionStorage.getItem(DATAKEY_KEY), legacy = sessionStorage.getItem(LEGACY_DATAKEY_KEY);
    // A changed confirmation is itself a witness; never retry past it into restored A.
    if (raw !== localStorage.getItem(SESSION_KEY)) return { kind: "unavailable" };
    const pair = { raw, key, legacy };
    if (raw === null) return key === null && legacy === null ? { kind: "empty", pair } : { kind: "blocked", pair };
    const stored = JSON.parse(raw);
    if (!stored || typeof stored.token !== "string" || !stored.token || !stored.account || typeof stored.account.id !== "string" || !stored.account.id) return { kind: "blocked", pair };
    let dataKey: string;
    if (key !== null) {
      const envelope = JSON.parse(key);
      if (envelope?.schemaVersion !== 2 || envelope.accountId !== stored.account.id || envelope.token !== stored.token || typeof envelope.dataKey !== "string") return { kind: "blocked", pair };
      dataKey = envelope.dataKey;
    } else {
      if (typeof stored.dataKey !== "string") return { kind: "blocked", pair };
      dataKey = stored.dataKey;
    }
    return { kind: "owned", pair, session: copySession({ token: stored.token, account: stored.account, dataKey: unb64(dataKey) }),
      legacy: key === null || Object.prototype.hasOwnProperty.call(stored, "dataKey") };
  } catch { return { kind: "unavailable" }; }
}
/** Compatibility reader is now PURE. Migration is an explicit guarded restore, never a read effect. */
export function loadSession(): Session | null { return inspectSession().session ?? null; }
function publishAuthority(origin?: AuthAttempt): void {
  // Authority/result already changed. A listener cannot roll back it or prevent other retirement.
  for (const listener of [...ownerListeners]) { try { listener(origin); } catch { /* nonsecret, isolated effect */ } }
}
function blockAuthority(deferNotification = false): void {
  if (ownerMode === "blocked") return;
  authorityRevision++; ownerMode = "blocked";
  if (!deferNotification) publishAuthority();
}
/** A failed ownership observation retires capabilities, even if the old bytes later return. */
function observeOwnership(valid: boolean, deferNotification = false): boolean {
  if (!valid) blockAuthority(deferNotification);
  return valid;
}
function initializeAuthority(): void {
  if (authorityStarted) return;
  authorityStarted = true;
  const read = inspectSession();
  if (read.kind === "owned") { owner = read.session!; ownerPair = read.pair; ownerMode = "persisted"; }
  else if (read.kind !== "empty") ownerMode = "blocked";
}
/** Start before async boot work. Never reinstalls on receiver restart. */
export function startSessionAuthority(): void {
  initializeAuthority();
  if (observerStarted || typeof window === "undefined") return;
  observerStarted = true;
  window.addEventListener("storage", (event: StorageEvent) => {
    if (event.key !== null && event.key !== SESSION_KEY && event.key !== DATAKEY_KEY && event.key !== LEGACY_DATAKEY_KEY) return;
    authorityRevision++; // delivered A -> B -> A still retires every older capability
    const read = inspectSession();
    if (!explicitlyRetired && read.kind === "owned") { owner = read.session!; ownerPair = read.pair; ownerMode = "persisted"; }
    else if (!explicitlyRetired) ownerMode = "blocked"; // retain known owner, not false guest
    publishAuthority();
  });
}
export function sessionOwner(): { session: Session | null; mode: typeof ownerMode; revision: number } {
  initializeAuthority();
  return { session: owner ? copySession(owner) : null, mode: ownerMode, revision: authorityRevision };
}
export function onSessionAuthority(listener: (origin?: AuthAttempt) => void): () => void { ownerListeners.add(listener); return () => ownerListeners.delete(listener); }
export function captureSessionOwnership(source: Session): () => boolean {
  initializeAuthority();
  const captured = copySession(source), revision = authorityRevision;
  return () => {
    if (revision !== authorityRevision || explicitlyRetired || ownerMode === "blocked" || !matchesSession(owner, captured) || !matchesSession(source, captured)) return false;
    const read = inspectSession();
    const valid = ownerMode === "memory" ? read.kind === "empty" : read.kind === "owned" && pairEqual(read.pair, ownerPair) && matchesSession(read.session!, captured);
    return observeOwnership(valid);
  };
}
export function createAuthSurface(): AuthSurface {
  startSessionAuthority();
  const token = Object.freeze({}) as AuthSurface; surfaces.set(token, { live: true }); return token;
}
export function retireAuthSurface(surface: AuthSurface): void {
  const state = surfaces.get(surface); if (state) state.live = false;
  const op = activeAttempt && operations.get(activeAttempt);
  if (op?.surface === surface) op.controller.abort();
}
function surfaceLive(surface?: AuthSurface): boolean { return !surface || surfaces.get(surface)?.live === true; }
function operationLive(op: Operation): boolean {
  return op.revision === authorityRevision && surfaceLive(op.surface) && !op.controller.signal.aborted;
}
function requireOperation(handle: AuthAttempt, kind?: AuthKind): Operation {
  const op = operations.get(handle);
  if (!op || (kind && op.kind !== kind) || !operationLive(op) || op.used) throw new Error("This account action has retired. Start from the current screen.");
  return op;
}
function invokeOperation(handle: AuthAttempt, kind: AuthKind): Operation {
  const op = requireOperation(handle, kind);
  if (op.invoked) throw new Error("This account operation has already started. Its original outcome is retained.");
  op.invoked = true; // claim invocation before crypto, preparation or another await
  return op;
}
export function authAttemptCurrent(handle: AuthAttempt): boolean { const op = operations.get(handle); return !!op && !op.used && operationLive(op); }
export function beginAuthAttempt(kind: AuthKind, surface?: AuthSurface): AuthAttempt {
  startSessionAuthority();
  if (!surfaceLive(surface) || commitBusy || uncertainCommit || logoutEvidence) throw new Error("An account save is unresolved. Keep this tab open.");
  const read = inspectSession();
  if (!observeOwnership(!!read.pair && (read.kind === "empty" || read.kind === "owned") && ownerMode !== "blocked")) throw new Error("Account storage is unavailable or belongs to another session.");
  // Validate this exact inspection, not a second read that could miss an already observed rival.
  if (owner && !explicitlyRetired && !observeOwnership(ownerMode === "memory" ? read.kind === "empty" :
    read.kind === "owned" && pairEqual(read.pair, ownerPair) && matchesSession(read.session!, owner))) throw new Error("Account ownership changed.");
  if (explicitlyRetired && read.kind !== "empty") throw new Error("Sign-out has not cleared this tab. Keep the existing session material intact.");
  if ((kind === "register" || kind === "recover" || kind === "reset" || kind === "approve" || kind === "reset-send") && retainedOperation) throw new Error("A previous account operation is unresolved. Do not repeat it.");
  const previous = activeAttempt && operations.get(activeAttempt);
  if (previous && !previous.used) previous.controller.abort();
  const token = Object.freeze({}) as AuthAttempt;
  const op: Operation = { kind, surface, revision: authorityRevision, before: read.pair!, controller: new AbortController(),
    priorOwner: owner ? copySession(owner) : null, priorMode: ownerMode,
    remote: "not-sent", invoked: false, dispatched: false, used: false, proofReady: kind !== "reset" };
  operations.set(token, op); activeAttempt = token;
  if (kind === "register" || kind === "recover" || kind === "reset" || kind === "approve" || kind === "reset-send") retainedOperation = op;
  return token;
}
function releaseNotSent(op: Operation): void {
  if (!op.dispatched && retainedOperation === op) retainedOperation = undefined;
}
function acceptCandidate(op: Operation, session: Session): Session {
  op.candidate = copySession(session); op.remote = "accepted";
  return copySession(op.candidate);
}
/** Nonsecret retained status; secret material stays in the original private operation. */
export function pendingAuthOperation(): { kind: AuthKind; outcome: RemoteOutcome; resumable: boolean; materialRetained: boolean; codeRetained: boolean; proofReady: boolean } | null {
  const op = retainedOperation;
  return op ? { kind: op.kind, outcome: op.remote, resumable: op.remote === "accepted" && !!op.candidate, materialRetained: !!op.material, codeRetained: !!op.recoveryCode, proofReady: op.proofReady } : null;
}
export function authTransitionFrom(origin: AuthAttempt, surface: AuthSurface): boolean {
  const op = operations.get(origin);
  return activeAttempt === origin && op?.surface === surface && !!op.result?.effect && authEffectCurrent(op.result.effect);
}
export function authEffectCurrent(effect?: AuthEffect): boolean {
  const proof = effect && effects.get(effect);
  return !!proof && proof.revision === authorityRevision && surfaceLive(proof.surface) && !!owner && captureSessionOwnership(owner)();
}
export function recoveryCodeFor(effect: AuthEffect): string | null {
  return authEffectCurrent(effect) && retainedOperation?.candidate && matchesSession(owner, retainedOperation.candidate) ? retainedOperation.recoveryCode ?? null : null;
}
export function acknowledgeRecoveryCode(effect: AuthEffect): boolean {
  if (!authEffectCurrent(effect) || !retainedOperation || !matchesSession(owner, retainedOperation.candidate ?? null)) return false;
  retainedOperation = undefined; return true;
}
function finishAdoption(op: Operation, status: "persisted" | "memory-only", pair?: Pair): AuthResult {
  owner = copySession(op.candidate!); ownerMode = status === "persisted" ? "persisted" : "memory";
  ownerPair = pair; explicitlyRetired = false; authorityRevision++; op.used = true;
  const effect = Object.freeze({}) as AuthEffect;
  effects.set(effect, { revision: authorityRevision, surface: op.surface });
  const result: AuthResult = Object.freeze({ status, effect }); op.result = result;
  if (retainedOperation === op && !op.recoveryCode) retainedOperation = undefined;
  return result; // caller publishes notifications AFTER leaving the lock
}
async function withSessionLock(work: () => AuthResult, signal?: AbortSignal): Promise<AuthResult> {
  if (commitBusy || !globalThis.navigator?.locks) return { status: "unavailable" };
  commitBusy = true;
  const controller = new AbortController(), abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) controller.abort();
  const timer = setTimeout(abort, 10_000);
  try {
    return await navigator.locks.request(SESSION_LOCK, { mode: "exclusive", signal: controller.signal }, () => {
      clearTimeout(timer); signal?.removeEventListener("abort", abort);
      return work(); // synchronous storage only: never user callback, crypto or network
    });
  } catch { return { status: signal?.aborted ? "retired" : "unavailable" }; }
  finally { clearTimeout(timer); signal?.removeEventListener("abort", abort); commitBusy = false; }
}
export async function completeAuthAttempt(handle: AuthAttempt): Promise<AuthResult> {
  const op = operations.get(handle);
  if (!op) return { status: "retired" };
  if (op.result) return op.result;
  if (!op.candidate || !op.proofReady || !operationLive(op) || op.used) return { status: "retired" };
  const candidate = copySession(op.candidate);
  // Retain same-owner envelope extras; never carry another account's unknown metadata into this owner.
  const predecessor = inspectSession();
  if (!observeOwnership(pairEqual(predecessor.pair, op.before) && (predecessor.kind === "empty" || predecessor.kind === "owned"))) return { status: "retired" };
  const sameOwner = predecessor.kind === "owned" && predecessor.session!.account.id === candidate.account.id;
  const key = encodedSessionKey(candidate, sameOwner ? op.before : undefined);
  const oldDescriptor = sameOwner && op.before.raw ? JSON.parse(op.before.raw) : {};
  delete oldDescriptor.dataKey;
  const raw = JSON.stringify({ ...oldDescriptor, token: candidate.token, account: candidate.account });
  const expected: Pair = { raw, key, legacy: op.before.legacy };
  op.staged = expected;
  let witnessedRevision: number | undefined;
  const witness = (valid: boolean): boolean => {
    if (!observeOwnership(valid, true)) witnessedRevision = authorityRevision;
    return valid;
  };
  const result = await withSessionLock(() => {
    if (!operationLive(op)) return { status: "retired" };
    if (!witness(pairEqual(inspectSession().pair, op.before))) return { status: "retired" };
    try {
      sessionStorage.setItem(DATAKEY_KEY, key);
      let stagedMatches = false;
      try {
        stagedMatches = sessionStorage.getItem(DATAKEY_KEY) === key && localStorage.getItem(SESSION_KEY) === op.before.raw &&
          sessionStorage.getItem(LEGACY_DATAKEY_KEY) === op.before.legacy;
      } catch { /* read denial is a witness; a setItem failure alone is not */ }
      if (!witness(stagedMatches) || !operationLive(op)) throw new Error("pre-publication");
      localStorage.setItem(SESSION_KEY, raw);
    } catch { /* classify from exact evidence below, not the thrown call */ }
    const after = inspectSession();
    // Our key-first intermediate can be blocked-but-coherent. Any other observed bytes retire
    // authority before compensation or a later read can hide the witness.
    witness(pairEqual(after.pair, expected) || pairEqual(after.pair, op.before) ||
      pairEqual(after.pair, { raw: op.before.raw, key, legacy: op.before.legacy }));
    if (pairEqual(after.pair, expected) && after.kind === "owned") {
      if (operationLive(op)) return finishAdoption(op, "persisted", expected);
      op.used = true; return op.result = Object.freeze({ status: "persisted" });
    }
    // Witness retirement can still compensate our exact staged slot, but never revives authority.
    const mayCompensate = operationLive(op) || (witnessedRevision !== undefined && witnessedRevision === authorityRevision &&
      surfaceLive(op.surface) && !op.controller.signal.aborted);
    if (mayCompensate && after.pair?.raw === op.before.raw && after.pair.legacy === op.before.legacy) {
      try {
        if (after.pair.key === key) {
          if (op.before.key === null) sessionStorage.removeItem(DATAKEY_KEY);
          else sessionStorage.setItem(DATAKEY_KEY, op.before.key);
        }
        if (pairEqual(inspectSession().pair, op.before)) return { status: "not-persisted" };
      } catch { /* exact predecessor is not proved */ }
    }
    uncertainCommit = op; retainedOperation ??= op; blockAuthority(true); uncertainRevision = authorityRevision;
    return { status: "uncertain" };
  }, op.controller.signal);
  // Historical result is recorded before any listener can throw or start another operation.
  if (result.status === "uncertain") op.result = Object.freeze(result);
  if (result.status === "persisted" || result.status === "uncertain" || witnessedRevision !== undefined) publishAuthority(handle);
  return result;
}
/** Explicit resolution only; no replay. A changed owner/lineage stays retained and blocked. */
export function pendingAuthPersistence(): boolean { return !!uncertainCommit; }
export async function resolveAuthPersistence(surface: AuthSurface): Promise<AuthResult> {
  const op = uncertainCommit;
  if (!op || !surfaceLive(surface) || authorityRevision !== uncertainRevision || commitBusy) return { status: "unavailable" };
  let origin: AuthAttempt | undefined;
  const result = await withSessionLock(() => {
    if (uncertainCommit !== op || authorityRevision !== uncertainRevision || !surfaceLive(surface)) return { status: "retired" };
    const read = inspectSession();
    if (read.kind === "owned" && pairEqual(read.pair, op.staged)) {
      const fresh = renewAdmission(op, surface, read.pair!);
      origin = fresh.handle; uncertainCommit = undefined;
      return finishAdoption(fresh.op, "persisted", read.pair);
    }
    if (pairEqual(read.pair, op.before)) {
      uncertainCommit = undefined;
      ownerMode = owner ? (op.before.raw === null ? "memory" : "persisted") : "guest";
      ownerPair = op.before; authorityRevision++;
      renewAdmission(op, surface, op.before);
      return { status: "not-persisted" };
    }
    return { status: "uncertain" };
  });
  publishAuthority(origin);
  return result;
}
/** Explicit local choice after a definite failed save; never inferred from a denied read. */
export function completeMemoryOnly(handle: AuthAttempt): AuthResult {
  const op = requireOperation(handle);
  if (!op.candidate || !op.proofReady || op.before.raw !== null || op.before.key !== null || op.before.legacy !== null || (op.priorMode !== "guest" && op.priorMode !== "memory")) return { status: "unavailable" };
  if (!observeOwnership(inspectSession().kind === "empty")) return { status: "unavailable" };
  const result = finishAdoption(op, "memory-only"); publishAuthority(handle); return result;
}
/** New admission shares immutable payload, never the old capability or historical outcome. */
function renewAdmission(previous: Operation, surface: AuthSurface, before: Pair): { handle: AuthAttempt; op: Operation } {
  previous.controller.abort(); // prior handles never acquire this new surface/revision
  const handle = Object.freeze({}) as AuthAttempt;
  const op: Operation = { ...previous, before, revision: authorityRevision, surface, controller: new AbortController(), used: false, result: undefined, staged: undefined };
  // Candidate/material are private immutable payloads; no old admission or historical result is retargeted.
  operations.set(handle, op); activeAttempt = handle;
  if (retainedOperation === previous) retainedOperation = op;
  return { handle, op };
}
/** Resume only an accepted candidate; unknown work has no replay or invented reconciliation path. */
export async function resumeAuthOperation(surface: AuthSurface): Promise<AuthResult> {
  const op = retainedOperation;
  if (!op || op.remote !== "accepted" || !op.candidate || !surfaceLive(surface) || uncertainCommit || commitBusy || logoutEvidence || explicitlyRetired || ownerMode === "blocked") return { status: "unavailable" };
  const samePrior = owner === null ? op.priorOwner === null : matchesSession(owner, op.priorOwner);
  if (!samePrior && !matchesSession(owner, op.candidate)) return { status: "retired" };
  const read = inspectSession();
  if (!observeOwnership(!!read.pair && (read.kind === "empty" || read.kind === "owned"))) return { status: "unavailable" };
  if (!observeOwnership(pairEqual(read.pair, op.before) || (read.kind === "owned" && matchesSession(read.session!, op.candidate)))) return { status: "retired" };
  const admittedRevision = authorityRevision, admittedAttempt = activeAttempt;
  if (!op.proofReady) { await authorizeResetSyncGeneration(op.candidate); op.proofReady = true; }
  if (retainedOperation !== op || commitBusy || uncertainCommit || logoutEvidence || explicitlyRetired || authorityRevision !== admittedRevision || activeAttempt !== admittedAttempt || !surfaceLive(surface)) return { status: "retired" };
  if (!observeOwnership(pairEqual(inspectSession().pair, read.pair))) return { status: "retired" };
  const fresh = renewAdmission(op, surface, read.pair!);
  return completeAuthAttempt(fresh.handle);
}
/** Explicit owned-legacy migration only. Inspection/load remain pure. */
export async function migrateSession(): Promise<AuthResult> {
  const read = inspectSession();
  if (!observeOwnership(!!read.pair && (read.kind === "empty" || read.kind === "owned") && ownerMode !== "blocked")) return { status: "unavailable" };
  if (owner && !explicitlyRetired && !observeOwnership(ownerMode === "memory" ? read.kind === "empty" :
    read.kind === "owned" && pairEqual(read.pair, ownerPair) && matchesSession(read.session!, owner))) return { status: "unavailable" };
  if (read.kind !== "owned" || !read.legacy) return { status: "unavailable" };
  const handle = beginAuthAttempt("restore"), op = operations.get(handle)!;
  // Never attach the first legacy candidate to a different second-read admission.
  if (!observeOwnership(pairEqual(op.before, read.pair))) return { status: "retired" };
  acceptCandidate(op, read.session!); return completeAuthAttempt(handle);
}
export async function clearSession(): Promise<AuthResult> {
  initializeAuthority();
  const before = inspectSession();
  const owned = ownerMode === "memory" ? before.kind === "empty" :
    ownerMode === "persisted" && before.kind === "owned" && pairEqual(before.pair, ownerPair) && matchesSession(owner, before.session!);
  // Retain exact original bytes until definite clearing; do not capture a rival as our logout target.
  if (!logoutEvidence && (owned || before.kind === "empty") && before.pair) logoutEvidence = { pair: before.pair, revision: authorityRevision };
  const revision = ++authorityRevision;
  owner = null; ownerMode = "guest"; ownerPair = undefined; explicitlyRetired = true;
  activeAttempt && operations.get(activeAttempt)?.controller.abort();
  publishAuthority();
  const evidence = logoutEvidence;
  if (!evidence) return { status: "unavailable" };
  evidence.revision = revision;
  const result = await withSessionLock(() => {
    if (authorityRevision !== revision || logoutEvidence !== evidence) return { status: "retired" };
    const read = inspectSession(), pair = read.pair;
    if (!pair || (pair.raw !== evidence.pair.raw && pair.raw !== null) ||
      (pair.key !== evidence.pair.key && pair.key !== null) || (pair.legacy !== evidence.pair.legacy && pair.legacy !== null)) return { status: "uncertain" };
    try {
      if (pair.raw === evidence.pair.raw) localStorage.removeItem(SESSION_KEY);
      if (localStorage.getItem(SESSION_KEY) !== null) return { status: "uncertain" };
      if (sessionStorage.getItem(DATAKEY_KEY) === evidence.pair.key) sessionStorage.removeItem(DATAKEY_KEY);
      if (sessionStorage.getItem(LEGACY_DATAKEY_KEY) === evidence.pair.legacy) sessionStorage.removeItem(LEGACY_DATAKEY_KEY);
    } catch { /* readback below can still establish a completed clear */ }
    if (inspectSession().kind !== "empty") return { status: "uncertain" };
    logoutEvidence = undefined;
    return { status: "not-persisted" };
  });
  return result;
}

/** Material is retained before dispatch; a thrown/aborted fetch or malformed success is UNKNOWN. */
async function operationRequest(handle: AuthAttempt, path: string, body: Record<string, unknown>, dataKey?: Uint8Array, recoveryCode?: string, token?: string): Promise<ApiResult> {
  const op = requireOperation(handle);
  if (op.dispatched) throw new Error("This request was already sent. Its outcome is retained; do not repeat it.");
  if (!observeOwnership(ownerMode !== "blocked" && pairEqual(inspectSession().pair, op.before))) {
    // Keep the known owner/material; a witnessed failure never grants guest authority.
    throw new Error("Account ownership changed before this request was sent.");
  }
  // No raw password/OTP is retained in the private request evidence.
  const evidence = { ...body }; delete evidence.code; delete evidence.totp;
  op.requestEvidence = JSON.stringify({ path, body: evidence });
  if (dataKey) op.material = { dataKey: dataKey.slice(), request: op.requestEvidence };
  if (recoveryCode) op.recoveryCode = recoveryCode;
  op.dispatched = true; op.remote = "unknown";
  const result = await api(path, { method: "POST", body, token, signal: op.controller.signal });
  if (definitivelyRejected(path, result)) rejectedOperation(op);
  return result;
}
function definitivelyRejected(path: string, result: ApiResult): boolean {
  // Exact documented no-write outcomes only; an unfamiliar status/body remains unknown.
  const error = result.data?.error;
  const is = (status: number, ...codes: string[]) => result.status === status && typeof error === "string" && codes.includes(error);
  switch (path) {
    case "/v1/auth/register": return is(400, "invalid_email", "invalid_username", "bad_request") || is(409, "email_taken", "username_taken");
    case "/v1/auth/recover-complete": return is(400, "bad_request") || is(401, "invalid_recovery");
    case "/v1/auth/reset/complete": return is(400, "bad_request") || is(401, "invalid_code");
    case "/v1/auth/change-password": return is(400, "bad_request") || is(401, "unauthorized", "invalid_credentials");
    case "/v1/auth/2fa/activate": return is(400, "no_pending") || is(401, "unauthorized", "invalid_code");
    case "/v1/auth/2fa/disable": return is(400, "not_enabled") || is(401, "unauthorized", "invalid_code");
    case "/v1/qr/authorize": return ([404, 409, 410].includes(result.status) && result.data === null) || is(400, "bad_request") || is(401, "unauthorized");
    default: return false;
  }
}
function rejectedOperation(op: Operation): void {
  op.remote = "rejected";
  if (retainedOperation === op) retainedOperation = undefined;
}
function acceptedAccount(data: Record<string, unknown> | null, dataKey: Uint8Array): Session {
  return copySession({ token: data?.token as string, account: data?.account as Account, dataKey });
}
function reserveManagement(op: Operation): void {
  if (retainedOperation && retainedOperation !== op) throw new Error("An account operation remains unresolved.");
  retainedOperation = op;
}

// --- Key derivation helpers ---------------------------------------------------------------------

/** The master key: stretch the password under the account's kdf salt. Unlocks the password-wrapped
 *  data key and is the basis of the auth verifier. */
async function deriveMaster(password: string, kdfSalt: string, iters: number): Promise<Uint8Array> {
  return pbkdf2(enc(password), unb64(kdfSalt), iters);
}

/** Clamp a server-supplied PBKDF2 iteration count to a safe floor. A hostile / compromised prelogin
 *  returning a tiny kdfIters would collapse key stretching and enable offline brute-force of the auth
 *  verifier, so never go below ITERS. Legit accounts are always created at ITERS; a higher server value
 *  (a future migration) is honored. Not applied to the 1-iteration verifiers, which are intentional. */
function safeIters(n: unknown): number {
  return Math.max(Number(n) || 0, ITERS);
}
/** The auth verifier: a 1-iteration PBKDF2 of the master key salted by the password. Proves password
 *  knowledge to the server without ever sending the password or the master key itself. */
async function authVerifier(masterKey: Uint8Array, password: string): Promise<string> {
  return b64(await pbkdf2(masterKey, enc(password), 1));
}

// --- Registration / login -----------------------------------------------------------------------

/** Create an account. Generates the kdf salt, derives the master key, mints a random data key plus a
 *  recovery code, wraps the data key under BOTH the master key and the recovery key, and posts the
 *  verifiers + wrapped keys. Returns the live session AND the one-time recovery code (the UI must show
 *  it once and tell the user to store it offline). */
export async function register(
  email: string,
  username: string,
  password: string,
  attempt: AuthAttempt = beginAuthAttempt("register"),
): Promise<{ session: Session; recoveryCode: string }> {
  const op = invokeOperation(attempt, "register");
  try {
  const kdfSaltBytes = crypto.getRandomValues(new Uint8Array(16));
  const kdfSalt = b64(kdfSaltBytes);
  const masterKey = await pbkdf2(enc(password), kdfSaltBytes, ITERS);
  const dataKey = crypto.getRandomValues(new Uint8Array(32));
  const recoveryCode = makeRecoveryCode();
  const recoveryKey = await pbkdf2(enc(recoveryCode), kdfSaltBytes, ITERS);
  const body = {
    email,
    username,
    kdfSalt,
    kdfIters: ITERS,
    authVerifier: await authVerifier(masterKey, password),
    wrappedKeyPassword: await seal(masterKey, dataKey),
    wrappedKeyRecovery: await seal(recoveryKey, dataKey),
    recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1)),
    // The plaintext recoveryCode is NEVER sent to the server (zero-knowledge): recVerifier +
    // wrappedKeyRecovery above are sufficient for the recovery protocol. The code is shown on-screen
    // once (the "created" step) for the user to copy; the welcome email tells them to save it from there.
  };
  const r = await operationRequest(attempt, "/v1/auth/register", body, dataKey, recoveryCode);
  if (r.status === 409 && op.remote === "rejected") {
    throw new Error(r.data?.error === "email_taken" ? "That email is already registered." : "That username is taken.");
  }
  if (r.status !== 200) {
    throw new Error(r.data?.error === "weak_password" ? "Password must be at least 8 characters." : "Could not create the account.");
  }
  const session = acceptCandidate(op, acceptedAccount(r.data, dataKey));
  return { session, recoveryCode };
  } finally { releaseNotSent(op); }
}

/** Thrown when the account has 2FA on and the login needs a TOTP code. The UI catches this to reveal
 *  the 6-digit field and retry with the code (instead of mislabeling it as a wrong password). */
export class TotpRequiredError extends Error {
  constructor() {
    super("totp_required");
    this.name = "TotpRequiredError";
  }
}

/** Sign in with email-or-username + password (+ optional TOTP). Pre-login fetches the account's kdf
 *  salt + iterations, the master key is derived locally, and only the auth verifier crosses the wire.
 *  On success the password-wrapped data key is unwrapped in-tab. Throws TotpRequiredError when the
 *  account needs a 2FA code so the UI can prompt for it. */
export async function login(loginId: string, password: string, totp?: string, attempt: AuthAttempt = beginAuthAttempt("login")): Promise<Session> {
  const op = invokeOperation(attempt, "login");
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: loginId } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (!preData?.kdfSalt) throw new Error("Wrong email/username or password.");
  const masterKey = await deriveMaster(password, preData.kdfSalt, safeIters(preData.kdfIters));
  const body: Record<string, unknown> = { login: loginId, authVerifier: await authVerifier(masterKey, password) };
  if (totp) body.totp = totp.trim();
  const r = await operationRequest(attempt, "/v1/auth/login", body);
  if (r.status === 401) {
    if (r.data?.error === "totp_required") throw new TotpRequiredError();
    if (r.data?.error === "invalid_totp") {
      throw new Error("That 6-digit code is not right. Use the current one from your authenticator app.");
    }
    throw new Error("Wrong email/username or password.");
  }
  if (r.status !== 200) throw new Error("Could not sign in.");
  const data = r.data as { token: string; account: Account; wrappedKeyPassword: string };
  const dataKey = await open(masterKey, data.wrappedKeyPassword);
  if (!dataKey) throw new Error("Could not unlock your data.");
  return acceptCandidate(op, acceptedAccount(r.data, dataKey));
}

/** Verify the stored session is still valid server-side (GET /v1/auth/me). Returns false ONLY on a
 *  definite 401 (the token was revoked/expired, e.g. a password change rotated session_version), so
 *  the app can force a clean re-login; a network blip returns true so it does not sign you out. On
 *  success it refreshes account fields (e.g. twoFactorEnabled) in place. */
export async function validateSession(session: Session): Promise<"retained" | "invalid" | AuthResult> {
  const owns = captureSessionOwnership(session);
  if (!owns()) return "retained";
  const attempt = beginAuthAttempt("refresh"), op = operations.get(attempt)!;
  const snapshot = copySession(session);
  let r: ApiResult;
  try { r = await api("/v1/auth/me", { token: snapshot.token, signal: op.controller.signal }); }
  catch { return "retained"; } // no refresh/publish authority inferred from network failure
  if (!operationLive(op) || !owns()) return "retained";
  if (r.status === 401) return "invalid";
  if (r.status !== 200 || !r.data?.account) return "retained";
  acceptCandidate(op, { ...snapshot, account: { ...snapshot.account, ...cloneAccount(r.data.account as Account) } });
  return completeAuthAttempt(attempt);
}

/** Live username-availability check (debounced by the UI). True = available. */
export async function checkUsername(username: string): Promise<boolean> {
  const r = await api("/v1/auth/check-username", { method: "POST", body: { username } });
  return !!r.data?.available;
}

// --- Recovery / reset ---------------------------------------------------------------------------

/** Forgot-password recovery (DATA-PRESERVING): the user still has the recovery code. Unwrap the data
 *  key with the recovery key, then re-derive a new master key from the SAME kdf salt the account
 *  already uses (so the recovery key stays valid afterwards) and re-wrap the data key under it. */
export async function recover(email: string, recoveryCode: string, newPassword: string, attempt: AuthAttempt = beginAuthAttempt("recover")): Promise<Session> {
  const op = invokeOperation(attempt, "recover");
  try {
  const start = await api("/v1/auth/recover-start", { method: "POST", body: { email } });
  const startData = start.data as { wrappedKeyRecovery?: string; kdfSalt: string; kdfIters: number } | null;
  if (!startData?.wrappedKeyRecovery) throw new Error("No recovery is set up for that email.");
  const recoveryKey = await pbkdf2(enc(recoveryCode.trim()), unb64(startData.kdfSalt), safeIters(startData.kdfIters));
  const dataKey = await open(recoveryKey, startData.wrappedKeyRecovery);
  if (!dataKey) throw new Error("That recovery code is not correct.");
  // Re-derive the new master key from the SAME kdfSalt the account already uses, so the recovery key
  // (also derived from kdfSalt) stays valid after this reset.
  const newMaster = await pbkdf2(enc(newPassword), unb64(startData.kdfSalt), safeIters(startData.kdfIters));
  const body = {
    email,
    recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode.trim()), 1)),
    newAuthVerifier: await authVerifier(newMaster, newPassword),
    newWrappedKeyPassword: await seal(newMaster, dataKey),
  };
  const r = await operationRequest(attempt, "/v1/auth/recover-complete", body, dataKey);
  if (r.status !== 200) throw new Error(op.remote === "rejected" ? "Recovery was rejected. Check the supplied details." : "Recovery outcome could not be confirmed. Do not repeat the request.");
  return acceptCandidate(op, acceptedAccount(r.data, dataKey));
  } finally { releaseNotSent(op); }
}

// Email-code reset, for a user who lost BOTH their password and their recovery code. Unlike recover()
// (which still has the recovery code, so it keeps the data), this CANNOT recover the old data: with no
// old secret the old data key can't be unwrapped, so it mints a FRESH data key + a FRESH recovery code
// and the server drops the old (now-undecryptable) backup. resetStart() asks the server to email a
// 6-digit code; resetComplete() verifies it and re-keys into a fresh, empty vault.
export async function resetStart(login: string, attempt: AuthAttempt = beginAuthAttempt("reset-send")): Promise<void> {
  const op = invokeOperation(attempt, "reset-send");
  try {
  const r = await operationRequest(attempt, "/v1/auth/reset/start", { login: login.trim().toLowerCase() });
  if (r.status !== 200) throw new Error("Email-code request outcome is unknown. Do not repeat it.");
  op.remote = "accepted"; if (retainedOperation === op) retainedOperation = undefined;
  } finally { releaseNotSent(op); }
}
export async function resetComplete(
  login: string,
  code: string,
  newPassword: string,
  attempt: AuthAttempt = beginAuthAttempt("reset"),
): Promise<{ session: Session; recoveryCode: string }> {
  const op = invokeOperation(attempt, "reset");
  try {
  const loginId = login.trim().toLowerCase();
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: loginId } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (pre.status !== 200 || !preData?.kdfSalt) throw new Error("Could not start the reset.");
  const kdfSaltBytes = unb64(preData.kdfSalt);
  const iters = safeIters(preData.kdfIters);
  // Keep the account's existing kdfSalt so the new recovery key derives consistently.
  const newMaster = await pbkdf2(enc(newPassword), kdfSaltBytes, iters);
  const dataKey = crypto.getRandomValues(new Uint8Array(32)); // fresh vault: the old data is unrecoverable
  const recoveryCode = makeRecoveryCode();
  const recoveryKey = await pbkdf2(enc(recoveryCode), kdfSaltBytes, iters);
  const body = {
    login: loginId, code: code.trim(),
    authVerifier: await authVerifier(newMaster, newPassword),
    wrappedKeyPassword: await seal(newMaster, dataKey),
    wrappedKeyRecovery: await seal(recoveryKey, dataKey),
    recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1)),
  };
  const r = await operationRequest(attempt, "/v1/auth/reset/complete", body, dataKey, recoveryCode);
  if (r.status === 401 && op.remote === "rejected") { throw new Error("That reset code is wrong or expired."); }
  if (r.status !== 200) throw new Error("Reset outcome could not be confirmed. Do not repeat the request.");
  // Attach the valid accepted result BEFORE proof finalization can throw.
  const session = acceptCandidate(op, acceptedAccount(r.data, dataKey));
  await authorizeResetSyncGeneration(session);
  op.proofReady = true;
  return { session, recoveryCode };
  } finally { releaseNotSent(op); }
}

// --- Account management (signed-in) -------------------------------------------------------------

/** Change password while logged in: re-derive the key from the new password and re-wrap the data key.
 *  The change rotates session_version (revoking the old token), so adopt the fresh token to stay
 *  signed in. */
export async function changePassword(session: Session, oldPassword: string, newPassword: string): Promise<AuthResult> {
  if (!captureSessionOwnership(session)()) throw new Error("Account session changed.");
  const attempt = beginAuthAttempt("refresh"), op = operations.get(attempt)!;
  reserveManagement(op); session = copySession(session);
  try {
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: session.account.email } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (!preData?.kdfSalt) throw new Error("Could not change the password.");
  const oldMaster = await deriveMaster(oldPassword, preData.kdfSalt, safeIters(preData.kdfIters));
  // Keep the account's kdfSalt so the recovery key still derives correctly afterwards.
  const newMaster = await deriveMaster(newPassword, preData.kdfSalt, safeIters(preData.kdfIters));
  const body = {
    oldAuthVerifier: await authVerifier(oldMaster, oldPassword),
    newAuthVerifier: await authVerifier(newMaster, newPassword),
    newWrappedKeyPassword: await seal(newMaster, session.dataKey),
  };
  const r = await operationRequest(attempt, "/v1/auth/change-password", body, session.dataKey, undefined, session.token);
  if (r.status === 401 && op.remote === "rejected") { throw new Error("Current password is incorrect."); }
  if (r.status !== 200 || typeof r.data?.token !== "string" || !r.data.token) throw new Error("Password change outcome could not be confirmed.");
  acceptCandidate(op, { ...session, token: r.data.token });
  return completeAuthAttempt(attempt);
  } finally { releaseNotSent(op); }
}

/** Regenerate the recovery code while logged in (data-preserving): re-wrap the SAME data key under a
 *  fresh recovery code derived from the account's existing kdf salt, update the server, and return the
 *  new code (the server also emails it). The old code stops working. */
export async function regenerateRecoveryCode(session: Session): Promise<string> {
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: session.account.email } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (!preData?.kdfSalt) throw new Error("Could not regenerate the recovery code.");
  const recoveryCode = makeRecoveryCode();
  const recoveryKey = await pbkdf2(enc(recoveryCode), unb64(preData.kdfSalt), safeIters(preData.kdfIters));
  const r = await api("/v1/auth/recovery/regenerate", {
    method: "POST",
    token: session.token,
    body: {
      wrappedKeyRecovery: await seal(recoveryKey, session.dataKey),
      recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1)),
      // plaintext recoveryCode is NOT sent (zero-knowledge); shown on-screen for the user to copy.
    },
  });
  if (r.status !== 200) throw new Error("Could not regenerate the recovery code.");
  return recoveryCode;
}

// --- 2FA (authenticator / TOTP) -----------------------------------------------------------------

export async function enroll2fa(session: Session): Promise<{ secret: string; otpauth: string }> {
  const r = await api("/v1/auth/2fa/enroll", { method: "POST", token: session.token });
  if (r.status === 409) throw new Error("Two-factor is already enabled.");
  if (r.status !== 200) throw new Error("Could not start 2FA setup.");
  const data = r.data as { secret: string; otpauth: string };
  return { secret: data.secret, otpauth: data.otpauth };
}
async function update2fa(session: Session, code: string, enabled: boolean): Promise<AuthResult> {
  if (!captureSessionOwnership(session)()) throw new Error("Account session changed.");
  const attempt = beginAuthAttempt("refresh"), op = operations.get(attempt)!;
  reserveManagement(op); session = copySession(session);
  try {
  const r = await operationRequest(attempt, enabled ? "/v1/auth/2fa/activate" : "/v1/auth/2fa/disable", { code }, session.dataKey, undefined, session.token);
  if (r.status !== 200) throw new Error("Two-factor update outcome could not be confirmed. Do not repeat it.");
  acceptCandidate(op, { ...session, account: { ...session.account, twoFactorEnabled: enabled } });
  return completeAuthAttempt(attempt);
  } finally { releaseNotSent(op); }
}
export function activate2fa(session: Session, code: string): Promise<AuthResult> { return update2fa(session, code, true); }
export function disable2fa(session: Session, code: string): Promise<AuthResult> { return update2fa(session, code, false); }

// --- Encrypted sync document --------------------------------------------------------------------
// The synced backup is one AES-GCM blob the server stores opaquely; only this tab (holding the data
// key) can read or write it. getSyncDoc/mutateSyncDoc are the decrypted read/write helpers; fetchSync
// reports status + the decoded contents for a "what is synced" view.

export interface SyncStatus {
  synced: boolean;
  version?: number;
  size?: number;
  contents?: Record<string, unknown>;
  // A stored doc that EXISTS (200) but did not decrypt/parse. A writer that treats this as an empty {} would
  // PUT a near-empty doc as a full replacement and WIPE the account (every channel), so callers must abort.
  decryptFailed?: boolean;
  unchanged?: boolean;
}

export class SyncUpgradeRequiredError extends Error {
  constructor() { super("Update VortX to continue syncing. Your unsaved changes are retained."); this.name = "SyncUpgradeRequiredError"; }
}
function snapshotSyncSession(session: Session): Session { return copySession(session); }
function captureSyncWriter(source: Session): () => void {
  const current = captureSessionOwnership(source);
  return () => { if (!current()) throw new Error("Account session changed."); };
}
function candidateBaseRevision(status: SyncStatus): number | null {
  if (!status.synced) return null; // Only an authenticated GET 404 creates this result.
  if (status.decryptFailed || status.unchanged || !status.contents || !Number.isSafeInteger(status.version)
    || status.version! < 0 || status.version! >= Number.MAX_SAFE_INTEGER) throw new Error("Could not read a safe account revision. Please try again.");
  return status.version!;
}

export async function fetchSync(session: Session, options: { version?: number; signal?: AbortSignal; isCurrent?: () => boolean } = {}): Promise<SyncStatus> {
  const ownsSession = captureSessionOwnership(session);
  session = snapshotSyncSession(session);
  const assertCurrent = () => { if (!ownsSession()) throw new Error("Account session changed."); options.signal?.throwIfAborted(); if (options.isCurrent?.() === false) throw new Error("Account session changed."); };
  assertCurrent();
  const ratchet = await syncRatchetAccount(session);
  assertCurrent();
  const r = await api("/v1/backup", {
    token: session.token,
    signal: options.signal,
    headers: options.version === undefined ? undefined : { "if-none-match": `"${options.version}"` },
  });
  assertCurrent();
  if (r.status === 304 && Number.isSafeInteger(options.version) && options.version! >= 0) {
    if (options.version! < syncFloor(ratchet)) return { synced: true, version: options.version, decryptFailed: true };
    return { synced: true, unchanged: true, version: options.version };
  }
  if (r.status === 404) return { synced: false };
  if (r.status !== 200) throw new Error("offline");
  const data = r.data as { document: string; version: number };
  if (typeof data?.document !== "string" || !Number.isSafeInteger(data.version) || data.version < 0) throw new Error("Sync data unavailable: invalid revision or document.");
  const acct = session.account.id;
  const isV2 = data.document.startsWith(DOC_V2_PREFIX);
  let contents: Record<string, unknown> | undefined;
  let decryptFailed = false;
  // "decryptFailed" means "do not use / do not clobber". It covers: an undecryptable doc (wrong key, tamper,
  // a v2 doc served under a forged version), a NON-parsing doc, H-2 a stale replay below our per-account
  // version high-water, and H-1 a bare-legacy doc after this account has been seen as v2 (a downgrade).
  if (data.version < syncFloor(ratchet) || (!isV2 && sawV2(ratchet))) {
    decryptFailed = true;
  } else {
    const pt = await openDocument(session.dataKey, data.document, acct, data.version);
    assertCurrent();
    if (pt) {
      try {
        contents = JSON.parse(td.decode(pt)) as Record<string, unknown>;
        if (!contents || typeof contents !== "object" || Array.isArray(contents) ||
          data.version < syncFloor(ratchet) || (!isV2 && sawV2(ratchet)) || options.signal?.aborted) {
          return { synced: true, version: data.version, decryptFailed: true };
        }
        if (isV2) markSawV2(ratchet);
        bumpSyncFloor(ratchet, data.version);
      } catch {
        decryptFailed = true;
      }
    } else {
      decryptFailed = true;
    }
  }
  return {
    synced: true,
    version: data.version,
    size: Math.ceil((data.document.length * 3) / 4),
    contents,
    decryptFailed,
  };
}

/** Read the decrypted sync document (the data key lives in this tab). */
export async function getSyncDoc(session: Session): Promise<Record<string, unknown>> {
  const s = await fetchSync(session);
  // Never present an undecryptable doc as {} - a caller that writes it back would replace the whole account.
  if (s.synced && s.decryptFailed) throw new Error("Could not read your account right now. Please try again.");
  return (s.contents as Record<string, unknown>) ?? {};
}
/** Carry the exact GET revision with its derived encrypted candidate. A later read or conflict echo
 *  cannot advance this witness. Rejected writes re-read and re-apply the durable intent. The callback
 *  touches only owned fields and retains all foreign/native carriers from the fresh document. */
export async function mutateSyncDoc(
  session: Session,
  mutate: (doc: Record<string, unknown>) => void | false | Promise<void | false>,
  isCurrent: () => boolean = () => true,
  receipt: { rejected?: () => void; accepted?: () => void } = {},
): Promise<void> {
  const sessionGuard = captureSyncWriter(session);
  session = snapshotSyncSession(session);
  const ratchet = await syncRatchetAccount(session);
  sessionGuard();
  const guard = (): void => { sessionGuard(); if (!isCurrent()) throw new Error("Account session changed."); };
  for (let attempt = 0; attempt < 5; attempt++) {
    guard();
    const status = await fetchSync(session, { isCurrent: () => { guard(); return true; } });
    guard();
    // Refuse to write onto a doc we could not read: mutating an assumed-empty {} and PUTing it would wipe
    // the whole account at a winning version. Fail loudly instead (mirrors the app + vortx-site).
    if (status.synced && status.decryptFailed) throw new Error("Could not read your account right now. Please try again.");
    const baseRevision = candidateBaseRevision(status);
    const doc = (status.contents as Record<string, unknown>) ?? {};
    // A causal writer may have witnessed its exact durable edit in this authenticated read.
    // No-op receipt must not create a fresh row revision or echo a received update.
    const changed = await mutate(doc);
    guard();
    if (changed === false) return;
    const version = baseRevision === null ? 0 : baseRevision + 1;
    const ciphertext = await sealDocument(session.dataKey, enc(JSON.stringify(doc)), session.account.id, version, WRITE_SYNC_DOC_V2 || sawV2(ratchet));
    guard();
    const r = await api("/v1/backup", {
      method: "PUT",
      token: session.token,
      body: { document: ciphertext, version, baseRevision },
    });
    guard();
    if (r.status === 426) throw new SyncUpgradeRequiredError();
    if (r.status !== 200) throw new Error("Could not save to your account.");
    if (r.data?.accepted === true) {
      bumpSyncFloor(ratchet, version);                      // H-2: never accept below this again
      if (WRITE_SYNC_DOC_V2) markSawV2(ratchet);            // H-1: our stored doc is now v2
      receipt.accepted?.();
      return;
    }
    if (r.data?.accepted !== false) throw new Error("Could not confirm your account edit. Please retry.");
    // accepted === false: a newer version landed between our read and write; loop to re-fetch and merge.
    receipt.rejected?.();
  }
  throw new Error("Could not save to your account (kept losing to another device).");
}

/** Browser WebSocket authentication uses a transient URL. Never store or log this URL. */
export function connectSyncSocket(session: Session): WebSocket {
  const url = new URL("/v1/sync/connect", API);
  url.protocol = "wss:";
  url.searchParams.set("token", session.token);
  return new WebSocket(url.href);
}

// --- QR / device sign-in (pairing) --------------------------------------------------------------
// A new device shows a QR; an already-signed-in device approves it, handing over the data key WITHOUT
// the server ever seeing it. This reuses the Apple app's PairingCrypto contract byte-for-byte: an
// ephemeral X25519 key agreement, HKDF-SHA256 (salt "vortx-pairing-salt-v1", info "vortx-pairing-v1")
// to a 32-byte AES-GCM key, sealing the 32-byte data key in the combined nonce||ct||tag framing, all
// base64url. So the same flow can later interoperate with the native app as the approver. The worker
// (/v1/qr/*) relays only ciphertext + ephemeral public keys and mints the session token on approval.

const PAIR_SALT = enc("vortx-pairing-salt-v1");
const PAIR_INFO = enc("vortx-pairing-v1");

/** base64url (no padding), matching the app's BackupCrypto.base64URL, for ephemeral pubkeys + sealed blobs. */
function b64url(u8: Uint8Array): string {
  return b64(u8).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function unb64url(s: string): Uint8Array {
  return unb64(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
}

/** ECDH(X25519) + HKDF-SHA256 -> the 32-byte one-time wrapping key, from our private key + the peer's
 *  raw public key (base64url). ECDH is symmetric, so wrap and unwrap derive the same key. */
async function pairWrappingKey(ourPrivate: CryptoKey, peerPubB64url: string): Promise<Uint8Array> {
  const peer = await crypto.subtle.importKey("raw", unb64url(peerPubB64url) as BufferSource, { name: "X25519" }, false, []);
  const secret = new Uint8Array(await crypto.subtle.deriveBits({ name: "X25519", public: peer }, ourPrivate, 256));
  const hk = await crypto.subtle.importKey("raw", secret as BufferSource, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: PAIR_SALT as BufferSource, info: PAIR_INFO as BufferSource },
    hk,
    256,
  );
  return new Uint8Array(bits);
}

/** AES-GCM seal in the app's combined framing (nonce||ct||tag), base64url. */
async function sealPair(key: Uint8Array, pt: Uint8Array): Promise<string> {
  const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, k, pt as BufferSource));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv, 0);
  out.set(ct, 12);
  return b64url(out);
}
/** AES-GCM open of a base64url combined sealed blob. Null on any failure (wrong key / tamper). */
async function openPair(key: Uint8Array, blobB64url: string): Promise<Uint8Array | null> {
  try {
    const comb = unb64url(blobB64url);
    const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["decrypt"]);
    return new Uint8Array(
      await crypto.subtle.decrypt({ name: "AES-GCM", iv: comb.subarray(0, 12) as BufferSource }, k, comb.subarray(12) as BufferSource),
    );
  } catch {
    return null;
  }
}

/** Whether this browser has the X25519 WebCrypto the QR flow needs (so the UI can hide it otherwise). */
export async function qrSupported(): Promise<boolean> {
  try {
    await crypto.subtle.generateKey({ name: "X25519" }, false, ["deriveBits"]);
    return true;
  } catch {
    return false;
  }
}

export interface QrJoin {
  pairingID: string;
  code: string;
  /** What the QR encodes: an approve deep-link a signed-in device opens. */
  approveURL: string;
  /** Kept in memory by the caller until approval; needed to unwrap the approved payload. */
  ephemeral: CryptoKeyPair;
}

/** Joiner: start a QR sign-in. Mints an ephemeral X25519 keypair, registers its public key with the
 *  worker, and returns the pairing id + the human code + the approve URL to render as a QR. */
export async function qrSignInStart(approveBase: string): Promise<QrJoin> {
  const ephemeral = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const pub = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey)));
  const r = await api("/v1/qr/start", { method: "POST", body: { devicePublicKey: pub } });
  const d = r.data as { pairingID?: string; code?: string } | null;
  if (r.status !== 200 || !d?.pairingID || !d?.code) throw new Error("Could not start QR sign-in.");
  const approveURL = `${approveBase}#/approve?c=${encodeURIComponent(d.code)}&k=${encodeURIComponent(pub)}`;
  return { pairingID: d.pairingID, code: d.code, approveURL, ephemeral };
}

/** Joiner: poll once. Returns the live Session when approved, null while still pending. Throws on a
 *  definite failure (expired pairing, undecryptable payload). */
export async function qrSignInPoll(join: QrJoin): Promise<Session | null> {
  const r = await api(`/v1/qr/status?id=${encodeURIComponent(join.pairingID)}`);
  if (r.status === 410 || r.status === 404) throw new Error("This QR code expired. Generate a new one.");
  const d = r.data as { token?: string; payload?: string; pending?: boolean } | null;
  if (!d || d.pending || !d.token || !d.payload) return null; // still waiting for approval
  let parsed: { claim?: string; wrapped?: string };
  try {
    parsed = JSON.parse(d.payload) as { claim?: string; wrapped?: string };
  } catch {
    throw new Error("Sign-in failed (bad approval payload).");
  }
  if (!parsed.claim || !parsed.wrapped) throw new Error("Sign-in failed (incomplete approval).");
  const wrapKey = await pairWrappingKey(join.ephemeral.privateKey, parsed.claim);
  const dataKey = await openPair(wrapKey, parsed.wrapped);
  if (!dataKey || dataKey.length !== 32) throw new Error("Could not unlock your data from the approval.");
  // The worker minted the session token on approval; fetch the account fields it belongs to.
  const me = await api("/v1/auth/me", { token: d.token });
  const account = me.status === 200 ? (me.data?.account as Account | undefined) : undefined;
  if (!account) throw new Error("Sign-in failed (account lookup).");
  const session: Session = { token: d.token, account, dataKey };
  return copySession(session);
}

/** Approver (signed in): wrap our data key to a joining device's published public key and authorize the
 *  pairing. `code` + `devicePublicKey` come from the QR the joining device displayed. */
export async function qrApprove(session: Session, code: string, devicePublicKey: string, attempt: AuthAttempt = beginAuthAttempt("approve")): Promise<void> {
  const op = invokeOperation(attempt, "approve");
  const owns = captureSessionOwnership(session);
  if (!owns()) { releaseNotSent(op); throw new Error("Account session changed."); }
  session = copySession(session);
  try {
  const ephemeral = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const claim = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey)));
  const wrapKey = await pairWrappingKey(ephemeral.privateKey, devicePublicKey);
  const wrapped = await sealPair(wrapKey, session.dataKey);
  if (!owns()) throw new Error("Account session changed.");
  const r = await operationRequest(attempt, "/v1/qr/authorize",
    { code: code.trim().toUpperCase(), wrappedPayload: JSON.stringify({ claim, wrapped }) }, session.dataKey, undefined, session.token);
  if ((r.status === 404 || r.status === 410) && op.remote === "rejected") { throw new Error("That code was not found or has expired."); }
  if (r.status !== 200) throw new Error("Approval outcome could not be confirmed. Do not repeat it.");
  op.remote = "accepted"; if (retainedOperation === op) retainedOperation = undefined;
  } finally { releaseNotSent(op); }
}

// --- Household sharing (shared add-ons / library / metadata + debrid keys across SEPARATE accounts) ---
// A household has ONE random 32-byte household key (`hhKey`, versioned by `hhKeyVersion`). Every member
// can decrypt the household-scoped shared blob with it; the worker (/v1/household/*) never sees `hhKey`
// in plaintext. Admission reuses the SAME ephemeral X25519 + ECDH + HKDF primitive as QR pairing above,
// but with a DISTINCT HKDF salt AND info ("vortx-household-salt-v1" / "vortx-household-v1") so a
// household-wrapped payload can never cross-replay with a pairing-wrapped one (domain separation). The
// owner ECDH-wraps the RAW 32-byte `hhKey` to a joiner's published public key; the worker relays only
// the ciphertext. Byte contract is identical to the Apple app's HouseholdCrypto.swift + the e2e test:
//   wrappingKey = HKDF-SHA256(ECDH(ourPriv, peerPub),
//                             salt = utf8("vortx-household-salt-v1"),
//                             info = utf8("vortx-household-v1"), L = 32)
//   wrappedHhKey = base64url( AES-GCM-seal(hhKey 32B, wrappingKey) )   // iv(12)||ct(32)||tag(16), base64URL
//   public keys  = base64url( X25519 raw public key (32 bytes) )       // same framing as the pairing flow
// The SHARED BLOB itself is sealed under `hhKey` with the account-backup framing (standard base64
// iv||ct||tag, i.e. seal/open above), NOT base64url — two distinct b64 alphabets for two channels, kept
// separate on purpose so each matches its Swift counterpart exactly.

const HOUSEHOLD_SALT = enc("vortx-household-salt-v1");
const HOUSEHOLD_INFO = enc("vortx-household-v1");

/** ECDH(X25519) + HKDF-SHA256 -> the 32-byte household wrapping key, from our private key + the peer's
 *  raw public key (base64url). DISTINCT salt+info from pairWrappingKey for real domain separation. */
async function householdWrappingKey(ourPrivate: CryptoKey, peerPubB64url: string): Promise<Uint8Array> {
  const peer = await crypto.subtle.importKey("raw", unb64url(peerPubB64url) as BufferSource, { name: "X25519" }, false, []);
  const secret = new Uint8Array(await crypto.subtle.deriveBits({ name: "X25519", public: peer }, ourPrivate, 256));
  const hk = await crypto.subtle.importKey("raw", secret as BufferSource, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: HOUSEHOLD_SALT as BufferSource, info: HOUSEHOLD_INFO as BufferSource },
    hk,
    256,
  );
  return new Uint8Array(bits);
}

/** Mint a brand-new household key: 32 random bytes. Called ONCE on household init and again ONLY on
 *  rotation (a member leaves), where the version is bumped so old members are locked out of FUTURE
 *  shared content. Never derive these bytes deterministically. */
export function newHhKey(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(32));
}

/** Joiner: mint a one-time ephemeral X25519 keypair for a household key-request. Hold the keypair in
 *  memory until the owner answers, then unwrap with unwrapHhKey. */
export async function newHouseholdEphemeral(): Promise<{ keyPair: CryptoKeyPair; publicKeyB64url: string }> {
  const keyPair = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const publicKeyB64url = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey)));
  return { keyPair, publicKeyB64url };
}

/** Owner side: wrap the RAW 32-byte `hhKey` to a joiner's published public key. Mints a fresh ephemeral
 *  keypair (so the owner public key for THIS answer is `ownerPublicKey`), does ECDH against the joiner
 *  key, derives the household wrapping key, and seals `hhKey` under it. Returns the owner ephemeral
 *  public key + the sealed key, both base64url. */
export async function wrapHhKey(
  hhKey: Uint8Array,
  joinerPublicKeyB64url: string,
): Promise<{ ownerPublicKey: string; wrappedHhKey: string }> {
  if (hhKey.length !== 32) throw new Error("hhKey must be exactly 32 bytes.");
  const ephemeral = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const ownerPublicKey = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey)));
  const wrapKey = await householdWrappingKey(ephemeral.privateKey, joinerPublicKeyB64url);
  const wrappedHhKey = await sealPair(wrapKey, hhKey);
  return { ownerPublicKey, wrappedHhKey };
}

/** Joiner side: unwrap the household key with our ephemeral private key + the owner's ephemeral public
 *  key. Returns the RAW 32-byte `hhKey`, or null if anything fails to verify (wrong key / tamper / the
 *  recovered bytes are not 32 long). The joiner is expected to re-seal these bytes under its own dataKey
 *  for durability (doc.household.wrappedHhKey), which is a plain seal() with the dataKey. */
export async function unwrapHhKey(
  wrappedHhKey: string,
  ownerPublicKeyB64url: string,
  ourPrivate: CryptoKey,
): Promise<Uint8Array | null> {
  const wrapKey = await householdWrappingKey(ourPrivate, ownerPublicKeyB64url);
  const hhKey = await openPair(wrapKey, wrappedHhKey);
  if (!hhKey || hhKey.length !== 32) return null;
  return hhKey;
}

/** Seal the household shared blob under `hhKey`. Uses the account-backup framing (standard base64
 *  iv||ct||tag), pinned to seal() so the blob stored in household_docs matches every surface + the app's
 *  HouseholdCrypto.sealSharedBlob. */
export async function sealSharedBlob(plaintext: Uint8Array, hhKey: Uint8Array): Promise<string> {
  return seal(hhKey, plaintext);
}
/** Open the household shared blob sealed under `hhKey`. Null on any failure (wrong key / tamper). */
export async function openSharedBlob(ciphertext: string, hhKey: Uint8Array): Promise<Uint8Array | null> {
  return open(hhKey, ciphertext);
}

// --- Household worker calls (the /v1/household/* relay; the worker stays a blind ciphertext relay) ---

export interface HouseholdStatus {
  familyId: string;
  role: string;
  hasBlob: boolean;
  version: number;
  hhKeyVersion: number;
  pendingRequests: number;
}
export interface HouseholdKeyRequest {
  accountId: string;
  username: string;
  joinerPublicKey: string;
  createdAt: number;
}

/** GET /v1/household — sharing status for the caller's family, or null when not in a household. */
export async function householdStatus(session: Session): Promise<HouseholdStatus | null> {
  const r = await api("/v1/household", { token: session.token });
  if (r.status !== 200) return null;
  return (r.data?.household as HouseholdStatus | null) ?? null;
}

/** GET /v1/household/blob — the shared ciphertext blob + its versions, or null when none exists yet. */
export async function householdBlobGet(
  session: Session,
): Promise<{ document: string; version: number; hhKeyVersion: number } | null> {
  const r = await api("/v1/household/blob", { token: session.token });
  if (r.status === 404) return null;
  if (r.status !== 200) throw new Error("Could not read the household.");
  const d = r.data as { document: string; version: number; hhKeyVersion: number };
  return { document: d.document, version: d.version, hhKeyVersion: d.hhKeyVersion };
}

/** PUT /v1/household/blob — store the shared blob, LWW by version (accepted only when strictly newer). */
export async function householdBlobPut(
  session: Session,
  document: string,
  version: number,
  hhKeyVersion: number,
): Promise<boolean> {
  const r = await api("/v1/household/blob", {
    method: "PUT",
    token: session.token,
    body: { document, version, hhKeyVersion },
  });
  if (r.status !== 200) throw new Error("Could not save the household.");
  return r.data?.accepted !== false; // false = a newer version already won; caller re-fetches + merges
}

/** Joiner: POST /v1/household/key-request — publish our ephemeral public key so the owner can wrap hhKey. */
export async function householdKeyRequest(session: Session, joinerPublicKey: string): Promise<void> {
  const r = await api("/v1/household/key-request", {
    method: "POST",
    token: session.token,
    body: { joinerPublicKey },
  });
  if (r.status !== 200) throw new Error("Could not request the household key.");
}

/** Owner: GET /v1/household/key-requests — pending hhKey requests from members (owner only). */
export async function householdKeyRequests(session: Session): Promise<HouseholdKeyRequest[]> {
  const r = await api("/v1/household/key-requests", { token: session.token });
  if (r.status !== 200) return [];
  return (r.data?.requests as HouseholdKeyRequest[]) ?? [];
}

/** Owner: POST /v1/household/key-answer — relay the wrapped hhKey + our ephemeral public key to a member. */
export async function householdKeyAnswer(
  session: Session,
  accountId: string,
  ownerPublicKey: string,
  wrappedHhKey: string,
  hhKeyVersion: number,
): Promise<void> {
  const r = await api("/v1/household/key-answer", {
    method: "POST",
    token: session.token,
    body: { accountId, ownerPublicKey, wrappedHhKey, hhKeyVersion },
  });
  if (r.status !== 200) throw new Error("Could not answer the household key request.");
}

/** Joiner: GET /v1/household/key-status — poll for the owner's answer. The worker returns the wrapped key
 *  ONCE (and deletes the request), so call unwrapHhKey immediately on an "answered" status. */
export async function householdKeyStatus(session: Session): Promise<{
  status: "none" | "pending" | "expired" | "answered";
  ownerPublicKey?: string;
  wrappedHhKey?: string;
  hhKeyVersion?: number;
}> {
  const r = await api("/v1/household/key-status", { token: session.token });
  if (r.status !== 200) return { status: "none" };
  return r.data as {
    status: "none" | "pending" | "expired" | "answered";
    ownerPublicKey?: string;
    wrappedHhKey?: string;
    hhKeyVersion?: number;
  };
}
