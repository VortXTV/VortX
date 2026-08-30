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
  pruneInstalledAddons,
  applyAddonOrder,
  registerAddonsSyncPusher,
  registerCwSyncPusher,
  webProgressEntries,
  webProgressTombstones,
  installedUrls,
  mergeLibrary,
  mergeContinueWatching,
  mergeLibraryForScope,
  mergeContinueWatchingForScope,
  mergeContinueWatchingTombstonesForScope,
  mergeCWTombstones,
  type CWEntry,
  type CWTombstone,
} from "./store";
import {
  mergeSyncedProfiles,
  profiles as localProfiles,
  activeProfileId,
  isOwnerProfile,
  onProfilesChange,
  type SyncedProfile,
} from "./profiles";
import { getSettings, updateSettings, onSettingsChange, type Settings } from "./settings";
import {
  settingsPatchFromDoc,
  mergeWebappSettingsPatchIntoProfile,
  effectiveMainSettings,
  mainProfileId,
} from "./syncSettings";
import { CINEMETA_URL, loadAddon } from "./addon";
import type { MetaItem } from "./types";

// The in-memory cache. `undefined` = not yet hydrated from storage; `null` = hydrated, signed out.
// We lazily hydrate from loadSession() on first read so a hard reload restores the signed-in state.
let cached: Session | null | undefined = undefined;

type Listener = (session: Session | null) => void;
const listeners = new Set<Listener>();

/** Set the cache and tell every subscriber. The single mutation point for the session. */
function setSession(next: Session | null): void {
  bindSettingsSyncState(next);
  cached = next;
  notify();
}

/** The current session (cached). Hydrates from localStorage on first call. This is a SYNCHRONOUS
 *  best-effort read: it does not validate the token with the server (use ensureValidSession on boot
 *  for that), so a revoked token still reads as signed-in until the next validation. */
