// Household sharing for the web app (web.vortx.tv) — the orchestration + per-device consent layer behind
// the Settings "Household sharing" section. Mirrors the app's HouseholdSyncManager + HouseholdConsent and
// the dashboard's household-ui.ts. The worker (/v1/household/*) NEVER sees hhKey in plaintext.
//
// CRYPTO is delegated wholesale to vault.ts (newHhKey / wrapHhKey / unwrapHhKey / sealSharedBlob /
// openSharedBlob + the /v1/household/* calls), byte-for-byte verified against the Swift side and
// cloudflare/e2e-test.mjs. This module adds NO new crypto; it orchestrates + tracks consent.
//
// The web app is a playback device, so the FIVE Phase-5 Settings concerns live here:
//   1. Per-channel "shared into this device" indicator (add-ons / library / metadata keys / debrid keys).
//   2. Per-UPDATE consent: a channel's shared payload is fingerprinted; when it changes the channel pauses
//      until re-accepted (the "new shared content" surface; guards a hostile owner pushing content).
//   3. SEPARATE debrid consent, distinct from the content consent (debrid keys are financial credentials).
//   4. Rotate-at-provider guidance after a member leaves (hhKey rotation does NOT un-cache a held key).
//   5. Leave (self) / the household re-keys so the leaver reads nothing new.
import {
  type Session,
  householdStatus,
  householdBlobGet,
  householdKeyRequest,
  householdKeyStatus,
  unwrapHhKey,
  newHouseholdEphemeral,
  sealSharedBlob,
  openSharedBlob,
  getSyncDoc,
  mutateSyncDoc,
  type HouseholdStatus,
} from "./vault";
import { currentSession } from "./account";
import { addAddon } from "./store";
import { updateSettings, getSettings } from "./settings";

const FAM_API = "https://api.vortx.tv";
const te = new TextEncoder();
const td = new TextDecoder();

// --- The shared blob shape (matches the spec + the dashboard's SharedJSON exactly) -----------------
export interface SharedAddon { transportUrl: string; name?: string; contributorAccountId: string; }
export interface SharedLibItem { id: string; name: string; type: string; poster?: string; contributorAccountId: string; }
export interface SharedDebridKey { key: string; contributorAccountId: string; }
export interface SharedJSON {
  addOns: SharedAddon[];
  library: SharedLibItem[];
  metadataKeys: { tmdb?: string; mdblist?: string; fanart?: string };
  debridKeys: { rd?: SharedDebridKey; ad?: SharedDebridKey; pm?: SharedDebridKey; torbox?: SharedDebridKey };
}
const emptyShared = (): SharedJSON => ({ addOns: [], library: [], metadataKeys: {}, debridKeys: {} });

export interface FamilyMember { username: string; role: string; isMe: boolean; }
export interface Family { id: string; name: string; role: string; members: FamilyMember[]; }

// The two independently-consented channel groups (identical to the app's HouseholdConsent.Channel).
export type Channel = "content" | "debrid";

// A read-only snapshot for the Settings indicator + consent surface.
export interface HouseholdSnapshot {
  inHousehold: boolean;
  hasBlob: boolean;
  hasKey: boolean;          // we hold the household key in this browser
  role: string;            // "owner" | "member"
  familyName: string;
  members: FamilyMember[];
  addOnCount: number;
  libraryCount: number;
  metadataKeyCount: number;
  debridKeyCount: number;
  sharedDebridProviders: string[];   // display names, for the rotate-at-provider guidance
  contentAccepted: boolean;
  debridAccepted: boolean;
  contentNeedsReview: boolean;
  debridNeedsReview: boolean;
}

// --- Per-device, per-account consent (localStorage; a fingerprint per channel, never the payload) ----
// Mirrors the app's HouseholdConsent: consent is per UPDATE (fingerprint), keyed by account so two
// accounts in one browser keep independent consent.
function consentKey(channel: Channel, accountId: string): string {
  return `vortx.household.consent.${channel}.${accountId}`;
}
function acceptedFingerprint(channel: Channel, accountId: string): string | null {
  try { return localStorage.getItem(consentKey(channel, accountId)); } catch { return null; }
}
function acceptConsent(channel: Channel, fingerprint: string, accountId: string): void {
  try { localStorage.setItem(consentKey(channel, accountId), fingerprint); } catch { /* private mode */ }
}
function revokeConsent(channel: Channel, accountId: string): void {
  try { localStorage.removeItem(consentKey(channel, accountId)); } catch { /* private mode */ }
}
function isAccepted(channel: Channel, fingerprint: string, accountId: string): boolean {
  if (!fingerprint) return true; // nothing shared on this channel = nothing to gate
  return acceptedFingerprint(channel, accountId) === fingerprint;
}

