// Session-state module for the webapp. A thin, DOM-free layer over vault.ts that the nav, the Login
// screen, and a future Settings > Account section all read from. It owns:
//   - the single in-memory session cache (so callers don't re-read localStorage on every render),
//   - the boot-time validation (loadSession then GET /v1/auth/me, clearing on a definite 401),
//   - sign-out, and
//   - a tiny subscribe/notify bus so UI reacts to sign-in / sign-out without polling.
// vault.ts is the source of truth for crypto + persistence; this module never touches localStorage
// directly, it goes through vault's saveSession/loadSession/clearSession.

import { loadSession, clearSession, validateSession, saveSession, getSyncDoc, mutateSyncDoc, type Session } from "./vault";
import {
  mergeInstalledAddons,
  applyAddonOrder,
  registerAddonsSyncPusher,
  registerCwSyncPusher,
  webProgressEntries,
  installedUrls,
  mergeLibrary,
  mergeContinueWatching,
  mergeLibraryForScope,
  mergeContinueWatchingForScope,
  type CWEntry,
} from "./store";
import { mergeSyncedProfiles, activeProfileId, isOwnerProfile, type SyncedProfile } from "./profiles";
import { updateSettings, onSettingsChange, type Settings } from "./settings";
import { settingsPatchFromDoc, mergeWebappSettingsIntoProfile, effectiveMainSettings, mainProfileId } from "./syncSettings";
import { CINEMETA_URL, loadAddon } from "./addon";
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

  // Settings read-down: metadata API keys (doc.apiKeys) + the app/dashboard per-profile appearance,
  // playback and stream-filter settings (doc.vortx.profiles[main].settings / doc.profileEdits). Applied
  // through updateSettings so the theme + player prefs take effect live. Wrapped in suppressUp so this
  // hydration does not immediately bounce back up as a web-authored change (see the write-up below).
  const keys = (doc.apiKeys && typeof doc.apiKeys === "object" ? doc.apiKeys : {}) as Record<string, unknown>;
  const patch: Partial<Settings> = {};
  if (typeof keys.tmdb === "string" && keys.tmdb) patch.tmdbKey = keys.tmdb;
  if (typeof keys.mdblist === "string" && keys.mdblist) patch.mdblistKey = keys.mdblist;
  const settingsPatch = settingsPatchFromDoc(doc);
  if (Object.keys(settingsPatch).length) settingsSyncArmed = true; // the account carries settings: web->up is now safe
  Object.assign(patch, settingsPatch);
  if (Object.keys(patch).length) withSuppressedUp(() => updateSettings(patch));

  // Add-ons: the app summary (vortx.addons: [{transportUrl,name}]) + the web Stremio import (doc.addons).
  // Membership union first (never drops a local add-on), then apply the synced ORDER (vortx order wins,
  // Cinemeta stays pinned first).
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
  const orderChanged = applyAddonOrder(urls);

  // Owner library (vortx.library: [{id,name,type,poster,t,d,lastWatched,v,...}]). The app emits t/d in
  // seconds (the dashboard + now the web app derive Continue Watching from each item's progress).
  const libItems = (Array.isArray(vortx.library) ? vortx.library : []) as Array<Record<string, unknown>>;
  mergeLibrary(libItems as unknown as MetaItem[]);

  // Continue Watching for the OWNER: derive from the synced library items' t/d progress, plus any explicit
  // vortx.continueWatching the app emits. cwEntriesFrom is shared with the per-profile hydration below.
  let cwChanged = mergeContinueWatching([...cwEntriesFrom(vortx.continueWatching), ...cwEntriesFrom(libItems)]);

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

  // Web-written watch progress (the bilateral doc.webProgress field this client also WRITES). Shape:
  // { editedAt, owner: [entry], byProfile: { <overlayId>: [entry] } }, entry = {id,type,v,t,d,lastWatched}.
  // Mirrors the app's "owner top-level, overlays under byProfile" convention so the owner's web progress
  // merges into the base scope (not a phantom scope keyed by the owner's profile id). Merging it back means
  // what you watched on one browser shows on another even before the apps round-trip it into vortx.library.
  const webProg = doc.webProgress && typeof doc.webProgress === "object" ? (doc.webProgress as Record<string, unknown>) : null;
  if (webProg) {
    if (Array.isArray(webProg.owner) && mergeContinueWatching(cwEntriesFrom(webProg.owner))) cwChanged = true;
    const wpBy = webProg.byProfile && typeof webProg.byProfile === "object" ? (webProg.byProfile as Record<string, unknown>) : null;
    if (wpBy) {
      for (const pid of Object.keys(wpBy)) {
        if (mergeContinueWatchingForScope(pid, cwEntriesFrom(wpBy[pid]))) byProfileChanged = true;
      }
    }
  }

  // Re-render: any add-on/library/CW change reloads the nav; a roster change repaints the profile switcher
  // and the scoped Home/Library/Continue-Watching for the active profile.
  if (typeof window !== "undefined") {
    if (addonsChanged || orderChanged || cwChanged || rosterChanged || byProfileChanged) {
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

// --- Two-way sync: push web-authored changes back to the account --------------------------------
// The webapp writes ONLY web-owned sibling keys: doc.profileEdits (the main profile's settings) and
// doc.addons (the installed add-on list). It NEVER writes doc.vortx.* (app-authoritative). Every write
// goes through mutateSyncDoc (optimistic concurrency: read version, merge, PUT version+1, retry on a
// stale-version rejection) so a concurrent app/device write is never clobbered.

// Guard so settings applied by read-down hydration do not immediately echo back up as a "web edit".
let suppressUp = false;
// Gate settings write-up: only push web settings UP once read-down has seen that the account already
// carries per-profile settings (i.e. an app/dashboard participates in settings sync). Otherwise the
// webapp's first edit would push its DEFAULTS into profileEdits and could override the app's real
// settings. Stays false on accounts whose app has not synced settings yet (e.g. older app builds), so
// settings only flow web->account once it is safe; read-down works regardless.
let settingsSyncArmed = false;
function withSuppressedUp(fn: () => void): void {
  suppressUp = true;
  try {
    fn();
  } finally {
    suppressUp = false;
  }
}

// Debounce settings pushes: the user may flip several toggles quickly; coalesce into one write.
const SETTINGS_PUSH_DELAY = 800;
let settingsPushTimer: ReturnType<typeof setTimeout> | undefined;

/** Push the webapp's settings up to the MAIN profile via doc.profileEdits (dashboard-compatible shape).
 *  Builds the full roster from the synced profiles (idempotent for unchanged ones, matching the dashboard
 *  buildRoster: non-main entries are {id,name} so the app no-ops them) and merges the webapp-owned keys
 *  over the main profile's existing settings, preserving keys the webapp does not model (avatar, isKids,
 *  ...). No-op when there is no synced main profile yet. Fail-soft. */
async function pushSettings(session: Session, s: Settings): Promise<void> {
  try {
    await mutateSyncDoc(session, (doc) => {
      const mainId = mainProfileId(doc);
      if (!mainId) return; // nothing to attach settings to; never invent a profile
      const vortx = (doc.vortx && typeof doc.vortx === "object" ? doc.vortx : {}) as Record<string, unknown>;
      const profiles = (Array.isArray(vortx.profiles) ? vortx.profiles : []) as Record<string, unknown>[];
      const edits = (doc.profileEdits && typeof doc.profileEdits === "object" ? doc.profileEdits : {}) as Record<string, unknown>;
      const base = effectiveMainSettings(doc); // freshest known main settings (app mirror + newer overlay)
      const roster = profiles
        .filter((p) => p.id != null)
        .map((p) => {
          const id = String(p.id);
          const name = String(p.name ?? "Profile");
          return id === mainId ? { id, name, settings: mergeWebappSettingsIntoProfile(base, s) } : { id, name };
        });
      doc.profileEdits = {
        ...edits,
        editedAt: Date.now(),
        roster,
        libraryAdds: (edits as Record<string, unknown>).libraryAdds ?? {},
      };
    });
  } catch {
    // fail-soft: the local change is already saved; the next change retries the push.
  }
}

/** Push the webapp's installed add-ons up to the account (the doc.addons web sibling), so add-ons added
 *  on the web reach the user's other devices. Cinemeta is excluded (a universal built-in, not a user
 *  add-on). Fail-soft. */
async function pushAddons(
  session: Session,
  urls: string[],
  hint?: { added?: string; removed?: string },
): Promise<void> {
  try {
    // Resolve each add-on's FULL manifest so the synced entry is the descriptor the native app needs:
    // {transportUrl, name, manifest}. The app DROPS doc.addons entries that lack a manifest (it installs
    // them into the engine network-free, see VortXSyncManager.ownedAddons), so a URL-only entry would
    // never reach the apps - that was the "add-ons added on web don't sync to the apps" bug. Cinemeta is a
    // universal built-in and is excluded. Resolve in parallel; on a manifest-fetch failure fall back to a
    // URL-only entry so at least web clients still record the membership.
    const descriptors = await Promise.all(
      urls
        .filter((u) => u !== CINEMETA_URL)
        .map(async (u) => {
          try {
            const a = await loadAddon(u);
            return { transportUrl: a.transportUrl, name: a.manifest.name, manifest: a.manifest };
          } catch {
            return { transportUrl: u };
          }
        }),
    );
    await mutateSyncDoc(session, (doc) => {
      doc.addons = descriptors;
      // Maintain the removal tombstone (doc.removedAddons: { [transportUrl]: removedAtEpochMs }) from the
      // EXPLICIT add/remove signal - never inferred by diffing the merged set, which would false-tombstone
      // app-installed add-ons the webapp doesn't hold locally. A removal records "now"; the app uninstalls
      // tombstoned URLs (gated on a good pull). Re-adding the same URL clears its tombstone (add wins LWW).
      const tomb: Record<string, number> =
        doc.removedAddons && typeof doc.removedAddons === "object"
          ? (doc.removedAddons as Record<string, number>)
          : {};
      if (hint?.removed) tomb[hint.removed] = Date.now();
      if (hint?.added) delete tomb[hint.added];
      doc.removedAddons = tomb;
    });
  } catch {
    // fail-soft: the add-on is already installed locally; a later change re-pushes.
  }
}

// Wire the write-up triggers once at module load:
//  - add/remove on the web pushes the installed list up (store.ts calls this injected pusher).
//  - any USER settings change (suppressUp gates out hydration) debounce-pushes the main profile's settings.
registerAddonsSyncPusher((hint) => {
  const s = currentSession();
  if (s) void pushAddons(s, installedUrls(), hint);
});

// Push the ACTIVE profile's web watch-progress up to the bilateral doc.webProgress field. Owner progress
// goes top-level (doc.webProgress.owner) to match the app's convention; overlay progress under
// .byProfile[profileId]. The app merges this into watch history (LWW by lastWatched), NEVER into
// libraryItem. Fail-soft. (Read-down lives in applySyncDoc.)
async function pushWebProgress(session: Session): Promise<void> {
  try {
    const entries = webProgressEntries(); // the active scope's CW, already in the bilateral shape
    const owner = isOwnerProfile(activeProfileId());
    const pid = activeProfileId();
    await mutateSyncDoc(session, (doc) => {
      const wp: Record<string, unknown> =
        doc.webProgress && typeof doc.webProgress === "object" ? (doc.webProgress as Record<string, unknown>) : {};
      const prior = owner
        ? wp.owner
        : wp.byProfile && typeof wp.byProfile === "object"
          ? (wp.byProfile as Record<string, unknown>)[pid]
          : undefined;
      const merged = mergeWebProgress(prior, entries);
      if (owner) {
        wp.owner = merged;
      } else {
        const by: Record<string, unknown> =
          wp.byProfile && typeof wp.byProfile === "object" ? (wp.byProfile as Record<string, unknown>) : {};
        by[pid] = merged;
        wp.byProfile = by;
      }
      wp.editedAt = Date.now();
      doc.webProgress = wp;
    });
  } catch {
    // fail-soft: progress is already saved locally; the next CW change re-pushes.
  }
}

// Union the doc's existing web-progress entries with this device's, keyed by id+played-id, keeping the
// fresher lastWatched. Without this, a full-array overwrite would let two browsers clobber each other's
// progress (LWW on the array instead of per title). Pure - returns a new array, never mutates inputs.
function mergeWebProgress(prior: unknown, mine: ReturnType<typeof webProgressEntries>): ReturnType<typeof webProgressEntries> {
  const byKey = new Map<string, (typeof mine)[number]>();
  const take = (e: unknown): void => {
    if (!e || typeof e !== "object") return;
    const r = e as Record<string, unknown>;
    if (typeof r.id !== "string" || typeof r.v !== "string") return;
    const key = `${r.id}|${r.v}`;
    const lastWatched = typeof r.lastWatched === "number" ? r.lastWatched : 0;
    const existing = byKey.get(key);
    if (!existing || lastWatched >= existing.lastWatched) {
      byKey.set(key, {
        id: r.id,
        type: typeof r.type === "string" ? r.type : "",
        v: r.v,
        t: typeof r.t === "number" ? r.t : 0,
        d: typeof r.d === "number" ? r.d : 0,
        lastWatched,
        name: typeof r.name === "string" ? r.name : undefined,
        poster: typeof r.poster === "string" ? r.poster : undefined,
      });
    }
  };
  if (Array.isArray(prior)) prior.forEach(take);
  mine.forEach(take);
  return Array.from(byKey.values())
    .sort((a, b) => b.lastWatched - a.lastWatched)
    .slice(0, 100); // cap the synced array; locally we still keep the 40 most-recent per the CW store
}

// recordProgress fires ~every 5s during playback, so coalesce: the first change opens a window and the
// push fires once at its end (at most ~1 account write per WEBPROGRESS_PUSH_DELAY of continuous play),
// then flushes on pagehide so a closed tab still syncs the last position.
let webProgressTimer: ReturnType<typeof setTimeout> | null = null;
const WEBPROGRESS_PUSH_DELAY = 25_000;
registerCwSyncPusher(() => {
  if (suppressUp) return; // hydration merges CW too; don't echo synced progress back up
  if (!currentSession()) return; // signed out: progress stays local
  if (webProgressTimer) return; // a push is already scheduled within this window
  webProgressTimer = setTimeout(() => {
    webProgressTimer = null;
    const s = currentSession();
    if (s) void pushWebProgress(s);
  }, WEBPROGRESS_PUSH_DELAY);
});
if (typeof window !== "undefined") {
  window.addEventListener("pagehide", () => {
    if (webProgressTimer) {
      clearTimeout(webProgressTimer);
      webProgressTimer = null;
    }
    const s = currentSession();
    if (s) void pushWebProgress(s); // best-effort final flush (browsers allow a last fetch on pagehide)
  });
}
onSettingsChange((next) => {
  if (suppressUp) return; // hydration applied this, not the user; don't echo it back up
  if (!settingsSyncArmed) return; // account has no settings mirror yet: keep web changes local (see flag)
  if (!currentSession()) return; // signed out: settings stay local
  if (settingsPushTimer) clearTimeout(settingsPushTimer);
  settingsPushTimer = setTimeout(() => {
    const cur = currentSession();
    if (cur) void pushSettings(cur, next);
  }, SETTINGS_PUSH_DELAY);
});

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