export function currentSession(): Session | null {
  if (cached === undefined) {
    cached = loadSession();
    bindSettingsSyncState(cached);
  }
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
    // lastWatched may be an ISO string OR an epoch (seconds or ms). Missing/unparseable clocks retain
    // source order in the non-positive range. Never synthesize wall-clock freshness: doing that would
    // make an undated stale account row newer than a real local removal tombstone.
    let updatedAt = NaN;
    if (typeof it.lastWatched === "string") updatedAt = Date.parse(it.lastWatched);
    else if (typeof it.lastWatched === "number") updatedAt = it.lastWatched < 1e12 ? it.lastWatched * 1000 : it.lastWatched;
    if (!Number.isFinite(updatedAt) || updatedAt <= 0) updatedAt = -i;
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
  // playback and stream-filter settings (doc.vortx.profiles[main].settings / doc.profileEdits). Merge
  // them into the owner's complete snapshot. Apply that snapshot live only while the owner is active:
  // account hydration must not replace an overlay profile's local look. The live application is wrapped
  // in suppressUp so hydration cannot bounce back up as a web-authored change (see the write-up below).
  const keys = (doc.apiKeys && typeof doc.apiKeys === "object" ? doc.apiKeys : {}) as Record<string, unknown>;
  const metadataPatch: Partial<Settings> = {
    tmdbKey: typeof keys.tmdb === "string" ? keys.tmdb : "",
    mdblistKey: typeof keys.mdblist === "string" ? keys.mdblist : "",
  };
  settingsSyncState.apiKeysArmed = true;
  const settingsPatch = settingsPatchFromDoc(doc);
  if (Object.keys(settingsPatch).length) {
    settingsSyncState.profileSettingsArmed = true;
  }
  const ownerPatch = { ...metadataPatch, ...settingsPatch };
  if (Object.keys(ownerPatch).length) {
    const ownerSettings = mergeOwnerSettings(ownerPatch);
    if (isOwnerProfile(activeProfileId())) {
      withSuppressedUp(() => updateSettings(ownerSettings));
    } else {
      const sharedPatch = sharedSettingsPatch(ownerPatch);
      if (Object.keys(sharedPatch).length) {
        withSuppressedUp(() => updateSettings(sharedPatch));
      }
    }
  }

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
  // Removal set: a URL deleted on ANY surface. mergeInstalledAddons only ever UNIONs, so without subtracting
  // this a deleted add-on still in vortx.addons (app channel), a Stremio re-import, or one removed on an
  // Apple device would be added straight back - THAT is the "I removed YouTube/Watch Hub but it keeps coming
  // back" bug. Three sources, all folded (matching the app's own union): doc.removedAddons keys (this web
  // stack's tombstones) + doc.webAddonRemovals (the flat mirror) + doc.vortx.deletedAddons (removals done in
  // the Apple app). Normalize (trim+lowercase) BOTH sides so casing differences can't cause a miss - the app
  // keys its tombstones the same way. Re-adding a URL clears the web tombstone (add wins LWW).
  const removedNorm = new Set<string>();
  if (doc.removedAddons && typeof doc.removedAddons === "object")
    for (const k of Object.keys(doc.removedAddons)) removedNorm.add(normalizeAddonUrl(k));
  if (Array.isArray(doc.webAddonRemovals))
    for (const k of doc.webAddonRemovals) if (typeof k === "string") removedNorm.add(normalizeAddonUrl(k));
  if (Array.isArray(vortx.deletedAddons))
    for (const k of vortx.deletedAddons) if (typeof k === "string") removedNorm.add(normalizeAddonUrl(k));
  const liveUrls = removedNorm.size ? urls.filter((u) => !removedNorm.has(normalizeAddonUrl(u))) : urls;
  const addedChanged = mergeInstalledAddons(liveUrls);
  const toPrune = removedNorm.size ? installedUrls().filter((u) => removedNorm.has(normalizeAddonUrl(u))) : [];
  const prunedChanged = toPrune.length ? pruneInstalledAddons(toPrune) : false;
  const addonsChanged = addedChanged || prunedChanged;
  const orderChanged = applyAddonOrder(liveUrls);

  // Owner library (vortx.library: [{id,name,type,poster,t,d,lastWatched,v,...}]). The app emits t/d in
  // seconds (the dashboard + now the web app derive Continue Watching from each item's progress).
  const libItems = (Array.isArray(vortx.library) ? vortx.library : []) as Array<Record<string, unknown>>;
  mergeLibrary(libItems as unknown as MetaItem[]);

  // Apply bilateral timestamped removals BEFORE any live union so stale account/app rows cannot resurrect
  // a clear or >=95%-finished title. Older documents simply omit webProgress.removed.
  const webProg = doc.webProgress && typeof doc.webProgress === "object" ? (doc.webProgress as Record<string, unknown>) : null;
  const removed = webProg?.removed && typeof webProg.removed === "object"
    ? (webProg.removed as Record<string, unknown>)
    : null;
  let cwChanged = mergeContinueWatchingTombstonesForScope("", tombstonesFrom(removed?.owner));
  const removedBy = removed?.byProfile && typeof removed.byProfile === "object"
    ? (removed.byProfile as Record<string, unknown>)
    : null;
  if (removedBy) {
    for (const pid of Object.keys(removedBy)) {
      if (mergeContinueWatchingTombstonesForScope(pid, tombstonesFrom(removedBy[pid]))) cwChanged = true;
    }
  }

  // Continue Watching for the OWNER: derive from the synced library items' t/d progress, plus any explicit
  // vortx.continueWatching the app emits. cwEntriesFrom is shared with the per-profile hydration below.
  if (mergeContinueWatching([...cwEntriesFrom(vortx.continueWatching), ...cwEntriesFrom(libItems)])) cwChanged = true;

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
      // Apple writes the same timestamped canonical-key removals beside this profile's library. Fold them
      // before its live rows, in addition to webProgress.removed above, so either surface can dismiss safely.
      if (mergeContinueWatchingTombstonesForScope(pid, tombstonesFrom(rec.removed))) byProfileChanged = true;
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

function tombstonesFrom(value: unknown): CWTombstone[] {
  if (!Array.isArray(value)) return [];
  return value.filter((entry): entry is CWTombstone => {
    if (!entry || typeof entry !== "object") return false;
    const record = entry as Record<string, unknown>;
    return Array.isArray(record.keys) && record.keys.every((key) => typeof key === "string") &&
      typeof record.removedAt === "number" && Number.isFinite(record.removedAt);
  });
}

/** After sign-in, pull the account's encrypted sync document and apply it locally, so the user's add-ons,
 *  library, and metadata keys come over from their other VortX devices. Fail-soft: a missing or
 *  undecryptable doc never blocks sign-in. */
export async function hydrateFromAccount(session: Session): Promise<void> {
  try {
    const doc = await getSyncDoc(session);
    if (sameSession(settingsSyncState.session, session)) applySyncDoc(doc);
  } catch {
    // network / decrypt failure: sign-in still succeeds with local state.
  }
}

// --- Two-way sync: push web-authored changes back to the account --------------------------------
// The webapp writes ONLY web-owned sibling keys: doc.profileEdits (the main profile's settings) and
// doc.addons (the installed add-on list). It NEVER writes doc.vortx.* (app-authoritative). Every write
// goes through mutateSyncDoc (optimistic concurrency: read version, merge, PUT version+1, retry on a
// stale-version rejection) so a concurrent app/device write is never clobbered.

const SETTINGS_PUSH_DELAY = 800;
const SETTINGS_RETRY_DELAY = 1_000;
const API_KEY_SETTING_KEYS: readonly (keyof Settings)[] = ["tmdbKey", "mdblistKey"];
// These are exactly the fields this module hydrates from and writes to the account document. Resetting
// them on an identity change prevents account A from remaining live while account B is still hydrating.
// Settings absent here are device-local and intentionally survive the transition.
const ACCOUNT_SCOPED_SETTING_DEFAULTS: Partial<Settings> = {
  accentID: "vortx",
  background: "warm",
  textScale: 1,
  audioLang: "",
  subtitleLang: "",
  subtitlesMode: "always",
  tmdbKey: "",
  mdblistKey: "",
  subtitleScale: 1,
  useAddonOrder: false,
  sourceOrder: ["debrid", "usenet", "torrent", "direct"],
  safetyFilter: "off",
  hideWords: "",
  requireWords: "",
  instantOnly: false,
  hideDeadTorrents: false,
  hdrOnly: false,
  hideAV1: false,
  maxQuality: 0,
  maxFileSizeGB: 0,
  subtitleFont: "modern",
  subtitleColor: "white",
  subtitleEdge: "outline",
};

interface SettingsSyncState {
  session: Session | null;
  profileSettingsArmed: boolean;
  apiKeysArmed: boolean;
  suppressUpDepth: number;
  pushTimer: ReturnType<typeof setTimeout> | undefined;
  pendingKeys: Set<keyof Settings>;
  pendingSettings: Settings | null;
  writeQueued: boolean;
  profileAtLastChange: string;
  ownerSettingsSnapshot: Settings;
}

let settingsSyncState: SettingsSyncState;
// Every settings mutation, including one queued under a refreshed session, runs after the previous one.
// Jobs still verify their captured state before starting, so a queued write from a departed account drops.
let settingsWriteTail: Promise<void> = Promise.resolve();

function sameSession(a: Session | null, b: Session | null): boolean {
  if (a === b) return true;
  if (!sameAccountScope(a, b) || !a || !b || a.token !== b.token) {
    return false;
  }
  return true;
}

function sameAccountScope(a: Session | null, b: Session | null): boolean {
  if (a === b) return true;
  if (!a || !b || a.account.id !== b.account.id || a.dataKey.length !== b.dataKey.length) return false;
  return a.dataKey.every((byte, index) => byte === b.dataKey[index]);
}

function copySettings(settings: Settings): Settings {
  return { ...settings, sourceOrder: [...settings.sourceOrder] };
}

// profiles.ts deliberately owns only these six fields per profile. Every other Settings field is shared
// account state even while an overlay is active.
const PROFILE_SCOPED_SETTING_KEYS: readonly (keyof Settings)[] = [
  "accentID",
  "background",
  "textScale",
  "audioLang",
  "subtitleLang",
  "subtitlesMode",
];

function sharedSettingsPatch(settings: Partial<Settings>): Partial<Settings> {
  const shared = { ...settings };
  for (const key of PROFILE_SCOPED_SETTING_KEYS) delete shared[key];
  if (shared.sourceOrder) shared.sourceOrder = [...shared.sourceOrder];
  return shared;
}

function changedSettingKeys(a: Settings, b: Settings): (keyof Settings)[] {
  return (Object.keys(b) as (keyof Settings)[]).filter((key) => {
    if (key === "sourceOrder") return JSON.stringify(a.sourceOrder) !== JSON.stringify(b.sourceOrder);
    return a[key] !== b[key];
  });
}

function initialOwnerSettings(): Settings {
  const live = getSettings();
  const ownerLook = localProfiles()[0]?.look;
  return copySettings(ownerLook ? { ...live, ...ownerLook } : live);
}

function createSettingsSyncState(session: Session | null, ownerSnapshot?: Settings): SettingsSyncState {
  return {
    session,
    profileSettingsArmed: false,
    apiKeysArmed: false,
    suppressUpDepth: 0,
    pushTimer: undefined,
    pendingKeys: new Set(),
    pendingSettings: null,
    writeQueued: false,
    profileAtLastChange: activeProfileId(),
    ownerSettingsSnapshot: copySettings(ownerSnapshot ?? initialOwnerSettings()),
  };
}

settingsSyncState = createSettingsSyncState(null);

function bindSettingsSyncState(session: Session | null): void {
  if (sameAccountScope(settingsSyncState.session, session)) {
    settingsSyncState.session = session;
    return;
  }
  if (settingsSyncState.pushTimer) clearTimeout(settingsSyncState.pushTimer);
  let resetSnapshot: Settings | undefined;
  withSuppressedUp(() => {
    resetSnapshot = updateSettings({
      ...ACCOUNT_SCOPED_SETTING_DEFAULTS,
      sourceOrder: [...(ACCOUNT_SCOPED_SETTING_DEFAULTS.sourceOrder ?? [])],
    });
  });
  settingsSyncState = createSettingsSyncState(session, resetSnapshot);
}

// Guard so settings applied by read-down hydration do not immediately echo back up as a web edit.
function withSuppressedUp(fn: () => void): void {
  const state = settingsSyncState;
  state.suppressUpDepth += 1;
  try {
    fn();
  } finally {
    state.suppressUpDepth -= 1;
  }
}

function rememberOwnerSettings(settings: Settings): void {
  settingsSyncState.ownerSettingsSnapshot = copySettings(settings);
}

function mergeOwnerSettings(patch: Partial<Settings>): Settings {
  const ownerSettingsSnapshot = settingsSyncState.ownerSettingsSnapshot;
  const next = {
    ...ownerSettingsSnapshot,
    ...patch,
    sourceOrder: patch.sourceOrder ? [...patch.sourceOrder] : [...ownerSettingsSnapshot.sourceOrder],
  };
  rememberOwnerSettings(next);
  return next;
}

function restoreOwnerSettings(): void {
  withSuppressedUp(() => updateSettings(copySettings(settingsSyncState.ownerSettingsSnapshot)));
}

onProfilesChange(() => {
  const state = settingsSyncState;
  const profileId = activeProfileId();
  if (profileId === state.profileAtLastChange) return;
  state.profileAtLastChange = profileId;
  if (isOwnerProfile(profileId)) restoreOwnerSettings();
});

/** Build the roster carried by a settings write from the latest effective account state. The app mirror
 *  supplies the acknowledged base. A newer web roster overlays it row by row and retains every pending
 *  web-only field, row, and tombstone. The caller then changes only the main row's settings. */
function rosterForSettingsWrite(
  doc: Record<string, unknown>,
  mainId: string,
  mergedSettings: Record<string, unknown>,
): Record<string, unknown>[] {
  const vortx = (doc.vortx && typeof doc.vortx === "object" ? doc.vortx : {}) as Record<string, unknown>;
  const edits =
    doc.profileEdits && typeof doc.profileEdits === "object"
      ? (doc.profileEdits as Record<string, unknown>)
      : {};
  const order: string[] = [];
  const byId = new Map<string, Record<string, unknown>>();
  const put = (row: Record<string, unknown>): void => {
    if (row.id == null) return;
    const id = String(row.id);
    if (!byId.has(id)) order.push(id);
    byId.set(id, { ...(byId.get(id) ?? {}), ...row, id });
  };

  for (const profile of asObjArr(vortx.profiles)) {
    if (profile.id == null) continue;
    put({ id: String(profile.id), name: String(profile.name ?? "Profile") });
  }
  const editsAreEffective = (Number(edits.editedAt) || 0) > (Number(vortx.updatedAt) || 0);
  if (editsAreEffective) {
    for (const row of asObjArr(edits.roster)) put(row);
  }

  const main = byId.get(mainId) ?? { id: mainId, name: "Profile" };
  byId.set(mainId, { ...main, settings: mergedSettings });
  if (!order.includes(mainId)) order.unshift(mainId);
  return order.map((id) => byId.get(id)!);
}

/** Push the changed webapp settings up to the MAIN profile via doc.profileEdits (dashboard-compatible shape).
 *  Delta-merges the main settings onto the latest effective app plus web roster, preserving unrelated
 *  profile edits and settings. Profile settings no-op when there is no synced main profile, while
 *  API-key deltas remain independent. */
async function pushSettings(
  session: Session,
  s: Settings,
  changedKeys: readonly (keyof Settings)[],
): Promise<void> {
  await mutateSyncDoc(session, (doc) => {
    const changed = new Set(changedKeys);
    const mainId = mainProfileId(doc);
    if (mainId) {
      const edits = (doc.profileEdits && typeof doc.profileEdits === "object" ? doc.profileEdits : {}) as Record<string, unknown>;
      const base = effectiveMainSettings(doc); // freshest known main settings (app mirror + newer overlay)
      const merged = mergeWebappSettingsPatchIntoProfile(base, s, changedKeys);
      if (JSON.stringify(merged) !== JSON.stringify(base)) {
        doc.profileEdits = {
          ...edits,
          editedAt: Date.now(),
          roster: rosterForSettingsWrite(doc, mainId, merged),
          libraryAdds: (edits as Record<string, unknown>).libraryAdds ?? {},
        };
      }
    }

    if (changed.has("tmdbKey") || changed.has("mdblistKey")) {
      const apiKeys =
        doc.apiKeys && typeof doc.apiKeys === "object"
          ? { ...(doc.apiKeys as Record<string, unknown>) }
          : {};
      if (changed.has("tmdbKey")) {
        if (s.tmdbKey) apiKeys.tmdb = s.tmdbKey;
        else delete apiKeys.tmdb;
      }
      if (changed.has("mdblistKey")) {
        if (s.mdblistKey) apiKeys.mdblist = s.mdblistKey;
        else delete apiKeys.mdblist;
      }
      doc.apiKeys = apiKeys;
    }
  });
}

/** Tombstone-identity normalization: trim + lowercase, byte-for-byte matching the app's
 *  AddonTombstones.normalize, so a URL the web writes into doc.webAddonRemovals matches what the app
 *  compares its installed add-ons against. */
function normalizeAddonUrl(u: string): string {
  return u.trim().toLowerCase();
}

/** Push the webapp's installed add-ons up to the account (the doc.addons web sibling), so add-ons added
 *  on the web reach the user's other devices AND the native apps. Cinemeta is excluded (a universal
 *  built-in). Serialized + coalesced by the caller. Fail-soft. */
async function pushAddons(
  session: Session,
  urls: string[],
  hint?: { added?: string[]; removed?: string[] },
): Promise<void> {
  try {
    // Pre-resolve each URL's FULL manifest (async, outside the mutate): the app installs from doc.addons
    // network-free and DROPS any entry without a manifest, so a URL-only entry would never reach the apps.
    const resolved = new Map<string, { transportUrl: string; name: string; manifest: unknown }>();
    await Promise.all(
      urls
        .filter((u) => u !== CINEMETA_URL)
        .map(async (u) => {
          try {
            const a = await loadAddon(u);
            resolved.set(u, { transportUrl: a.transportUrl, name: a.manifest.name, manifest: a.manifest });
          } catch {
            /* leave unresolved; handled inside the mutate (preserve prior descriptor or skip) */
          }
        }),
    );
    await mutateSyncDoc(session, (doc) => {
      // doc.addons is the WEB-ONLY sibling channel. Exclude app-owned URLs (doc.vortx.addons): the webapp's
      // installedUrls includes app add-ons it hydrated in, and copying them here makes the dashboard's
      // diff-based setAddons false-tombstone an untouched app add-on. (audit: web-pollutes-doc.addons)
      const vortx = (doc.vortx && typeof doc.vortx === "object" ? doc.vortx : {}) as Record<string, unknown>;
      const appUrls = new Set(
        (Array.isArray(vortx.addons) ? vortx.addons : []).map((a) => addonUrl(a)).filter(Boolean) as string[],
      );
      const priorByUrl = new Map<string, { transportUrl: string; name?: string; manifest?: unknown }>();
      for (const a of Array.isArray(doc.addons) ? doc.addons : []) {
        const u = addonUrl(a);
        if (u) priorByUrl.set(u, a as { transportUrl: string; name?: string; manifest?: unknown });
      }
      const descriptors: Array<{ transportUrl: string; name?: string; manifest?: unknown }> = [];
      for (const u of urls) {
        if (u === CINEMETA_URL || appUrls.has(u)) continue; // Cinemeta built-in; app add-ons stay in their channel
        const r = resolved.get(u);
        if (r) descriptors.push(r); // freshly-resolved manifest
        else if (priorByUrl.get(u)?.manifest) descriptors.push(priorByUrl.get(u)!); // preserve the last good descriptor
        // else: no manifest available this round - SKIP rather than write a URL-only entry the app drops.
      }
      doc.addons = descriptors;

      // Removal tombstones, from the EXPLICIT add/remove hints (never inferred by diffing, which would
      // false-tombstone app add-ons). doc.removedAddons {url: epochMs} is the web-internal record (carries
      // timestamps so a re-add can clear it). doc.webAddonRemovals is the flat string[] the APP reads and
      // folds into its uninstall set (VortXSyncManager: "web agent owns this write; we only READ it").
      const tomb: Record<string, number> =
        doc.removedAddons && typeof doc.removedAddons === "object"
          ? (doc.removedAddons as Record<string, number>)
          : {};
      for (const u of hint?.removed ?? []) tomb[u] = Date.now();
      for (const u of hint?.added ?? []) delete tomb[u];
      doc.removedAddons = tomb;
      doc.webAddonRemovals = Object.keys(tomb).map(normalizeAddonUrl); // the app-facing mirror
    });
  } catch {
    // fail-soft: the add-on is already installed locally; a later change re-pushes.
  }
}

// Wire the add-on write-up once at module load. recordProgress-style hazards apply: add/remove fire in
// bursts, and each pushAddons does a FULL doc.addons overwrite, so an unserialized fire-and-forget push
// could write a stale snapshot and drop an entry. Coalesce: accumulate add/remove hints, debounce briefly,
// run ONE push that reads installedUrls() fresh at fire time, and never overlap two pushes.
const pendingAdded = new Set<string>();
const pendingRemoved = new Set<string>();
let addonPushTimer: ReturnType<typeof setTimeout> | null = null;
let addonPushInFlight = false;
function scheduleAddonPush(): void {
  if (addonPushTimer) return;
  addonPushTimer = setTimeout(runAddonPush, 350);
}
async function runAddonPush(): Promise<void> {
  addonPushTimer = null;
  if (addonPushInFlight) { scheduleAddonPush(); return; } // one already running; try again after it
  const s = currentSession();
  if (!s) { pendingAdded.clear(); pendingRemoved.clear(); return; }
  const hint = { added: [...pendingAdded], removed: [...pendingRemoved] };
  pendingAdded.clear();
  pendingRemoved.clear();
  addonPushInFlight = true;
  try {
    await pushAddons(s, installedUrls(), hint);
  } finally {
    addonPushInFlight = false;
    if (pendingAdded.size || pendingRemoved.size) scheduleAddonPush(); // hints arrived mid-flight
  }
}
registerAddonsSyncPusher((hint) => {
  if (hint?.added) { pendingAdded.add(hint.added); pendingRemoved.delete(hint.added); }
  if (hint?.removed) { pendingRemoved.add(hint.removed); pendingAdded.delete(hint.removed); }
  scheduleAddonPush();
});

// Push the ACTIVE profile's web watch-progress up to the bilateral doc.webProgress field. Owner progress
// goes top-level (doc.webProgress.owner) to match the app's convention; overlay progress under
// .byProfile[profileId]. The app merges this into watch history (LWW by lastWatched), NEVER into
// libraryItem. Fail-soft. (Read-down lives in applySyncDoc.)
async function pushWebProgress(session: Session): Promise<void> {
  try {
    const entries = webProgressEntries(); // the active scope's CW, already in the bilateral shape
    const tombstones = webProgressTombstones();
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
      const removed: Record<string, unknown> =
        wp.removed && typeof wp.removed === "object" ? (wp.removed as Record<string, unknown>) : {};
      if (owner) {
        removed.owner = mergeWebProgressTombstones(removed.owner, tombstones);
      } else {
        const by: Record<string, unknown> =
          removed.byProfile && typeof removed.byProfile === "object"
            ? (removed.byProfile as Record<string, unknown>)
            : {};
        by[pid] = mergeWebProgressTombstones(by[pid], tombstones);
        removed.byProfile = by;
      }
      wp.removed = removed;
      wp.editedAt = Date.now();
      doc.webProgress = wp;
    });
  } catch {
    // fail-soft: progress is already saved locally; the next CW change re-pushes.
  }
}

