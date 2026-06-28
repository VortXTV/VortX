// Session-state module for the webapp. A thin, DOM-free layer over vault.ts that the nav, the Login
// screen, and a future Settings > Account section all read from. It owns:
//   - the single in-memory session cache (so callers don't re-read localStorage on every render),
//   - the boot-time validation (loadSession then GET /v1/auth/me, clearing on a definite 401),
//   - sign-out, and
//   - a tiny subscribe/notify bus so UI reacts to sign-in / sign-out without polling.
// vault.ts is the source of truth for crypto + persistence; this module never touches localStorage
// directly, it goes through vault's saveSession/loadSession/clearSession.

import { loadSession, clearSession, validateSession, saveSession, getSyncDoc, type Session } from "./vault";
import {
  mergeInstalledAddons,
  mergeLibrary,
  mergeContinueWatching,
  mergeLibraryForScope,
  mergeContinueWatchingForScope,
  type CWEntry,
} from "./store";
import { mergeSyncedProfiles, type SyncedProfile } from "./profiles";
import { updateSettings } from "./settings";
import type { MetaItem } from "./types";

// The in-memory cache. `undefined` = not yet hydrated from storage; `null` = hydrated, signed out.
// We lazily hydrate from loadSession() on first read so a hard reload restores the signed-in state.
let cached: Session | null | undefined = undefined;

type Listener = (session: Session | null) => void;
const listeners = new Set<Listener>();

/** Set the cache and tell every subscriber. The single mutation point for the session. */
function setSession(next: Session | null): void {
  cached = next;
  notify();
}

/** The current session (cached). Hydrates from localStorage on first call. This is a SYNCHRONOUS
 *  best-effort read: it does not validate the token with the server (use ensureValidSession on boot
 *  for that), so a revoked token still reads as signed-in until the next validation. */
export function currentSession(): Session | null {
  if (cached === undefined) cached = loadSession();
  return cached;
}

/** Whether there is a stored session on this device (best-effort, not server-validated). */
export function isSignedIn(): boolean {
  return currentSession() !== null;
}

/** The label for the signed-in chip: the username if present, else the email, else null. */
export function accountDisplay(): string | null {
  const s = currentSession();
  if (!s) return null;
  return s.account.username || s.account.email || null;
}

/** Boot guard: hydrate the session, then validate it once with the server (GET /v1/auth/me). On a
 *  definite 401 (token revoked/expired) the session is cleared; a network blip keeps it (validateSession
 *  is lenient). On success it refreshes account fields and re-persists. Returns the live session or
 *  null. Safe to call once at startup, before painting the nav. */
export async function ensureValidSession(): Promise<Session | null> {
  const session = loadSession();
  if (!session) {
    setSession(null);
    return null;
  }
  const ok = await validateSession(session);
  if (!ok) {
    clearSession();
    setSession(null);
    return null;
  }
  // validateSession refreshes account fields (e.g. twoFactorEnabled) in place; re-persist them.
  saveSession(session);
  setSession(session);
  return session;
}

/** Adopt a freshly created session (called by the Login screen after register/login/recover/reset).
 *  vault already persisted it via saveSession; this updates the cache + notifies the UI. */
export function adoptSession(session: Session): void {
  setSession(session);
}

/** Pull a string transport URL out of a synced add-on entry (the app emits {transportUrl,name}; the web
 *  Stremio import emits plain strings or {transportUrl}). */
function addonUrl(a: unknown): string | null {
  if (typeof a === "string") return a;
  if (a && typeof a === "object" && typeof (a as { transportUrl?: unknown }).transportUrl === "string") {
    return (a as { transportUrl: string }).transportUrl;
  }
  return null;
}

/** Coerce an unknown to an array of plain objects (the loose synced-doc shape). */
function asObjArr(v: unknown): Record<string, unknown>[] {
  return Array.isArray(v) ? (v.filter((x) => x && typeof x === "object") as Record<string, unknown>[]) : [];
}

/** Map synced library items (carrying t/d seconds + lastWatched + v resumeId) to CW entries. Shared by
 *  the owner library and each per-profile (byProfile) library so the logic stays in one place. */