// Stable SHA-256 digest of a channel payload, canonicalized (sorted keys) so key order never matters.
async function fingerprint(payload: unknown): Promise<string> {
  const json = canonicalJSON(payload);
  if (!json) return "";
  const digest = await crypto.subtle.digest("SHA-256", te.encode(json));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function canonicalJSON(payload: unknown): string {
  if (Array.isArray(payload) && payload.length === 0) return "";
  if (payload && typeof payload === "object" && Object.keys(payload).length === 0) return "";
  return stableStringify(payload);
}
function stableStringify(v: unknown): string {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(stableStringify).join(",") + "]";
  const obj = v as Record<string, unknown>;
  const keys = Object.keys(obj).sort();
  return "{" + keys.map((k) => JSON.stringify(k) + ":" + stableStringify(obj[k])).join(",") + "}";
}

function contentPayload(s: SharedJSON): unknown { return { addOns: s.addOns, library: s.library, metadataKeys: s.metadataKeys }; }
function debridPayload(s: SharedJSON): unknown { return { debridKeys: s.debridKeys }; }

// --- hhKey recovery from our own backup doc (doc.household.wrappedHhKey), version-pinned ------------
interface StoredHhKey { wrappedHhKey: string; hhKeyVersion: number; }
function readStoredHhKey(doc: Record<string, unknown>): StoredHhKey | null {
  const h = doc?.household as Record<string, unknown> | undefined;
  if (h && typeof h === "object" && typeof h.wrappedHhKey === "string" && typeof h.hhKeyVersion === "number") {
    return { wrappedHhKey: h.wrappedHhKey, hhKeyVersion: h.hhKeyVersion };
  }
  return null;
}
async function sealHhKeyForSelf(hhKey: Uint8Array, dataKey: Uint8Array): Promise<string> { return sealSharedBlob(hhKey, dataKey); }
async function openHhKeyForSelf(wrapped: string, dataKey: Uint8Array): Promise<Uint8Array | null> {
  const raw = await openSharedBlob(wrapped, dataKey);
  return raw && raw.length === 32 ? raw : null;
}
async function storeOwnHhKey(session: Session, hhKey: Uint8Array, hhKeyVersion: number): Promise<void> {
  const wrappedHhKey = await sealHhKeyForSelf(hhKey, session.dataKey);
  await mutateSyncDoc(session, (doc) => {
    const prev = (doc.household && typeof doc.household === "object") ? (doc.household as Record<string, unknown>) : {};
    doc.household = { ...prev, wrappedHhKey, hhKeyVersion };
  });
}
/** Recover hhKey from our own backup doc, only if it matches the current version (a stale leaver key is discarded). */
async function recoverOwnHhKey(session: Session, currentVersion: number): Promise<Uint8Array | null> {
  const doc = await getSyncDoc(session);
  const stored = readStoredHhKey(doc);
  if (!stored) return null;
  if (currentVersion > 0 && stored.hhKeyVersion !== currentVersion) return null;
  return openHhKeyForSelf(stored.wrappedHhKey, session.dataKey);
}

// --- Shared blob read --------------------------------------------------------------------------------
async function loadSharedBlob(session: Session, hhKey: Uint8Array): Promise<SharedJSON | null> {
  const blob = await householdBlobGet(session);
  if (!blob) return null;
  const pt = await openSharedBlob(blob.document, hhKey);
  if (!pt) return null; // rotated/wrong key
  try { return normalizeShared(JSON.parse(td.decode(pt))); } catch { return null; }
}
function normalizeShared(raw: any): SharedJSON {
  const out = emptyShared();
  if (Array.isArray(raw?.addOns)) {
    out.addOns = raw.addOns
      .filter((a: any) => a && typeof a.transportUrl === "string" && typeof a.contributorAccountId === "string")
      .map((a: any) => ({ transportUrl: a.transportUrl, name: typeof a.name === "string" ? a.name : undefined, contributorAccountId: a.contributorAccountId }));
  }
  if (Array.isArray(raw?.library)) {
    out.library = raw.library
      .filter((l: any) => l && typeof l.id === "string" && typeof l.contributorAccountId === "string")
      .map((l: any) => ({ id: l.id, name: String(l.name ?? l.id), type: String(l.type ?? "movie"), poster: typeof l.poster === "string" ? l.poster : undefined, contributorAccountId: l.contributorAccountId }));
  }
  if (raw?.metadataKeys && typeof raw.metadataKeys === "object") {
    for (const k of ["tmdb", "mdblist", "fanart"] as const) {
      if (typeof raw.metadataKeys[k] === "string" && raw.metadataKeys[k]) out.metadataKeys[k] = raw.metadataKeys[k];
    }
  }
  if (raw?.debridKeys && typeof raw.debridKeys === "object") {
    for (const k of ["rd", "ad", "pm", "torbox"] as const) {
      const d = raw.debridKeys[k];
      if (d && typeof d.key === "string" && d.key && typeof d.contributorAccountId === "string") {
        out.debridKeys[k] = { key: d.key, contributorAccountId: d.contributorAccountId };
      }
    }
  }
  return out;
}

const DEBRID_NAMES: Record<string, string> = { rd: "Real-Debrid", ad: "AllDebrid", pm: "Premiumize", torbox: "TorBox" };

// --- Family roster + leave (the household membership layer) -----------------------------------------
async function famApi(session: Session, path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(FAM_API + path, {
    ...init,
    headers: { authorization: "Bearer " + session.token, ...(init?.body ? { "content-type": "application/json" } : {}) },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((data && data.error) || ("http_" + res.status));
  return data;
}
async function family(session: Session): Promise<Family | null> {
  try { return (await famApi(session, "/v1/family"))?.family ?? null; } catch { return null; }
}

// --- The public read model + actions ---------------------------------------------------------------

/** Inspect the household + this browser's consent state. `inHousehold === false` => render the empty state. */
export async function snapshot(): Promise<HouseholdSnapshot> {
  const base: HouseholdSnapshot = {
    inHousehold: false, hasBlob: false, hasKey: false, role: "member", familyName: "", members: [],
    addOnCount: 0, libraryCount: 0, metadataKeyCount: 0, debridKeyCount: 0, sharedDebridProviders: [],
    contentAccepted: false, debridAccepted: false, contentNeedsReview: false, debridNeedsReview: false,
  };
  const session = currentSession();
  if (!session) return base;

  let st: HouseholdStatus | null;
  try { st = await householdStatus(session); } catch { return base; }
  if (!st) return base;

  base.inHousehold = true;
  base.role = st.role;
  base.hasBlob = st.hasBlob;
  const fam = await family(session);
  base.familyName = fam?.name ?? "";
  base.members = fam?.members ?? [];

  if (!st.hasBlob || st.hhKeyVersion <= 0) return base;

  let hhKey: Uint8Array | null = null;
  try { hhKey = await recoverOwnHhKey(session, st.hhKeyVersion); } catch { hhKey = null; }
  if (!hhKey) return base; // in a household but locked (waiting for the owner's approval)

  const shared = await loadSharedBlob(session, hhKey);
  if (!shared) return base;

  base.hasKey = true;
  base.addOnCount = shared.addOns.length;
  base.libraryCount = shared.library.length;
  base.metadataKeyCount = (["tmdb", "mdblist", "fanart"] as const).filter((k) => !!shared.metadataKeys[k]).length;
  const debridFields = (["rd", "ad", "pm", "torbox"] as const).filter((k) => !!shared.debridKeys[k]);
  base.debridKeyCount = debridFields.length;
  base.sharedDebridProviders = debridFields.map((k) => DEBRID_NAMES[k]);

  const acct = session.account.id;
  const contentFp = await fingerprint(contentPayload(shared));
  const debridFp = await fingerprint(debridPayload(shared));
  base.contentAccepted = isAccepted("content", contentFp, acct);
  base.debridAccepted = isAccepted("debrid", debridFp, acct);
  base.contentNeedsReview = !!contentFp && !base.contentAccepted;
  base.debridNeedsReview = !!debridFp && !base.debridAccepted;
  return base;
}

/** Accept the CURRENT shared payload on a channel and apply it to this browser. Re-pulls so the stored
 *  fingerprint is the one we actually adopt (no TOCTOU). Content = add-ons + metadata keys (the web app
 *  cannot create torrents, so debrid keys only apply on the separate debrid consent). */
export async function acceptShared(channel: Channel): Promise<boolean> {
  const session = currentSession();
  if (!session) return false;
  let st: HouseholdStatus | null;
  try { st = await householdStatus(session); } catch { return false; }
  if (!st || !st.hasBlob || st.hhKeyVersion <= 0) return false;
  const hhKey = await recoverOwnHhKey(session, st.hhKeyVersion);
  if (!hhKey) return false;
  const shared = await loadSharedBlob(session, hhKey);
  if (!shared) return false;
  const acct = session.account.id;

  if (channel === "content") {
    acceptConsent("content", await fingerprint(contentPayload(shared)), acct);
    await applyContent(shared);
  } else {
    acceptConsent("debrid", await fingerprint(debridPayload(shared)), acct);
    applyDebrid(shared);
  }
  return true;
}

/** Stop adopting NEW shared content on a channel (already-adopted content stays; install-only). */
export function declineShared(channel: Channel): void {
  const session = currentSession();
  if (session) revokeConsent(channel, session.account.id);
}

/** Apply shared add-ons (install-only) + metadata keys (only when we hold none). Library merge is the app's
 *  job (engine-backed); the web app installs add-ons + adopts metadata keys it can use. */
async function applyContent(shared: SharedJSON): Promise<void> {
  for (const a of shared.addOns) {
    try { await addAddon(a.transportUrl); } catch { /* a single bad manifest never blocks the rest */ }
  }
  const cur = getSettings();
  const patch: Record<string, string> = {};
  if (shared.metadataKeys.tmdb && !cur.tmdbKey) patch.tmdbKey = shared.metadataKeys.tmdb;
  if (shared.metadataKeys.mdblist && !cur.mdblistKey) patch.mdblistKey = shared.metadataKeys.mdblist;
  if (Object.keys(patch).length) updateSettings(patch as any);
}

/** Apply shared debrid keys. The web app's Settings has no debrid field of its own yet, so adopted keys ride
 *  in the account doc (doc.apiKeys.rd/ad/pm/torbox) so the apps + dashboard pick them up; the web app does
 *  not create torrents itself. Install-only: never overwrites a key the account already holds. */
async function applyDebrid(shared: SharedJSON): Promise<void> {
  const session = currentSession();
  if (!session) return;
  const map: Record<string, string> = {};
  for (const k of ["rd", "ad", "pm", "torbox"] as const) {
    const entry = shared.debridKeys[k];
    if (entry?.key) map[k] = entry.key;
  }
  if (!Object.keys(map).length) return;
  await mutateSyncDoc(session, (doc) => {
    const keys = (doc.apiKeys && typeof doc.apiKeys === "object") ? (doc.apiKeys as Record<string, unknown>) : {};
    const next = { ...keys };
    for (const [k, v] of Object.entries(map)) if (!next[k]) next[k] = v; // install-only
    doc.apiKeys = next;
  });
}

/** Member: request the household key + poll once for the owner's answer (a single tick; the Settings view
 *  drives the poll loop). Returns whether we unlocked. Mirrors the dashboard join flow. */
let joinEphemeral: CryptoKeyPair | null = null;
export async function startJoin(): Promise<boolean> {
  const session = currentSession();
  if (!session) return false;
  try {
    const { keyPair, publicKeyB64url } = await newHouseholdEphemeral();
    await householdKeyRequest(session, publicKeyB64url);
    joinEphemeral = keyPair;
    return true;
  } catch { return false; }
}
export async function pollJoinOnce(): Promise<"waiting" | "joined" | "expired" | "idle"> {
  const session = currentSession();
  if (!session || !joinEphemeral) return "idle";
  let res: Awaited<ReturnType<typeof householdKeyStatus>>;
  try { res = await householdKeyStatus(session); } catch { return "waiting"; }
  if (res.status === "answered" && res.wrappedHhKey && res.ownerPublicKey && typeof res.hhKeyVersion === "number") {
    const hhKey = await unwrapHhKey(res.wrappedHhKey, res.ownerPublicKey, joinEphemeral.privateKey);
    if (!hhKey) return "expired";
    await storeOwnHhKey(session, hhKey, res.hhKeyVersion);
    joinEphemeral = null;
    return "joined";
  }
  if (res.status === "expired") return "expired";
  if (res.status === "pending") return "waiting";
  return "idle";
}

/** Leave the household (self). The worker drops our membership + pending key-request; the owner re-keys so
 *  we cannot read future shared content. We keep our own already-adopted add-ons/keys (install-only). */
export async function leaveHousehold(): Promise<boolean> {
  const session = currentSession();
  if (!session) return false;
  try { await famApi(session, "/v1/family/leave", { method: "POST", body: "{}" }); return true; }
  catch { return false; }
}

/** Owner: remove a member by username. The worker drops their membership + pending key-request. The owner
 *  must then re-key (done from the dashboard / app authoring path) and rotate any shared debrid key at its
 *  provider to fully cut access. Returns true on success. */
export async function removeMember(username: string): Promise<boolean> {
  const session = currentSession();
  if (!session) return false;
  try { await famApi(session, "/v1/family/leave", { method: "POST", body: JSON.stringify({ username }) }); return true; }
  catch { return false; }
}