function mergeWebProgressTombstones(prior: unknown, mine: CWTombstone[]): CWTombstone[] {
  return mergeCWTombstones(tombstonesFrom(prior), mine);
}

export const __continueWatchingSyncTestHooks = { pushWebProgress, mergeWebProgress };

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
  if (settingsSyncState.suppressUpDepth > 0) return; // hydration merges CW too; don't echo synced progress back up
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

function syncableSettingsKeys(
  state: SettingsSyncState,
  changedKeys: readonly (keyof Settings)[],
): (keyof Settings)[] {
  if (state.profileSettingsArmed) return [...changedKeys];
  if (!state.apiKeysArmed) return [];
  return changedKeys.filter((key) => API_KEY_SETTING_KEYS.includes(key));
}

function queueSettingsPush(state: SettingsSyncState): void {
  state.pushTimer = undefined;
  if (state !== settingsSyncState || !state.session) {
    state.pendingKeys.clear();
    state.pendingSettings = null;
    return;
  }
  if (!state.pendingSettings || !state.pendingKeys.size || state.writeQueued) return;
  state.writeQueued = true;

  const write = async (): Promise<void> => {
    state.writeQueued = false;
    if (state !== settingsSyncState || !state.session || !state.pendingSettings || !state.pendingKeys.size) {
      return;
    }
    const session = state.session;
    const snapshot = copySettings(state.pendingSettings);
    const changedKeys = [...state.pendingKeys];
    state.pendingKeys.clear();
    state.pendingSettings = null;
    try {
      await pushSettings(session, snapshot, changedKeys);
    } catch {
      // Merge a failed batch back into the live pending accumulator. A later queued job captures this
      // combined key set at execution time; with no later edit, the retry timer makes progress itself.
      // Values always come from the newest owner snapshot, so an older same-key value cannot win.
      if (state === settingsSyncState && sameSession(state.session, session)) {
        for (const key of changedKeys) state.pendingKeys.add(key);
        state.pendingSettings = copySettings(state.ownerSettingsSnapshot);
        if (!state.writeQueued && !state.pushTimer) {
          state.pushTimer = setTimeout(() => queueSettingsPush(state), SETTINGS_RETRY_DELAY);
        }
      }
    }
  };
  settingsWriteTail = settingsWriteTail.then(write, write);
}