function cwEntriesFrom(items: unknown): CWEntry[] {
  const arr = asObjArr(items);
  const out: CWEntry[] = [];
  arr.forEach((it, i) => {
    if (typeof it.id !== "string" || typeof it.type !== "string" || typeof it.name !== "string") return;
    const t = Number(it.t);
    const d = Number(it.d);
    if (!(t > 0) || !(d > 0) || t / d >= 0.95) return; // not started / already finished
    // lastWatched may be an ISO string OR an epoch (seconds or ms). When it is missing or unparseable,
    // fall back to the source ORDER (earlier in the list = more recently watched) so the rail matches the
    // app's order instead of collapsing every item to updatedAt 0 and scrambling the order.
    let updatedAt = NaN;
    if (typeof it.lastWatched === "string") updatedAt = Date.parse(it.lastWatched);
    else if (typeof it.lastWatched === "number") updatedAt = it.lastWatched < 1e12 ? it.lastWatched * 1000 : it.lastWatched;
    if (!Number.isFinite(updatedAt) || updatedAt <= 0) updatedAt = Date.now() - i * 1000;
    out.push({
      id: it.id,
      type: it.type,
      name: it.name,
      poster: typeof it.poster === "string" ? it.poster : undefined,
      resumeId: typeof it.v === "string" && it.v ? it.v : it.id, // overlay items carry the resume episode id
      position: t,
      duration: d,
      updatedAt,
    });
  });
  return out;
}

/** Build the web profile roster from the synced doc, mirroring the dashboard's normalizeDoc essentials:
 *  read vortx.profiles, collapse duplicate "main" rows (the duplicate-Main bug), drop deletedProfiles
 *  tombstones unconditionally, and overlay doc.profileEdits ONLY when it is newer than the mirror
 *  (editedAt > vortx.updatedAt) so a stale web edit never masks a newer device change. Returns the slim
 *  roster the web store needs. */
function rosterFromDoc(vortx: Record<string, unknown>, doc: Record<string, unknown>): SyncedProfile[] {
  let roster: SyncedProfile[] = asObjArr(vortx.profiles)
    .filter((p) => p.id != null)
    .map((p, i) => {
      const st = p.settings && typeof p.settings === "object" ? (p.settings as Record<string, unknown>) : {};
      const avatar = typeof st.avatar === "string" && st.avatar.trim() ? st.avatar.trim() : undefined;
      return { id: String(p.id), name: String(p.name ?? `Profile ${i + 1}`), main: !!p.main || i === 0, avatar };
    });
  const mains = roster.filter((p) => p.main);
  if (mains.length > 1) {
    const drop = new Set(mains.slice(1).map((p) => p.id));
    roster = roster.filter((p) => !drop.has(p.id));
  }
  const tombIds = new Set((Array.isArray(vortx.deletedProfiles) ? vortx.deletedProfiles : []).map((x) => String(x)));
  if (tombIds.size) roster = roster.filter((p) => !tombIds.has(p.id));
  const edits = doc.profileEdits && typeof doc.profileEdits === "object" ? (doc.profileEdits as Record<string, unknown>) : null;
  if (edits && (Number(edits.editedAt) || 0) > (Number(vortx.updatedAt) || 0) && Array.isArray(edits.roster)) {
    const byId = new Map(roster.map((p) => [p.id, p] as const));
    for (const raw of edits.roster) {
      if (!raw || typeof raw !== "object") continue;
      const e = raw as Record<string, unknown>;
      if (e.id == null) continue;
      const id = String(e.id);
      if (tombIds.has(id)) continue;
      if (e.deleted) { byId.delete(id); continue; }
      const base = byId.get(id);
      if (base) byId.set(id, { ...base, name: typeof e.name === "string" && e.name ? e.name : base.name });
      else byId.set(id, { id, name: String(e.name ?? "Profile"), main: false });
    }
    roster = [...byId.values()];
  }
  return roster;
}

/** Apply a decrypted sync document to local state (READ-ONLY merge: add-ons, library, metadata keys).
 *  Pure (no network) so it is unit-testable; hydrateFromAccount fetches the doc then calls this. Tolerant
 *  of any missing/odd key - a partial or foreign doc never throws. */