function scheduleSettingsPush(
  state: SettingsSyncState,
  settings: Settings,
  changedKeys: readonly (keyof Settings)[],
): void {
  for (const key of changedKeys) state.pendingKeys.add(key);
  state.pendingSettings = copySettings(settings);
  if (state.pushTimer) clearTimeout(state.pushTimer);
  state.pushTimer = setTimeout(() => queueSettingsPush(state), SETTINGS_PUSH_DELAY);
}

onSettingsChange((next) => {
  const state = settingsSyncState;
  const profileId = activeProfileId();
  const switchedProfile = profileId !== state.profileAtLastChange;
  state.profileAtLastChange = profileId;
  if (state.suppressUpDepth > 0) {
    if (isOwnerProfile(profileId)) rememberOwnerSettings(next);
    return; // hydration applied this, not the user; don't echo it back up
  }
  if (switchedProfile) {
    if (isOwnerProfile(profileId)) restoreOwnerSettings();
    return; // applying another profile's local snapshot is not a settings edit
  }
  const previousOwner = state.ownerSettingsSnapshot;
  const ownerNext = isOwnerProfile(profileId)
    ? copySettings(next)
    : mergeOwnerSettings(sharedSettingsPatch(next));
  const changedKeys = changedSettingKeys(previousOwner, ownerNext);
  if (!changedKeys.length) {
    return; // the overlay changed only one of its six profile-scoped fields
  }
  rememberOwnerSettings(ownerNext);
  const syncableKeys = syncableSettingsKeys(state, changedKeys);
  if (!syncableKeys.length) return;
  const session = currentSession();
  if (!session || state !== settingsSyncState || !sameSession(state.session, session)) return;
  scheduleSettingsPush(state, ownerNext, syncableKeys);
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