export function applySyncDoc(doc: Record<string, unknown> | null | undefined): void {
  if (!doc || typeof doc !== "object") return;
  const vortx = (doc.vortx && typeof doc.vortx === "object" ? doc.vortx : {}) as Record<string, unknown>;

  // Metadata API keys (the app stores them under doc.apiKeys; Keychain on native, settings here).
  const keys = (doc.apiKeys && typeof doc.apiKeys === "object" ? doc.apiKeys : {}) as Record<string, unknown>;
  const patch: Record<string, string> = {};
  if (typeof keys.tmdb === "string" && keys.tmdb) patch.tmdbKey = keys.tmdb;
  if (typeof keys.mdblist === "string" && keys.mdblist) patch.mdblistKey = keys.mdblist;
  if (Object.keys(patch).length) updateSettings(patch);

  // Add-ons: the app summary (vortx.addons: [{transportUrl,name}]) + the web Stremio import (doc.addons).
  const urls: string[] = [];
  for (const a of Array.isArray(vortx.addons) ? vortx.addons : []) {
    const u = addonUrl(a);
    if (u) urls.push(u);
  }
  for (const a of Array.isArray(doc.addons) ? doc.addons : []) {
    const u = addonUrl(a);
    if (u) urls.push(u);
  }
  const addonsChanged = mergeInstalledAddons(urls);

  // Owner library (vortx.library: [{id,name,type,poster,t,d,lastWatched,v,...}]). The app emits t/d in
  // seconds (the dashboard + now the web app derive Continue Watching from each item's progress).
  const libItems = (Array.isArray(vortx.library) ? vortx.library : []) as Array<Record<string, unknown>>;
  mergeLibrary(libItems as unknown as MetaItem[]);

  // Continue Watching for the OWNER: derive from the synced library items' t/d progress, plus any explicit
  // vortx.continueWatching the app emits. cwEntriesFrom is shared with the per-profile hydration below.
  const cwChanged = mergeContinueWatching([...cwEntriesFrom(vortx.continueWatching), ...cwEntriesFrom(libItems)]);

  // Profiles roster + per-profile (byProfile) library/CW. Without this the webapp only ever showed the
  // local "You" profile and never the user's real synced roster, and secondary profiles had empty
  // libraries. Ports the dashboard normalizeDoc essentials (roster + tombstones + profileEdits overlay)
  // and writes each profile's library/CW into its own scoped store keys. Read-only: never deletes.
  const rosterChanged = mergeSyncedProfiles(rosterFromDoc(vortx, doc));
  let byProfileChanged = false;
  const byProfile = vortx.byProfile && typeof vortx.byProfile === "object" ? (vortx.byProfile as Record<string, unknown>) : null;
  if (byProfile) {
    for (const pid of Object.keys(byProfile)) {
      const bp = byProfile[pid];
      if (!bp || typeof bp !== "object") continue;
      const rec = bp as Record<string, unknown>;
      if (mergeLibraryForScope(pid, asObjArr(rec.library) as unknown as MetaItem[])) byProfileChanged = true;
      const cwSrc = Array.isArray(rec.continueWatching) ? rec.continueWatching : rec.library;
      if (mergeContinueWatchingForScope(pid, cwEntriesFrom(cwSrc))) byProfileChanged = true;
    }
  }

  // Re-render: any add-on/library/CW change reloads the nav; a roster change repaints the profile switcher
  // and the scoped Home/Library/Continue-Watching for the active profile.
  if (typeof window !== "undefined") {
    if (addonsChanged || cwChanged || rosterChanged || byProfileChanged) {
      window.dispatchEvent(new Event("vortx:addons-changed"));
    }
    if (rosterChanged) window.dispatchEvent(new Event("vortx:profile-changed"));
  }
}

/** After sign-in, pull the account's encrypted sync document and apply it locally, so the user's add-ons,
 *  library, and metadata keys come over from their other VortX devices. Fail-soft: a missing or
 *  undecryptable doc never blocks sign-in. */
export async function hydrateFromAccount(session: Session): Promise<void> {
  try {
    applySyncDoc(await getSyncDoc(session));
  } catch {
    // network / decrypt failure: sign-in still succeeds with local state.
  }
}

/** Sign out: clear storage, reset the cache, and notify subscribers so the nav drops back to signed-out. */
export function signOut(): void {
  clearSession();
  setSession(null);
}

/** Subscribe to sign-in / sign-out. Fires once immediately with the current session, then on every
 *  change. Returns an unsubscribe function. */
export function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  listener(currentSession());
  return () => {
    listeners.delete(listener);
  };
}

function notify(): void {
  const value = cached ?? null;
  for (const listener of listeners) listener(value);
}
