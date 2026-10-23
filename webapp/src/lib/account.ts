// Account/session sync for the webapp, read by the nav, Login and Settings. It owns:
//   - the single in-memory session cache (so callers don't re-read localStorage on every render),
//   - the boot-time validation (loadSession then GET /v1/auth/me, clearing on a definite 401),
//   - sign-out and a subscribe/notify bus,
//   - bounded socket/conditional-poll receive and foreground catch-up, and
//   - an account-scoped journal of explicit edits, ACKed only after serialized successful writes.
// vault.ts owns session persistence and encrypted transport. Journals carry no session/key/socket URL.

import { clearSession, validateSession, migrateSession, sessionOwner, startSessionAuthority, onSessionAuthority, captureSessionOwnership, completeAuthAttempt, fetchSync, connectSyncSocket, mutateSyncDoc, SyncUpgradeRequiredError, type Session, type AuthAttempt, type AuthResult } from "./vault";
import {
  mergeInstalledAddons,
  pruneInstalledAddons,
  applyAddonOrder,
  registerAddonsSyncPusher,
  registerCwSyncPusher,
  registerWatchlistSyncPusher,
  webProgressEntries,
  webProgressTombstones,
  installedUrls,
  mergeLibrary,
  mergeContinueWatching,
  mergeLibraryForScope,
  mergeContinueWatchingForScope,
  mergeContinueWatchingTombstonesForScope,
  mergeCWTombstones,
  setNativeAccountProjection,
  blockNativeAccountProjection,
  type CWEntry,
  type CWTombstone,
  type WebProgressEntry,
} from "./store";
import {
  mergeSyncedProfiles,
  profiles as localProfiles,
  activeProfileId,
  isOwnerProfile,
  onProfilesChange,
  setNativeProfiles,
  blockNativeProfiles,
  hasNativeProfiles,
  registerNativeLookSyncPusher,
  retireNativeLookIntent,
  pendingNativeLookIntent,
  type ProfileLook,
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
import { effectiveAddonRemovals, applyAddonIntents } from "./addonRemovals";
import { projectNativeSync, type NativeSyncProjection } from "./nativeSyncProjection";
import { applyHostIntent, createHostIntent, hostSettingField, watchlistField, watchlistValue, type HostIntent, type HostTarget } from "./nativeHostEdits";
import { applyProfileIntent, createProfileIntent, profileIntentAcknowledged, applyAddonEventIntent, addonEventAcknowledged, addonIdentity, type ProfileIntent, type AddonEventIntent } from "./nativeBrowserEvents";
import { canonicalJSON } from "./nativeProfileEvents";
let appliedNativeProjection: NativeSyncProjection | null = null;
function nativeSettingsTarget(profile: NativeSyncProjection["profiles"][number]): string { return `${profile.id}|${profile.binding}`; }

// The in-memory cache. `undefined` = not yet hydrated from storage; `null` = hydrated, signed out.
// We lazily hydrate from loadSession() on first read so a hard reload restores the signed-in state.
let cached: Session | null | undefined = undefined;
let observedAuthorityRevision = -1;

type Listener = (session: Session | null) => void;
const listeners = new Set<Listener>();

/** Vault has already recorded the historical transition before these fallible consumers run. */
function setSession(next: Session | null): void {
  cached = next;
  try { bindSettingsSyncState(next); } catch { /* retained intents remain; authority is not rolled back */ }
  // A revision change invalidates the old receiver even when A's token/key bytes compare equal.
  if (receiveState) disposeReceiver(receiveState);
  receiveState = null;
  try { bindReceiveSession(next); } catch { /* no receive authority inferred from callback success */ }
  notify();
}
function reconcileAuthority(): void {
  const state = sessionOwner();
  if (state.revision === observedAuthorityRevision && cached !== undefined) return;
  observedAuthorityRevision = state.revision;
  setSession(state.session);
}
/** Known blocked/memory owners remain accounts; availability is checked by captured ownership guards. */
export function currentSession(): Session | null {
  reconcileAuthority();
  return cached ?? null;
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
  startSessionAuthority();
  const initial = currentSession();
  if (!initial || !captureSessionOwnership(initial)()) return initial;
  // Explicit owned-legacy compatibility; loadSession/ownership reads never migrate.
  await migrateSession();
  const session = currentSession();
  if (!session) return null;
  const owns = captureSessionOwnership(session);
  const result = await validateSession(session);
  if (result === "invalid" && owns()) await signOut();
  reconcileAuthority();
  return currentSession();
}
/** Only the opaque attempt's privately authenticated candidate may be adopted. */
export async function adoptSession(attempt: AuthAttempt): Promise<AuthResult> {
  const result = await completeAuthAttempt(attempt);
  reconcileAuthority();
  return result;
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
export function applySyncDoc(doc: Record<string, unknown> | null | undefined): boolean {
  if (!doc || typeof doc !== "object") return false;
  discardTransferredIntents(settingsSyncState);
  if (Object.prototype.hasOwnProperty.call(doc, "nativeSync")) {
    try {
      const session = settingsSyncState.session;
      if (!session) return false;
      const view = projectNativeSync(doc, `account.${session.account.id.toLowerCase()}`)!;
      withSuppressedUp(() => applyNativeProjection(view, doc));
      return !view.unsupported;
    } catch {
      const scope = `account.${settingsSyncState.session!.account.id.toLowerCase()}`;
      blockNativeAccountProjection(scope); blockNativeProfiles(scope);
      window.dispatchEvent(new Event("vortx:addons-changed"));
      return false; // Present-invalid is not absence, nor permission to activate stale/unscoped data.
    }
  }
  appliedNativeProjection = null;
  setNativeAccountProjection(null);
  setNativeProfiles("", null);
  withSuppressedUp(() => applySyncDocLocally(doc));
  return true;
}

function nativeSettingsPatch(profile: NativeSyncProjection["profiles"][number]): Partial<Settings> {
  return settingsPatchFromDoc({ vortx: { profiles: [{ id: profile.id, main: true, settings: profile.settings }] } });
}

function applyNativeProjection(view: NativeSyncProjection, doc: Record<string, unknown>): void {
  const changed = JSON.stringify(appliedNativeProjection) !== JSON.stringify(view);
  appliedNativeProjection = view;
  setNativeAccountProjection(view, () => ({
    addons: Object.values(settingsSyncState.addonIntents).filter((intent) =>
      intent.profileId === view.ownerProfileId && view.profiles.find((profile) => profile.main)?.binding === intent.binding),
    progress: Object.fromEntries(Object.entries(settingsSyncState.progressIntents).filter(([key, intent]) => {
      const scope = intent.scope ?? key;
      const profile = view.profiles.find((profile) => profile.main ? scope === "" : profile.id === scope);
      return !!profile && profile.binding === intent.binding;
    }).map(([key, intent]) => [intent.scope ?? key, intent])),
    watchlist: Object.values(settingsSyncState.hostIntents).filter((edit) => !edit.intent.global && Object.keys(edit.intent.fields)[0].startsWith("watchlist.")).flatMap(({ intent }) =>
      Object.values(intent.fields).map((value) => {
        const field = Object.keys(intent.fields)[0], parts = field.split(".");
        const token = parts[2].replace(/-/g, "+").replace(/_/g, "/");
        return { profileId: intent.target.profileId, binding: intent.target.binding, type: parts[1],
          id: atob(token + "=".repeat((4 - token.length % 4) % 4)), value: value as Record<string, unknown> | null };
      })),
  }));
  const rosterChanged = setNativeProfiles(view.scope, [...view.profiles].sort((a, b) => Number(b.main) - Number(a.main) || a.id.localeCompare(b.id))
    .map((profile) => ({ ...profile, look: nativeSettingsPatch(profile), restricted: profile.pending || profile.locked || profile.kids })));
  settingsSyncState.profileAtLastChange = activeProfileId();
  const owner = view.profiles.find((profile) => profile.main)!;
  // Migrate already-durable local look overlays into the same target-bound outbound journal.
  // A projection/hydration is not a new edit: only explicit retained look bytes are recovered.
  let recovered = false;
  for (const profile of view.profiles) {
    const target = hostTarget(view, profile), look = pendingNativeLookIntent(profile.id, profile.binding);
    if (Object.keys(look).length && !settingsSyncState.profileIntents[JSON.stringify(target)]) {
      queueProfileLook(settingsSyncState, profile.id, profile.binding, look); recovered = true;
    }
  }
  // Recover the previously durable supported settings slice only under its originally captured
  // binding. Receiving a different slot is never permission to retarget a queued action.
  const restored = { ...settingsSyncState.retainedNativeSettings[nativeSettingsTarget(owner)] };
  for (const key of settingsSyncState.pendingKeys) if (settingsSyncState.pendingSettings &&
    settingsSyncState.nativeSettingBindings[key] === nativeSettingsTarget(owner)) Object.assign(restored, { [key]: settingsSyncState.pendingSettings[key] });
  for (const [rawKey, value] of Object.entries(restored)) {
    const key = rawKey as keyof Settings, field = hostSettingField(key);
    if (!field) continue;
    if (settingsSyncState.pendingKeys.has(key) && settingsSyncState.nativeSettingBindings[key] !== nativeSettingsTarget(owner)) continue;
    const target = hostTarget(view, owner), id = JSON.stringify([target, true, field]);
    if (!settingsSyncState.hostIntents[id]) { queueHostSetting(settingsSyncState, key, value); persistIntents(settingsSyncState); scheduleIntentPush(settingsSyncState, 350); }
  }
  if (Object.keys(restored).some((key) => PLAYBACK_SETTING_KEYS.includes(key as keyof Settings)) &&
    !Object.values(settingsSyncState.hostIntents).some((edit) => !edit.intent.global && "playback" in edit.intent.fields && edit.intent.target.binding === owner.binding)) {
    queuePlaybackSettings(settingsSyncState, { ...settingsSyncState.ownerSettingsSnapshot, ...restored }, Object.keys(restored) as (keyof Settings)[]);
    recovered = true;
  }
  if (recovered) { persistIntents(settingsSyncState); scheduleIntentPush(settingsSyncState, 350); }
  const keys = doc.apiKeys && typeof doc.apiKeys === "object" ? doc.apiKeys as Record<string, unknown> : {};
  const ownerPatch: Partial<Settings> = { ...ACCOUNT_SCOPED_SETTING_DEFAULTS, ...NATIVE_HOST_SETTING_DEFAULTS, ...view.globals, ...nativeSettingsPatch(owner),
    ...localProfiles().find((profile) => profile.id === owner.id)?.look, tmdbKey: typeof keys.tmdb === "string" ? keys.tmdb : "",
    mdblistKey: typeof keys.mdblist === "string" ? keys.mdblist : "" };
  Object.assign(ownerPatch, settingsSyncState.retainedNativeSettings[nativeSettingsTarget(owner)]);
  for (const key of settingsSyncState.pendingKeys) {
    if (settingsSyncState.pendingSettings && (!settingsSyncState.nativeSettingKeys.has(key) ||
      settingsSyncState.nativeSettingBindings[key] === nativeSettingsTarget(owner))) Object.assign(ownerPatch, { [key]: settingsSyncState.pendingSettings[key] });
  }
  const ownerSettings = mergeOwnerSettings(ownerPatch);
  const active = view.profiles.find((profile) => profile.id === activeProfileId())!;
  const activeLook: Partial<Settings> = localProfiles().find((profile) => profile.id === active.id)?.look ?? nativeSettingsPatch(active);
  const look = Object.fromEntries(PROFILE_SCOPED_SETTING_KEYS.filter((key) => key in activeLook).map((key) => [key, activeLook[key]]));
  updateSettings(active.main ? ownerSettings : { ...sharedSettingsPatch(ownerSettings), ...look });
  if (changed || rosterChanged) window.dispatchEvent(new Event("vortx:addons-changed"));
  if (rosterChanged) window.dispatchEvent(new CustomEvent("vortx:profile-changed", { detail: { fromSync: true } }));
}

function applySyncDocLocally(doc: Record<string, unknown>): void {
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
  const settingsPatch = settingsPatchFromDoc(doc);
  const ownerPatch: Partial<Settings> = { ...metadataPatch, ...settingsPatch };
  // A pull can race a local edit or failed PUT. Keep that edit live until its durable intent is ACKed.
  for (const key of settingsSyncState.pendingKeys) {
    if (settingsSyncState.pendingSettings) Object.assign(ownerPatch, { [key]: settingsSyncState.pendingSettings[key] });
  }
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
  const removedNorm = effectiveAddonRemovals(doc);
  for (const intent of Object.values(settingsSyncState.addonIntents)) {
    const normalized = normalizeAddonUrl(intent.url);
    if (intent.added) { removedNorm.delete(normalized); urls.push(intent.url); }
    else removedNorm.add(normalized);
  }
  const liveUrls = removedNorm.size ? urls.filter((u) => !removedNorm.has(normalizeAddonUrl(u))) : urls;
  const addedChanged = mergeInstalledAddons(liveUrls);
  const toPrune = removedNorm.size ? installedUrls().filter((u) => removedNorm.has(normalizeAddonUrl(u))) : [];
  const prunedChanged = toPrune.length ? pruneInstalledAddons(toPrune) : false;
  const addonsChanged = addedChanged || prunedChanged;
  const orderChanged = applyAddonOrder(liveUrls);

  // Owner library (vortx.library: [{id,name,type,poster,t,d,lastWatched,v,...}]). The app emits t/d in
  // seconds (the dashboard + now the web app derive Continue Watching from each item's progress).
  const libItems = (Array.isArray(vortx.library) ? vortx.library : []) as Array<Record<string, unknown>>;
  const libraryChanged = mergeLibrary(libItems as unknown as MetaItem[]);

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
    if (addonsChanged || orderChanged || libraryChanged || cwChanged || rosterChanged || byProfileChanged) {
      window.dispatchEvent(new Event("vortx:addons-changed"));
    }
    if (rosterChanged) window.dispatchEvent(new CustomEvent("vortx:profile-changed", { detail: { fromSync: true } }));
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
  if (receiveState && sameSession(receiveState.session, session)) {
    await requestAccountPull(receiveState);
    return;
  }
  const ownsStoredSession = captureStoredSession(session);
  const isCurrent = () => sameSession(settingsSyncState.session, session) && settingsSyncState.ownsStoredSession() && ownsStoredSession();
  try {
    const status = await fetchSync(session, { isCurrent });
    if (isCurrent() && status.contents && !status.decryptFailed) applySyncDoc(status.contents);
  } catch {
    // network / decrypt failure: sign-in still succeeds with local state.
  }
}

interface ReceiveState {
  session: Session;
  ownsStoredSession: () => boolean;
  receivedVersion?: number;
  appliedVersion?: number;
  projectionPending?: boolean;
  pull: Promise<void> | null;
  pullAgain: boolean;
  abort: AbortController | null;
  socket: WebSocket | null;
  pollTimer?: ReturnType<typeof setTimeout>;
  reconnectTimer?: ReturnType<typeof setTimeout>;
  reconnectAttempt: number;
}

let receiveStarted = false;
let receiveState: ReceiveState | null = null;

function syncIsActive(): boolean {
  return (typeof document === "undefined" || document.visibilityState !== "hidden") &&
    (typeof navigator === "undefined" || navigator.onLine !== false);
}

function isCurrentReceiver(state: ReceiveState): boolean {
  return receiveStarted && receiveState === state && sameSession(settingsSyncState.session, state.session) && state.ownsStoredSession();
}

function disposeReceiver(state: ReceiveState): void {
  if (state.pollTimer) clearTimeout(state.pollTimer);
  if (state.reconnectTimer) clearTimeout(state.reconnectTimer);
  state.pollTimer = state.reconnectTimer = undefined;
  state.abort?.abort();
  if (state.socket) {
    state.socket.onopen = state.socket.onmessage = state.socket.onerror = state.socket.onclose = null;
    state.socket.close();
    state.socket = null;
  }
}

function bindReceiveSession(session: Session | null): void {
  if (!receiveStarted) return;
  if (session && receiveState && sameSession(receiveState.session, session)) return;
  if (receiveState) disposeReceiver(receiveState);
  receiveState = session ? {
    session: { ...session, account: { ...session.account }, dataKey: session.dataKey.slice() },
    ownsStoredSession: captureStoredSession(session),
    pull: null, pullAgain: false, abort: null, socket: null, reconnectAttempt: 0,
  } : null;
  if (receiveState) resumeReceiver(receiveState, true);
  notifyReceiveStatus();
}

function resumeReceiver(state: ReceiveState, flushWrites = false): void {
  if (!isCurrentReceiver(state) || !syncIsActive()) return;
  discardTransferredIntents(settingsSyncState);
  if (!settingsSyncState.writeQueued && restoreIntents(settingsSyncState, true)) {
    withSuppressedUp(() => updateSettings(isOwnerProfile(activeProfileId())
      ? settingsSyncState.ownerSettingsSnapshot : sharedSettingsPatch(settingsSyncState.ownerSettingsSnapshot)));
    persistIntents(settingsSyncState);
    scheduleIntentPush(settingsSyncState, 350);
  }
  for (const key of settingsSyncState.journalOwners) claimJournal(settingsSyncState, key);
  void requestAccountPull(state);
  connectReceiver(state);
  if (!state.pollTimer) state.pollTimer = setTimeout(() => {
    state.pollTimer = undefined;
    resumeReceiver(state);
  }, 3_000);
  if (flushWrites && hasPendingIntents(settingsSyncState)) {
    if (settingsSyncState.pushTimer) clearTimeout(settingsSyncState.pushTimer);
    queueSettingsPush(settingsSyncState);
  }
}

function connectReceiver(state: ReceiveState): void {
  if (state.socket || state.reconnectTimer || typeof WebSocket === "undefined") return;
  const retry = (): void => {
    if (!isCurrentReceiver(state) || !syncIsActive() || state.reconnectTimer) return;
    state.reconnectTimer = setTimeout(() => {
      state.reconnectTimer = undefined;
      if (isCurrentReceiver(state) && syncIsActive()) connectReceiver(state);
    }, Math.min(30_000, 1_000 * 2 ** Math.min(state.reconnectAttempt++, 5)));
  };
  try {
    const socket = connectSyncSocket(state.session);
    state.socket = socket;
    socket.onopen = () => {
      if (!isCurrentReceiver(state) || state.socket !== socket) return;
      state.reconnectAttempt = 0;
      void requestAccountPull(state); // closes the write-between-initial-GET-and-socket-open gap
    };
    socket.onmessage = (event) => {
      if (!isCurrentReceiver(state) || state.socket !== socket || !syncIsActive()) return;
      try {
        const message = JSON.parse(String(event.data));
        if (message.type === "updated" && Number.isSafeInteger(message.version) &&
          (state.receivedVersion === undefined || message.version > state.receivedVersion)) {
          void requestAccountPull(state);
        }
      } catch { /* Invalid notifications carry no account content and cannot trigger application. */ }
    };
    socket.onclose = () => {
      if (state.socket !== socket) return;
      state.socket = null;
      retry();
    };
    socket.onerror = () => {
      if (state.socket !== socket) return;
      state.socket = null;
      socket.onclose = null;
      socket.close();
      retry();
    };
  } catch { retry(); }
}

function requestAccountPull(state: ReceiveState): Promise<void> {
  if (!isCurrentReceiver(state) || !syncIsActive()) return Promise.resolve();
  if (state.pull) {
    state.pullAgain = true;
    return state.pull;
  }
  const run = async (): Promise<void> => {
    do {
      state.pullAgain = false;
      const abort = new AbortController();
      state.abort = abort;
      const deadline = setTimeout(() => abort.abort(), 15_000);
      try {
        const status = await fetchSync(state.session, { version: state.receivedVersion, signal: abort.signal,
          isCurrent: () => isCurrentReceiver(state) && syncIsActive() });
        if (!isCurrentReceiver(state) || !syncIsActive() || abort.signal.aborted) return;
        if (status.unchanged || status.decryptFailed) continue;
        if (status.version !== undefined && state.receivedVersion !== undefined && status.version < state.receivedVersion) continue;
        if (status.contents) {
          const applied = applySyncDoc(status.contents);
          // The legacy browser adapter cannot project native engine state yet. Retain its encrypted
          // fields on every write, and expose received separately from fully applied in the UI.
          state.projectionPending = !applied;
          if (!state.projectionPending) state.appliedVersion = status.version;
        }
        state.receivedVersion = status.version;
        notifyReceiveStatus();
      } catch { /* Socket hints, fallback polling, and foreground/online catch-up retry automatically. */ }
      finally {
        clearTimeout(deadline);
        if (state.abort === abort) state.abort = null;
      }
    } while (state.pullAgain && isCurrentReceiver(state) && syncIsActive());
  };
  state.pull = run().finally(() => { state.pull = null; });
  return state.pull;
}

/** One automatic receiving lifecycle for this page. Account/token changes retire old callbacks. */
export function startAccountSync(): () => void {
  startSessionAuthority();
  reconcileAuthority();
  receiveStarted = true;
  bindReceiveSession(currentSession());
  const catchUp = (): void => {
    if (!receiveState) return;
    if (syncIsActive()) resumeReceiver(receiveState, true);
    else disposeReceiver(receiveState);
  };
  const pause = (): void => {
    if (receiveState) disposeReceiver(receiveState);
    releaseJournals(settingsSyncState);
  };
  window.addEventListener("online", catchUp);
  window.addEventListener("offline", catchUp);
  window.addEventListener("pageshow", catchUp);
  window.addEventListener("pagehide", pause);
  document.addEventListener("visibilitychange", catchUp);
  return () => {
    receiveStarted = false;
    if (receiveState) disposeReceiver(receiveState);
    receiveState = null;
    window.removeEventListener("online", catchUp);
    window.removeEventListener("offline", catchUp);
    window.removeEventListener("pageshow", catchUp);
    window.removeEventListener("pagehide", pause);
    document.removeEventListener("visibilitychange", catchUp);
  };
}

export function accountSyncStatus(): { receivedVersion?: number; appliedVersion?: number; projectionPending: boolean; upgradeRequired?: true } {
  return { receivedVersion: receiveState?.receivedVersion, appliedVersion: receiveState?.appliedVersion,
    projectionPending: receiveState?.projectionPending ?? false,
    ...(settingsSyncState.upgradeRequired ? { upgradeRequired: true as const } : {}) };
}

function notifyReceiveStatus(): void {
  if (typeof window !== "undefined") window.dispatchEvent(new Event("vortx:account-sync-changed"));
}

// --- Two-way sync: push web-authored changes back to the account --------------------------------
// The webapp writes ONLY web-owned sibling keys: doc.profileEdits (the main profile's settings),
// doc.addons (installed add-ons) and doc.webProgress. It NEVER writes doc.vortx.* (app-authoritative). Every write
// goes through mutateSyncDoc (optimistic concurrency: read version, merge, PUT version+1, retry on a
// stale-version rejection) so a concurrent app/device write is never clobbered.

const SETTINGS_PUSH_DELAY = 800;
const SETTINGS_RETRY_DELAY = 1_000;
const API_KEY_SETTING_KEYS: readonly (keyof Settings)[] = ["tmdbKey", "mdblistKey"];
const NATIVE_HOST_SETTING_DEFAULTS: Partial<Settings> = { autoplayTrailers: true, directLinksOnly: false, performance: "auto" };
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
  requiresStoredSession: boolean;
  ownsStoredSession: () => boolean;
  suppressUpDepth: number;
  pushTimer: ReturnType<typeof setTimeout> | undefined;
  pendingKeys: Set<keyof Settings>;
  nativeSettingKeys: Set<keyof Settings>;
  nativeSettingBindings: Partial<Record<keyof Settings, string>>;
  retainedNativeSettings: Record<string, Partial<Settings>>;
  pendingSettings: Settings | null;
  writeQueued: boolean;
  profileAtLastChange: string;
  ownerSettingsSnapshot: Settings;
  addonIntents: Record<string, AddonIntent>;
  progressIntents: Record<string, ProgressIntent>;
  hostIntents: Record<string, QueuedHostEdit>;
  profileIntents: Record<string, QueuedProfileEdit>;
  addonEvents: Record<string, QueuedAddonEvent>;
  hostCounter: number;
  revision: number;
  retryAttempt: number;
  upgradeRequired: boolean;
  journalSources: Map<string, string>;
  journalOwners: Set<string>;
}

interface AddonIntent { url: string; added: boolean; at: number; revision: number; profileId?: string; binding?: string;
  descriptor?: { transportUrl: string; name: string; manifest: unknown } }
interface ProgressIntent { entries: WebProgressEntry[]; tombstones: CWTombstone[]; revision: number; binding?: string; scope?: string }
interface QueuedHostEdit { intent: HostIntent; revision: number; settingKey?: keyof Settings; settingValues?: Partial<Settings> }
interface QueuedProfileEdit { intent: ProfileIntent; revision: number; look: Partial<ProfileLook> }
interface QueuedAddonEvent { intent: AddonEventIntent; revision: number; revisions: Record<string, number> }
function hostIntentKey(intent: HostIntent): string {
  return JSON.stringify([intent.target, intent.global, Object.keys(intent.fields)[0]]);
}
function hostAddress(intent: HostIntent): string {
  return JSON.stringify([intent.target.scope, intent.global, intent.global ? "globals" : intent.target.profileId, Object.keys(intent.fields)[0]]);
}
function hostTarget(view: NativeSyncProjection, profile: NativeSyncProjection["profiles"][number]): HostTarget {
  return { scope: view.scope, ownerProfileId: view.ownerProfileId, profileId: profile.id, binding: profile.binding };
}
function enqueueHostEdit(state: SettingsSyncState, edit: QueuedHostEdit): void {
  const incoming = edit.intent;
  // Public host globals/profile Watchlist have one address, not separate native own-slot buckets.
  // A new explicit action may supersede that address's older intent without retargeting either
  // capture. Otherwise returning to an old binding could replay an obsolete user choice.
  for (const [key, old] of Object.entries(state.hostIntents)) {
    if (hostAddress(old.intent) === hostAddress(incoming)) delete state.hostIntents[key];
  }
  if (edit.settingKey) for (const [target, delta] of Object.entries(state.retainedNativeSettings)) {
    delete delta[edit.settingKey];
    if (!Object.keys(delta).length) delete state.retainedNativeSettings[target];
  }
  state.hostIntents[hostIntentKey(incoming)] = edit;
}
function queueHostSetting(state: SettingsSyncState, key: keyof Settings, value: unknown): void {
  const field = hostSettingField(key), view = appliedNativeProjection;
  if (!field || !view) return;
  const owner = view.profiles.find((profile) => profile.main)!;
  const intent = createHostIntent(hostTarget(view, owner), { [field]: value }, true, journalPageId);
  enqueueHostEdit(state, { intent, revision: ++state.revision, settingKey: key });
}

const PLAYBACK_SETTING_KEYS: readonly (keyof Settings)[] = ["subtitleScale", "subtitleFont", "subtitleColor", "subtitleEdge", "useAddonOrder", "sourceOrder", "safetyFilter", "instantOnly", "hideDeadTorrents", "hdrOnly", "hideAV1", "hideWords", "requireWords", "maxQuality", "maxFileSizeGB"];
function queuePlaybackSettings(state: SettingsSyncState, snapshot: Settings, keys: readonly (keyof Settings)[]): void {
  const view = appliedNativeProjection, changed = keys.filter((key) => PLAYBACK_SETTING_KEYS.includes(key));
  if (!view || !changed.length) return;
  const owner = view.profiles.find((profile) => profile.main)!;
  const target = hostTarget(view, owner);
  const old = Object.values(state.hostIntents).find((edit) => !edit.intent.global && edit.intent.target.profileId === target.profileId
    && edit.intent.target.binding === target.binding && "playback" in edit.intent.fields);
  const patch = mergeWebappSettingsPatchIntoProfile({}, snapshot, changed).playback as Record<string, unknown>;
  const values = { ...old?.settingValues, ...Object.fromEntries(changed.map((key) => [key, snapshot[key]])) };
  const intent = createHostIntent(target, { playback: { ...(old?.intent.fields.playback as Record<string, unknown> ?? {}), ...patch } }, false, journalPageId);
  enqueueHostEdit(state, { intent, revision: ++state.revision, settingValues: values });
}

function queueProfileLook(state: SettingsSyncState, profileId: string, binding: string, look: Partial<ProfileLook>): void {
  const view = appliedNativeProjection, profile = view?.profiles.find((row) => row.id === profileId && row.binding === binding);
  if (!state.session || !view || !profile || profile.pending || profile.locked || profile.kids) return;
  const target = hostTarget(view, profile), id = JSON.stringify(target), prior = state.profileIntents[id];
  const complete = { ...prior?.look, ...look }, settings = nativeLookSettings(complete);
  state.profileIntents[id] = { intent: createProfileIntent(target, settings), revision: ++state.revision, look: complete };
}
function nativeLookSettings(complete: Partial<ProfileLook>): Record<string, any> {
  const settings: Record<string, any> = {}, playback: Record<string, unknown> = {};
  if (complete.accentID !== undefined) settings.accent = complete.accentID;
  if (complete.background !== undefined) settings.oled = complete.background === "oled";
  if (complete.textScale !== undefined) settings.textScale = complete.textScale;
  if (complete.audioLang !== undefined) playback.audioLang = complete.audioLang;
  if (complete.subtitleLang !== undefined) playback.subtitleLang = complete.subtitleLang;
  if (complete.subtitlesMode !== undefined) playback.forced = complete.subtitlesMode;
  if (Object.keys(playback).length) settings.playback = playback;
  return settings;
}
registerNativeLookSyncPusher((profileId, binding, patch) => {
  const state = settingsSyncState;
  if (state.suppressUpDepth > 0) return;
  discardTransferredIntents(state);
  queueProfileLook(state, profileId, binding, patch);
  persistIntents(state); scheduleIntentPush(state, SETTINGS_PUSH_DELAY);
});

registerWatchlistSyncPusher((item, added) => {
  const state = settingsSyncState, view = appliedNativeProjection;
  const profile = view?.profiles.find((profile) => profile.id === activeProfileId());
  if (!state.session || !view || !profile || profile.pending || profile.locked || profile.kids) return false;
  discardTransferredIntents(state);
  try {
    const field = watchlistField(item.id, item.type ?? ""), value = added ? watchlistValue(item, Date.now() / 1000) : null;
    const intent = createHostIntent(hostTarget(view, profile), { [field]: value }, false, journalPageId);
    enqueueHostEdit(state, { intent, revision: ++state.revision });
    persistIntents(state);
    scheduleIntentPush(state, 350);
    window.dispatchEvent(new Event("vortx:watchlist-changed"));
    return true;
  } catch { return false; }
});

let journalClientId: string | undefined;
function randomSyncId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const value = crypto.getRandomValues(new Uint8Array(16)); value[6] = (value[6] & 15) | 64; value[8] = (value[8] & 63) | 128;
  const hex = Array.from(value, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const journalPageId = randomSyncId();

function journalOwner(key: string): { id?: string; until?: number } {
  try { return JSON.parse(localStorage.getItem(key + ".owner") ?? "{}"); } catch { return {}; }
}

function claimJournal(state: SettingsSyncState, key: string): boolean {
  const owner = journalOwner(key);
  if (owner.id !== journalPageId && Number(owner.until) > Date.now()) return false;
  try {
    localStorage.setItem(key + ".owner", JSON.stringify({ id: journalPageId, until: Date.now() + 30_000 }));
    state.journalOwners.add(key);
  } catch { /* Storage unavailable: the current tab still retains its in-memory intent. */ }
  return true;
}

function ownsJournals(state: SettingsSyncState): boolean {
  return [...state.journalOwners].every((key) => {
    const owner = journalOwner(key);
    try { return owner.id === journalPageId || (owner.id === undefined && localStorage.getItem(key) !== null); }
    catch { return true; /* Storage unavailable: keep this page's in-memory queue. */ }
  });
}

function releaseJournals(state: SettingsSyncState): void {
  for (const key of state.journalOwners) {
    if (journalOwner(key).id !== journalPageId) continue;
    // Keep the ownership receipt after ACK. A suspended older page must see that its journal
    // transferred, even after the recovering page removes the completed journal itself.
    try { localStorage.setItem(key + ".owner", JSON.stringify({ id: journalPageId, until: 0 })); }
    catch { /* lease will expire */ }
  }
}

function discardTransferredIntents(state: SettingsSyncState): void {
  if (ownsJournals(state)) return;
  // Another page recovered this inactive page's exact durable journal. Its writer now owns those
  // intents; this page must not replay an older copy when it resumes or accepts a fresh edit.
  state.pendingKeys.clear(); state.pendingSettings = null;
  state.nativeSettingKeys.clear();
  state.nativeSettingBindings = {};
  state.hostIntents = {}; state.hostCounter = 0; state.profileIntents = {}; state.addonEvents = {};
  state.retainedNativeSettings = {};
  state.addonIntents = Object.create(null); state.progressIntents = Object.create(null);
  state.journalSources.clear(); state.journalOwners.clear();
}

function journalKey(session: Session): string {
  if (!journalClientId) {
    try { journalClientId = sessionStorage.getItem("vortx.web.sync-client.v1") ?? undefined; } catch { /* optional */ }
    journalClientId ??= randomSyncId();
    try { sessionStorage.setItem("vortx.web.sync-client.v1", journalClientId); } catch { /* in-memory queue remains */ }
  }
  const prefix = "vortx.web.sync-intents.v1." + encodeURIComponent(session.account.id) + ".";
  let key = prefix + journalClientId;
  const owner = journalOwner(key);
  if (owner.id !== journalPageId && Number(owner.until) > Date.now()) {
    journalClientId = randomSyncId();
    try { sessionStorage.setItem("vortx.web.sync-client.v1", journalClientId); } catch { /* optional */ }
    key = prefix + journalClientId;
  }
  return key;
}

// Only explicit account edits go in this journal. It carries no token, data key, or socket URL.
// A synchronous write happens before scheduling network work, including before pagehide/reload.
function persistIntents(state: SettingsSyncState): void {
  if (!state.session) return;
  const settings: Partial<Settings> = {};
  for (const key of state.pendingKeys) {
    if (state.pendingSettings) Object.assign(settings, { [key]: state.pendingSettings[key] });
  }
  try {
    if (!hasPendingIntents(state)) {
      localStorage.removeItem(journalKey(state.session));
      for (const [key, raw] of state.journalSources) {
        if (localStorage.getItem(key) === raw) localStorage.removeItem(key);
      }
      state.journalSources.clear();
      releaseJournals(state);
      state.journalOwners.clear();
    } else {
      const key = journalKey(state.session);
      claimJournal(state, key);
      localStorage.setItem(key, JSON.stringify({
        accountId: state.session.account.id, editedAt: Date.now(),
        settings, nativeSettingKeys: [...state.nativeSettingKeys], nativeSettingBindings: state.nativeSettingBindings,
        retainedNativeSettings: state.retainedNativeSettings,
        addons: state.addonIntents, progress: state.progressIntents, revision: state.revision,
        host: state.hostIntents, hostCounter: state.hostCounter, profile: state.profileIntents, addonEvents: state.addonEvents,
      }));
      // Transfer only after the complete merged checkpoint is durable. Older source bytes must
      // not outlive this receipt: otherwise a partial ACK or explicit supersession could replay
      // their obsolete edits on the next reload. Keep ownership receipts fencing older pages.
      for (const [source, raw] of state.journalSources) {
        if (source !== key && localStorage.getItem(source) === raw) localStorage.removeItem(source);
      }
      state.journalSources.clear();
    }
  } catch { /* Storage unavailable: retain the live queue and retry while the tab remains open. */ }
}

function restoreIntents(state: SettingsSyncState, onlyOrphans = false): boolean {
  if (!state.session) return false;
  try {
    const liveHostAddresses = new Set(Object.values(state.hostIntents).map((edit) => hostAddress(edit.intent)));
    const keys = new Set([journalKey(state.session)]);
    const prefix = "vortx.web.sync-intents.v1.";
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key?.startsWith(prefix)) keys.add(key);
    }
    const journals = [...keys].flatMap((key) => {
      try {
        const raw = localStorage.getItem(key);
        if (!raw) return [];
        const saved = JSON.parse(raw);
        if (onlyOrphans && journalOwner(key).id === journalPageId) return [];
        return saved.accountId === state.session!.account.id && claimJournal(state, key) ? [{ key, raw, saved }] : [];
      } catch { return []; }
    }).sort((a, b) => (Number(a.saved.editedAt) || 0) - (Number(b.saved.editedAt) || 0));
    const snapshot = copySettings(state.ownerSettingsSnapshot);
    for (const { key: sourceKey, raw, saved } of journals) {
      state.journalSources.set(sourceKey, raw);
      state.revision = Math.max(state.revision, Number(saved.revision) || 0);
      if (Number.isSafeInteger(saved.hostCounter) && saved.hostCounter >= 0) state.hostCounter = Math.max(state.hostCounter, saved.hostCounter);
      if (saved.settings && typeof saved.settings === "object") {
        for (const key of Object.keys(saved.settings) as (keyof Settings)[]) {
          const value = saved.settings[key];
          if ((onlyOrphans && state.pendingKeys.has(key)) || !(key in snapshot) || (key === "sourceOrder"
            ? !Array.isArray(value) || !value.every((v: unknown) => typeof v === "string")
            : typeof value !== typeof snapshot[key])) continue;
          Object.assign(snapshot, { [key]: value });
          state.pendingKeys.add(key);
          if (Array.isArray(saved.nativeSettingKeys) && saved.nativeSettingKeys.includes(key)) state.nativeSettingKeys.add(key);
          if (typeof saved.nativeSettingBindings?.[key] === "string") state.nativeSettingBindings[key] = saved.nativeSettingBindings[key];
        }
      }
      if (state.pendingKeys.size) {
        state.pendingSettings = snapshot;
        state.ownerSettingsSnapshot = snapshot;
      }
      for (const [target, raw] of Object.entries(saved.retainedNativeSettings ?? {})) {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
        const delta: Partial<Settings> = {};
        for (const [key, value] of Object.entries(raw)) {
          if (key in snapshot && (key === "sourceOrder" ? Array.isArray(value) && value.every((item) => typeof item === "string")
            : typeof value === typeof snapshot[key as keyof Settings])) Object.assign(delta, { [key]: value });
        }
        if (Object.keys(delta).length) state.retainedNativeSettings[target] = { ...state.retainedNativeSettings[target], ...delta };
      }
      for (const value of Object.values(saved.addons ?? {})) {
        const intent = value as AddonIntent;
        if (typeof intent?.url !== "string" || typeof intent.added !== "boolean" || !Number.isFinite(intent.at)) continue;
        const key = addonIntentKey(intent);
        if (!state.addonIntents[key] || state.addonIntents[key].at <= intent.at) state.addonIntents[key] = intent;
      }
      for (const [scope, value] of Object.entries(saved.progress ?? {})) {
        const intent = value as ProgressIntent;
        if (!intent || !Array.isArray(intent.entries) || !Array.isArray(intent.tombstones)) continue;
        state.progressIntents[scope] = {
          entries: mergeWebProgress(state.progressIntents[scope]?.entries, intent.entries),
          tombstones: mergeWebProgressTombstones(state.progressIntents[scope]?.tombstones, tombstonesFrom(intent.tombstones)),
          revision: ++state.revision,
          binding: typeof intent.binding === "string" ? intent.binding : undefined,
          scope: typeof intent.scope === "string" ? intent.scope : undefined,
        };
      }
      for (const raw of Object.values(saved.host ?? {})) {
        try {
          const edit = raw as QueuedHostEdit, captured = edit.intent;
          if (captured.target.scope !== `account.${state.session.account.id.toLowerCase()}` || !Number.isSafeInteger(edit.revision)) continue;
          const intent = createHostIntent(captured.target, captured.fields, captured.global, captured.actor);
          if (Object.keys(intent.fields).length !== 1) continue;
          if (captured.registers) intent.registers = captured.registers;
          if (captured.accepted === true) intent.accepted = true;
          const settingKey = edit.settingKey && hostSettingField(edit.settingKey) === Object.keys(intent.fields)[0] ? edit.settingKey : undefined;
          const settingValues = !intent.global && "playback" in intent.fields && edit.settingValues ? edit.settingValues : undefined;
          if (settingValues && Object.keys(settingValues).some((key) => !PLAYBACK_SETTING_KEYS.includes(key as keyof Settings))) continue;
          if (settingValues) {
            const wire = mergeWebappSettingsPatchIntoProfile({}, { ...state.ownerSettingsSnapshot, ...settingValues }, Object.keys(settingValues) as (keyof Settings)[]).playback;
            if (JSON.stringify(Object.entries(wire as Record<string, unknown>).sort()) !== JSON.stringify(Object.entries(intent.fields.playback as Record<string, unknown>).sort())) continue;
          }
          if (intent.global && !settingKey) continue;
          if (onlyOrphans && liveHostAddresses.has(hostAddress(intent))) continue;
          // Journals are already ordered by editedAt; per-page revision counters are not a
          // cross-page clock. Keep the latest restored address, not every old binding capture.
          enqueueHostEdit(state, { intent, revision: edit.revision, settingKey, settingValues });
        } catch { /* Invalid durable DTO cannot become a native host edit. */ }
      }
      for (const raw of Object.values(saved.profile ?? {})) {
        try {
          const edit = raw as QueuedProfileEdit;
          if (edit.intent.target.scope !== `account.${state.session.account.id.toLowerCase()}` || !Number.isSafeInteger(edit.revision)) continue;
          const intent = createProfileIntent(edit.intent.target, edit.intent.settings);
          if (!edit.look || Object.keys(edit.look).some((key) => !PROFILE_SCOPED_SETTING_KEYS.includes(key as keyof Settings))
            || JSON.stringify(createProfileIntent(edit.intent.target, nativeLookSettings(edit.look)).settings) !== JSON.stringify(intent.settings)) continue;
          if (edit.intent.event) intent.event = edit.intent.event;
          const id = JSON.stringify(intent.target);
          if (!onlyOrphans || !state.profileIntents[id]) state.profileIntents[id] = { intent, revision: edit.revision, look: edit.look };
        } catch { /* Invalid stored intent cannot author a native event. */ }
      }
      for (const [id, raw] of Object.entries(saved.addonEvents ?? {})) {
        const edit = raw as QueuedAddonEvent;
        if (edit?.intent?.target?.scope === `account.${state.session.account.id.toLowerCase()}` && Array.isArray(edit.intent.mutations)
          && (!onlyOrphans || !state.addonEvents[id])) state.addonEvents[id] = edit;
      }
    }
    return journals.length > 0;
  } catch { return false; /* Invalid journals cannot become an account write. */ }
}

let settingsSyncState: SettingsSyncState;
// Every settings mutation, including one queued under a refreshed session, runs after the previous one.
// Jobs still verify their captured state before starting, so a queued write from a departed account drops.
let settingsWriteTail: Promise<void> = Promise.resolve();

/** Bind async readers to the descriptor and key owned when they start. In-memory callers
 *  may omit storage entirely; a present but unowned descriptor never grants that exception. */
function hasSessionDescriptor(): boolean {
  return sessionOwner().mode !== "memory"; // denied reads are never absence/memory permission
}
function captureStoredSession(session: Session, requireStored = false): () => boolean {
  const owns = captureSessionOwnership(session);
  return () => (!requireStored || sessionOwner().mode === "persisted") && owns();
}

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
  const requiresStoredSession = !!session && hasSessionDescriptor();
  const state: SettingsSyncState = {
    session,
    requiresStoredSession,
    ownsStoredSession: session ? captureStoredSession(session, requiresStoredSession) : () => true,
    suppressUpDepth: 0,
    pushTimer: undefined,
    pendingKeys: new Set(),
    nativeSettingKeys: new Set(),
    nativeSettingBindings: {},
    retainedNativeSettings: {},
    pendingSettings: null,
    writeQueued: false,
    profileAtLastChange: activeProfileId(),
    ownerSettingsSnapshot: copySettings(ownerSnapshot ?? initialOwnerSettings()),
    addonIntents: Object.create(null), progressIntents: Object.create(null), hostIntents: Object.create(null), profileIntents: Object.create(null), addonEvents: Object.create(null), hostCounter: 0, revision: 0, retryAttempt: 0, upgradeRequired: false,
    journalSources: new Map(),
    journalOwners: new Set(),
  };
  restoreIntents(state);
  return state;
}

settingsSyncState = createSettingsSyncState(null);

function bindSettingsSyncState(session: Session | null): void {
  if (sameAccountScope(settingsSyncState.session, session)) {
    settingsSyncState.requiresStoredSession ||= !!session && hasSessionDescriptor();
    settingsSyncState.session = session;
    settingsSyncState.ownsStoredSession = session ? captureStoredSession(session, settingsSyncState.requiresStoredSession) : () => true;
    return;
  }
  if (settingsSyncState.pushTimer) clearTimeout(settingsSyncState.pushTimer);
  const nativeHostReset = appliedNativeProjection ? NATIVE_HOST_SETTING_DEFAULTS : {};
  appliedNativeProjection = null;
  setNativeAccountProjection(null);
  setNativeProfiles("", null);
  releaseJournals(settingsSyncState);
  let resetSnapshot: Settings | undefined;
  withSuppressedUp(() => {
    resetSnapshot = updateSettings({
      ...ACCOUNT_SCOPED_SETTING_DEFAULTS,
      ...nativeHostReset,
      sourceOrder: [...(ACCOUNT_SCOPED_SETTING_DEFAULTS.sourceOrder ?? [])],
    });
  });
  settingsSyncState = createSettingsSyncState(session, resetSnapshot);
  if (session) {
    withSuppressedUp(() => updateSettings(settingsSyncState.ownerSettingsSnapshot));
    scheduleIntentPush(settingsSyncState, 350);
  }
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
  if (hasNativeProfiles() && !state.session) return; // Retired page/module cannot restore another account's owner snapshot.
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
  isCurrent: () => boolean = () => true,
  nativeCaptured = false,
): Promise<void> {
  await mutateSyncDoc(session, (doc) => {
    const changed = new Set(changedKeys);
    if (("nativeSync" in doc || nativeCaptured) && changedKeys.some((key) => !API_KEY_SETTING_KEYS.includes(key))) {
      // Historical profileEdits is not a causal native edit event. Keep explicit native intent
      // durable until a compatible event writer exists; a successful legacy PUT is not its ACK.
      throw new Error("Native profile settings require a compatible edit event; intent remains queued.");
    }
    const mainId = mainProfileId(doc);
    if (!mainId && changedKeys.some((key) => key in ACCOUNT_SCOPED_SETTING_DEFAULTS && !API_KEY_SETTING_KEYS.includes(key))) {
      throw new Error("Account profile projection is not available; settings intent remains queued.");
    }
    if (mainId && changedKeys.some((key) => !API_KEY_SETTING_KEYS.includes(key))) {
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
  }, isCurrent);
}

async function pushHostEdit(state: SettingsSyncState, edit: QueuedHostEdit, isSessionCurrent: () => boolean): Promise<{ contents: Record<string, unknown>; version?: number }> {
  const session = state.session!;
  const isCurrent = () => isSessionCurrent() && state.hostIntents[hostIntentKey(edit.intent)] === edit;
  await mutateSyncDoc(session, (doc) => {
    const result = applyHostIntent(doc, edit.intent, state.hostCounter);
    state.hostCounter = result.counter;
    persistIntents(state); // Retain actor/clock/value before any uncertain transport completion.
    return result.alreadyApplied ? false : undefined;
  }, isCurrent, {
    rejected: () => { delete edit.intent.registers; delete edit.intent.accepted; persistIntents(state); },
    accepted: () => { edit.intent.accepted = true; persistIntents(state); },
  });
  if (!isCurrent()) throw new Error("Account session changed.");
  const readback = await fetchSync(session, { isCurrent });
  if (!isCurrent() || readback.decryptFailed || !readback.contents) throw new Error("Waiting for the account edit receipt.");
  const receipt = applyHostIntent(readback.contents, edit.intent, state.hostCounter);
  if (!receipt.alreadyApplied) throw new Error("Waiting for the account edit receipt.");
  state.hostCounter = receipt.counter;
  return { contents: readback.contents, version: readback.version };
}

async function pushProfileEdit(state: SettingsSyncState, edit: QueuedProfileEdit, isSessionCurrent: () => boolean): Promise<{ contents: Record<string, unknown>; version?: number }> {
  const session = state.session!, id = JSON.stringify(edit.intent.target);
  const isCurrent = () => isSessionCurrent() && state.profileIntents[id] === edit;
  await mutateSyncDoc(session, async (doc) => {
    const changed = await applyProfileIntent(doc, edit.intent);
    persistIntents(state); // Freeze immutable event bytes before transport can become uncertain.
    return changed ? undefined : false;
  }, isCurrent);
  const readback = await fetchSync(session, { isCurrent });
  if (!isCurrent() || !readback.contents || !profileIntentAcknowledged(readback.contents, edit.intent)) throw new Error("Waiting for native profile receipt.");
  return { contents: readback.contents, version: readback.version };
}

async function pushNativeAddonEvent(state: SettingsSyncState, addons: AddonIntent[], isSessionCurrent: () => boolean): Promise<{ contents: Record<string, unknown>; version?: number }> {
  const session = state.session!, view = appliedNativeProjection;
  const profile = view?.profiles.find((row) => row.main);
  if (!view || !profile || addons.some((intent) => intent.profileId !== profile.id || intent.binding !== profile.binding)) throw new Error("Native owner add-on target changed; intent remains queued.");
  const target = hostTarget(view, profile), id = JSON.stringify(target), revisions = Object.fromEntries(addons.map((intent) => [addonIntentKey(intent), intent.revision]));
  let edit = state.addonEvents[id];
  if (!edit || canonicalJSON(edit.revisions) !== canonicalJSON(revisions)) {
    edit = { intent: { target, mutations: addons.map((intent) => ({ url: intent.url, added: intent.added, descriptor: intent.descriptor })) }, revision: ++state.revision, revisions };
    state.addonEvents[id] = edit; persistIntents(state);
  }
  // Per-page revisions can collide across recovered journals. A frozen source must represent
  // these exact queued effects, not merely share their revision numbers. Never repair/rebuild
  // mismatched uncertain bytes and subsequently retire a different user's pending add-on.
  const effect = (mutation: { url: string; added: boolean; descriptor?: { manifest: unknown } }) =>
    [addonIdentity(mutation.url), mutation.added, mutation.added ? mutation.descriptor?.manifest ?? null : null];
  const effects = (mutations: typeof addons | AddonEventIntent["mutations"]) => mutations.map(effect).sort((a, b) => String(a[0]).localeCompare(String(b[0])));
  if (canonicalJSON(edit.intent.target) !== canonicalJSON(target) || canonicalJSON(effects(edit.intent.mutations)) !== canonicalJSON(effects(addons))) {
    throw new Error("Recovered add-on source does not match its queued target; intent remains retained.");
  }
  const captured = edit, isCurrent = () => isSessionCurrent() && state.addonEvents[id] === captured;
  await mutateSyncDoc(session, (doc) => {
    const changed = applyAddonEventIntent(doc, captured.intent);
    persistIntents(state);
    return changed ? undefined : false;
  }, isCurrent);
  const readback = await fetchSync(session, { isCurrent });
  if (!isCurrent() || !readback.contents || !addonEventAcknowledged(readback.contents, captured.intent)) throw new Error("Waiting for native add-on receipt.");
  if (state.addonEvents[id] === captured) delete state.addonEvents[id];
  return { contents: readback.contents, version: readback.version };
}

function applyHostReadback(readback: { contents: Record<string, unknown>; version?: number }, session: Session): void {
  // Apply this authenticated read after retiring its optimistic overlay. Delayed receive reads
  // below this revision are fenced, including a socket-triggered GET started before the PUT.
  if (!receiveState || readback.version === undefined || receiveState.receivedVersion === undefined || readback.version >= receiveState.receivedVersion) {
    const applied = applySyncDoc(readback.contents);
    if (receiveState && sameSession(receiveState.session, session)) {
      receiveState.receivedVersion = readback.version;
      receiveState.projectionPending = !applied;
      if (applied) receiveState.appliedVersion = readback.version;
    }
  }
}

/** Tombstone-identity normalization: trim + lowercase, byte-for-byte matching the app's
 *  AddonTombstones.normalize, so a URL the web writes into doc.webAddonRemovals matches what the app
 *  compares its installed add-ons against. */
function normalizeAddonUrl(u: string): string {
  return u.trim().toLowerCase();
}

// Descriptor membership preserves case-sensitive path/query/credential bytes. Legacy tombstones
// continue to use their established normalization until every client supports exact membership.
function addonMembershipKey(u: string): string {
  const value = u.trim();
  const match = /^([a-z][a-z0-9+.-]*):\/\/([^/?#]+)([\s\S]*)$/i.exec(value);
  if (!match) return value;
  const authority = match[2];
  const split = authority.lastIndexOf("@");
  const credentials = split >= 0 ? authority.slice(0, split + 1) : "";
  const host = authority.slice(split + 1).toLowerCase();
  return `${match[1].toLowerCase()}://${credentials}${host}${match[3]}`;
}
function addonIntentKey(intent: AddonIntent): string {
  return addonMembershipKey(intent.url) + (intent.binding ? `|${intent.profileId}|${intent.binding}` : "");
}

/** Push the webapp's installed add-ons up to the account (the doc.addons web sibling), so add-ons added
 *  on the web reach the user's other devices AND the native apps. Cinemeta is excluded (a universal
 *  built-in). Serialized + coalesced by the caller. Fail-soft. */
async function pushAddons(
  session: Session,
  intents: AddonIntent[],
  isCurrent: () => boolean,
): Promise<void> {
    // Pre-resolve each URL's FULL manifest (async, outside the mutate): the app installs from doc.addons
    // network-free and DROPS any entry without a manifest, so a URL-only entry would never reach the apps.
    const resolved = new Map<string, { transportUrl: string; name: string; manifest: unknown }>();
    for (const intent of intents) if (intent.descriptor) resolved.set(intent.url, intent.descriptor);
    await Promise.all(
      intents
        .filter((intent) => intent.added && !intent.descriptor && intent.url !== CINEMETA_URL)
        .map(async ({ url: u }) => {
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
      const native = intents.some((intent) => intent.binding) ? projectNativeSync(doc, `account.${session.account.id.toLowerCase()}`) : null;
      if (intents.some((intent) => intent.binding) && !native) throw new Error("Native add-on target is unavailable; intent remains queued.");
      if (native) for (const intent of intents) {
        const owner = native.profiles.find((profile) => profile.main)!;
        if (intent.profileId && (intent.profileId !== owner.id || intent.binding !== owner.binding)) {
          throw new Error("Native add-on target changed or requires an own-account event; intent remains queued.");
        }
      }
      if ("nativeSync" in doc) {
        // The retained doc.addons aggregate is only an import baseline once nativeSync exists.
        // Native membership needs a public webAddonEdits event/receipt, not a legacy PUT ACK.
        throw new Error("Native add-ons require compatible causal edit events; intent remains queued.");
      }
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
      // Change only explicit membership intent. A device's inherited store must not overwrite remote
      // additions or copy account A's add-ons into a newly signed-in account B.
      const descriptors: unknown[] = [...(Array.isArray(doc.addons) ? doc.addons : [])];
      for (const intent of intents) {
        const u = intent.url;
        if (u === CINEMETA_URL) continue;
        for (let i = descriptors.length - 1; i >= 0; i--) {
          const priorUrl = addonUrl(descriptors[i]);
          if (priorUrl && addonMembershipKey(priorUrl) === addonMembershipKey(u)) descriptors.splice(i, 1);
        }
        if (!intent.added || appUrls.has(u)) continue;
        const prior = priorByUrl.get(u);
        const descriptor = resolved.get(u) ?? (prior?.manifest ? prior : undefined);
        if (!descriptor) throw new Error("Add-on manifest unavailable; retry pending install.");
        descriptors.push({ ...(prior && typeof prior === "object" ? prior : {}), ...descriptor });
      }
      doc.addons = descriptors;

      // Removal tombstones, from the EXPLICIT add/remove hints (never inferred by diffing, which would
      // false-tombstone app add-ons). doc.removedAddons {url: epochMs} is the web-internal record (carries
      // timestamps so a re-add can clear it). doc.webAddonRemovals is the flat string[] the APP reads and
      // folds into its uninstall set (VortXSyncManager: "web agent owns this write; we only READ it").
      for (const intent of intents) {
        applyAddonIntents(doc, intent.added ? { added: [intent.url] } : { removed: [intent.url] }, intent.at);
      }
    }, isCurrent);
}

// Capture exact add/remove intent and the already validated manifest before scheduling any upload.
registerAddonsSyncPusher((hint) => {
  if (!currentSession() || settingsSyncState.suppressUpDepth > 0) return;
  const state = settingsSyncState;
  discardTransferredIntents(state);
  const url = hint?.added ?? hint?.removed;
  if (!url) return;
  const active = appliedNativeProjection?.profiles.find((profile) => profile.id === activeProfileId());
  const target = active && appliedNativeProjection!.addonsByProfile[active.id] === appliedNativeProjection!.ownerAddons
    ? appliedNativeProjection!.profiles.find((profile) => profile.main) : active;
  const intent: AddonIntent = { url, added: !!hint?.added, profileId: target?.id, binding: target?.binding,
    at: Date.now(), revision: ++state.revision };
  const key = addonIntentKey(intent);
  state.addonIntents[key] = { ...intent,
    at: Math.max(Date.now(), (state.addonIntents[key]?.at ?? 0) + 1), revision: ++state.revision,
    descriptor: hint?.descriptor ? { transportUrl: hint.descriptor.transportUrl,
      name: hint.descriptor.manifest.name, manifest: hint.descriptor.manifest } : undefined };
  persistIntents(state);
  scheduleIntentPush(state, 350);
}, () => {
  const session = currentSession();
  const state = settingsSyncState;
  const profileId = activeProfileId();
  const binding = appliedNativeProjection?.profiles.find((profile) => profile.id === profileId)?.binding;
  return () => state === settingsSyncState && sameAccountScope(state.session, session) && (!binding ||
    (activeProfileId() === profileId && appliedNativeProjection?.profiles.find((profile) => profile.id === profileId)?.binding === binding));
});

// Push the ACTIVE profile's web watch-progress up to the bilateral doc.webProgress field. Owner progress
// goes top-level (doc.webProgress.owner) to match the app's convention; overlay progress under
// .byProfile[profileId]. The app merges this into watch history (LWW by lastWatched), NEVER into
// libraryItem. Fail-soft. (Read-down lives in applySyncDoc.)
async function pushWebProgress(session: Session,
  scope = isOwnerProfile(activeProfileId()) ? "" : activeProfileId(),
  intent: ProgressIntent = { entries: webProgressEntries(), tombstones: webProgressTombstones(), revision: 0 },
  isCurrent: () => boolean = () => true,
): Promise<void> {
    const { entries, tombstones } = intent;
    const owner = scope === "";
    const pid = scope;
    await mutateSyncDoc(session, (doc) => {
      const native = intent.binding ? projectNativeSync(doc, `account.${session.account.id.toLowerCase()}`) : null;
      if (intent.binding && !native) throw new Error("Native progress target is unavailable; intent remains queued.");
      if (native) {
        const profile = native.profiles.find((profile) => owner ? profile.main : profile.id === scope);
        if (!profile || profile.pending || (intent.binding && profile.binding !== intent.binding)) {
          throw new Error("Native progress binding changed; intent remains queued for its original account slot.");
        }
        // webProgress entries lack the native watch operation/source witness. Do not retire a
        // durable own-slot edit merely because an unused legacy sibling PUT was accepted.
        throw new Error("Native watch progress requires compatible causal sync support; browser intent remains queued.");
      }
      if ("nativeSync" in doc) throw new Error("Unbound browser watch progress cannot be attributed to a native account slot; intent remains queued.");
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
    }, isCurrent);
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
        ...existing,
        ...r,
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

// recordProgress fires ~every 5s during playback. Journal the edited row immediately and send within
// one second; a profile switch, failed PUT or closed page cannot lose or retarget that snapshot.
const WEBPROGRESS_PUSH_DELAY = 1_000;
registerCwSyncPusher((hint) => {
  if (settingsSyncState.suppressUpDepth > 0) return; // hydration merges CW too; don't echo synced progress back up
  if (!currentSession()) return; // signed out: progress stays local
  if (!hint) return; // automatic writes only carry the explicit edit, never an inherited account store
  const state = settingsSyncState;
  const scope = isOwnerProfile(activeProfileId()) ? "" : activeProfileId();
  discardTransferredIntents(state);
  const binding = appliedNativeProjection?.profiles.find((profile) => profile.id === activeProfileId())?.binding;
  const previous = state.progressIntents[scope];
  if (previous?.binding && binding !== previous.binding) state.progressIntents[`${scope}|${previous.binding}`] = { ...previous, scope };
  const prior = previous?.binding === binding ? previous : undefined;
  const entries = hint.entry ? [{ id: hint.entry.id, type: hint.entry.type, v: hint.entry.resumeId,
    t: hint.entry.position, d: hint.entry.duration, lastWatched: hint.entry.updatedAt,
    name: hint.entry.name, poster: hint.entry.poster }] : [];
  state.progressIntents[scope] = {
    entries: mergeWebProgress(prior?.entries, entries),
    tombstones: mergeWebProgressTombstones(prior?.tombstones, hint.removal ? [hint.removal] : []),
    revision: ++state.revision,
    binding, scope,
  };
  persistIntents(state);
  scheduleIntentPush(state, WEBPROGRESS_PUSH_DELAY);
}, () => {
  const state = settingsSyncState, session = currentSession(), profileId = activeProfileId();
  const binding = appliedNativeProjection?.profiles.find((profile) => profile.id === profileId)?.binding;
  return () => state === settingsSyncState && sameAccountScope(state.session, session) && activeProfileId() === profileId &&
    appliedNativeProjection?.profiles.find((profile) => profile.id === profileId)?.binding === binding;
});
if (typeof window !== "undefined") {
  window.addEventListener("pagehide", () => {
    if (settingsSyncState.pushTimer) clearTimeout(settingsSyncState.pushTimer);
    queueSettingsPush(settingsSyncState); // durable intent survives even when pagehide fetch is canceled
  });
}

function syncableSettingsKeys(
  changedKeys: readonly (keyof Settings)[],
): (keyof Settings)[] {
  // Explicit edits are durable even while the first account GET is pending. The writer separately
  // waits for a usable main-profile projection; hydration never manufactures a dirty key.
  return changedKeys.filter((key) => key in ACCOUNT_SCOPED_SETTING_DEFAULTS || (!!appliedNativeProjection && key in NATIVE_HOST_SETTING_DEFAULTS));
}

function queueSettingsPush(state: SettingsSyncState): void {
  state.pushTimer = undefined;
  discardTransferredIntents(state);
  if (state !== settingsSyncState || !state.session || state.upgradeRequired || !hasPendingIntents(state) || state.writeQueued) return;
  state.writeQueued = true;

  const write = async (): Promise<void> => {
    if (state !== settingsSyncState || !state.session || state.upgradeRequired) {
      state.writeQueued = false;
      return;
    }
    const session = state.session;
    const isCurrent = () => state === settingsSyncState && !state.upgradeRequired && sameSession(state.session, session) && state.ownsStoredSession() && ownsJournals(state);
    let failed = Object.keys(state.retainedNativeSettings).length > 0;
    const attempt = async (job: () => Promise<void>): Promise<void> => {
      try { if (isCurrent()) await job(); } catch (error) {
        failed = true;
        if (error instanceof SyncUpgradeRequiredError) {
          state.upgradeRequired = true;
          persistIntents(state);
          notifyReceiveStatus();
        }
      }
    };
    try {
      for (const [id, edit] of Object.entries(state.hostIntents)) await attempt(async () => {
        if (!edit.intent.global && "playback" in edit.intent.fields && Object.values(state.profileIntents).some((profile) =>
          profile.intent.target.profileId === edit.intent.target.profileId && profile.intent.target.binding === edit.intent.target.binding
          && profile.intent.event && profile.intent.settings.playback)) throw new Error("Waiting for the earlier profile playback receipt.");
        const readback = await pushHostEdit(state, edit, isCurrent);
        if (!isCurrent()) throw new Error("Account session changed.");
        if (state.hostIntents[id]?.revision === edit.revision) delete state.hostIntents[id];
        if (edit.settingKey) {
          const key = edit.settingKey, value = Object.values(edit.intent.fields)[0];
          const target = `${edit.intent.target.profileId}|${edit.intent.target.binding}`;
          if (state.nativeSettingBindings[key] === target && JSON.stringify(state.pendingSettings?.[key]) === JSON.stringify(value)) {
            state.pendingKeys.delete(key); state.nativeSettingKeys.delete(key); delete state.nativeSettingBindings[key];
          }
          if (JSON.stringify(state.retainedNativeSettings[target]?.[key]) === JSON.stringify(value)) {
            delete state.retainedNativeSettings[target][key];
            if (!Object.keys(state.retainedNativeSettings[target]).length) delete state.retainedNativeSettings[target];
          }
          if (!state.pendingKeys.size) state.pendingSettings = null;
        }
        if (edit.settingValues) {
          const target = `${edit.intent.target.profileId}|${edit.intent.target.binding}`;
          for (const [rawKey, value] of Object.entries(edit.settingValues)) {
            const key = rawKey as keyof Settings;
            if (state.nativeSettingBindings[key] === target && JSON.stringify(state.pendingSettings?.[key]) === JSON.stringify(value)) {
              state.pendingKeys.delete(key); state.nativeSettingKeys.delete(key); delete state.nativeSettingBindings[key];
            }
            if (JSON.stringify(state.retainedNativeSettings[target]?.[key]) === JSON.stringify(value)) delete state.retainedNativeSettings[target][key];
          }
          if (!Object.keys(state.retainedNativeSettings[target] ?? {}).length) delete state.retainedNativeSettings[target];
          if (!state.pendingKeys.size) state.pendingSettings = null;
        }
        persistIntents(state);
        withSuppressedUp(() => applyHostReadback(readback, session));
        notifyReceiveStatus();
        window.dispatchEvent(new Event("vortx:watchlist-changed"));
      });
      for (const [id, edit] of Object.entries(state.profileIntents)) await attempt(async () => {
        if (!edit.intent.event && edit.intent.settings.playback && Object.values(state.hostIntents).some((host) => !host.intent.global && "playback" in host.intent.fields
          && host.intent.target.profileId === edit.intent.target.profileId && host.intent.target.binding === edit.intent.target.binding)) throw new Error("Waiting for the earlier host playback receipt.");
        const readback = await pushProfileEdit(state, edit, isCurrent);
        if (!isCurrent() || state.profileIntents[id] !== edit) throw new Error("Account profile intent changed.");
        delete state.profileIntents[id];
        retireNativeLookIntent(edit.intent.target.scope, edit.intent.target.profileId, edit.intent.target.binding, edit.look);
        const target = `${edit.intent.target.profileId}|${edit.intent.target.binding}`;
        for (const [rawKey, value] of Object.entries(edit.look)) {
          const key = rawKey as keyof Settings;
          if (state.nativeSettingBindings[key] === target && JSON.stringify(state.pendingSettings?.[key]) === JSON.stringify(value)) {
            state.pendingKeys.delete(key); state.nativeSettingKeys.delete(key); delete state.nativeSettingBindings[key];
          }
          if (JSON.stringify(state.retainedNativeSettings[target]?.[key]) === JSON.stringify(value)) delete state.retainedNativeSettings[target][key];
        }
        if (!Object.keys(state.retainedNativeSettings[target] ?? {}).length) delete state.retainedNativeSettings[target];
        if (!state.pendingKeys.size) state.pendingSettings = null;
        persistIntents(state); withSuppressedUp(() => applyHostReadback(readback, session)); notifyReceiveStatus();
      });
      // Independent supported API-key deltas must not be starved by a held native settings edit.
      for (const changedKeys of [[...state.pendingKeys].filter((key) => API_KEY_SETTING_KEYS.includes(key)),
        [...state.pendingKeys].filter((key) => !API_KEY_SETTING_KEYS.includes(key) && !(state.nativeSettingKeys.has(key) &&
          (hostSettingField(key) || PLAYBACK_SETTING_KEYS.includes(key) || PROFILE_SCOPED_SETTING_KEYS.includes(key))))]) if (state.pendingSettings && changedKeys.length) {
        await attempt(async () => {
          if (!state.pendingSettings) return;
          const snapshot = copySettings(state.pendingSettings);
          await pushSettings(session, snapshot, changedKeys, isCurrent, changedKeys.some((key) => state.nativeSettingKeys.has(key)));
          if (!isCurrent()) throw new Error("Account session changed.");
          for (const key of changedKeys) {
            if (JSON.stringify(state.pendingSettings?.[key]) === JSON.stringify(snapshot[key])) {
              state.pendingKeys.delete(key); state.nativeSettingKeys.delete(key);
              delete state.nativeSettingBindings[key];
            }
          }
          if (!state.pendingKeys.size) state.pendingSettings = null;
          persistIntents(state);
        });
      }
      const addonGroups = new Map<string, AddonIntent[]>();
      for (const intent of Object.values(state.addonIntents)) {
        const target = JSON.stringify([intent.profileId, intent.binding]);
        addonGroups.set(target, [...(addonGroups.get(target) ?? []), intent]);
      }
      // A held own-slot target cannot block independently supported owner/global membership.
      for (const addons of addonGroups.values()) {
        await attempt(async () => {
          const readback = addons.some((intent) => intent.binding) ? await pushNativeAddonEvent(state, addons, isCurrent) : undefined;
          if (!readback) await pushAddons(session, addons, isCurrent);
          if (!isCurrent()) throw new Error("Account session changed.");
          for (const intent of addons) {
            const key = addonIntentKey(intent);
            if (state.addonIntents[key]?.revision === intent.revision) delete state.addonIntents[key];
          }
          persistIntents(state);
          if (readback) withSuppressedUp(() => applyHostReadback(readback, session));
        });
      }
      for (const [scope, intent] of Object.entries(state.progressIntents)) {
        await attempt(async () => {
          await pushWebProgress(session, intent.scope ?? scope, intent, isCurrent);
          if (!isCurrent()) throw new Error("Account session changed.");
          if (state.progressIntents[scope]?.revision === intent.revision) delete state.progressIntents[scope];
          persistIntents(state);
        });
      }
      if (!failed) state.retryAttempt = 0;
    } catch {
      failed = true; // Unacknowledged intent never leaves the journal, including across reload/sign-out.
    } finally {
      state.writeQueued = false;
      if (state === settingsSyncState && state.session && !state.upgradeRequired && hasPendingIntents(state)) {
        scheduleIntentPush(state, failed
          ? Math.min(30_000, SETTINGS_RETRY_DELAY * 2 ** Math.min(state.retryAttempt++, 5))
          : 350);
      }
    }
  };
  settingsWriteTail = settingsWriteTail.then(write, write);
}

function hasPendingIntents(state: SettingsSyncState): boolean {
  return state.pendingKeys.size > 0 || Object.keys(state.retainedNativeSettings).length > 0 || Object.keys(state.hostIntents).length > 0 || Object.keys(state.profileIntents).length > 0 || Object.keys(state.addonEvents).length > 0 || Object.keys(state.addonIntents).length > 0 || Object.keys(state.progressIntents).length > 0;
}

function scheduleIntentPush(state: SettingsSyncState, delay: number): void {
  if (state !== settingsSyncState || !state.session || state.upgradeRequired || !hasPendingIntents(state) || state.pushTimer) return;
  state.pushTimer = setTimeout(() => queueSettingsPush(state), delay);
}

function scheduleSettingsPush(
  state: SettingsSyncState,
  settings: Settings,
  changedKeys: readonly (keyof Settings)[],
): void {
  const next = copySettings(settings);
  // Unrelated live fields may belong to a newly selected binding; never overwrite older dirty
  // values when this action changed only a metadata key or another independent preference.
  for (const key of state.pendingKeys) if (state.pendingSettings) Object.assign(next, { [key]: state.pendingSettings[key] });
  const target = appliedNativeProjection ? nativeSettingsTarget(appliedNativeProjection.profiles.find((profile) => profile.main)!) : undefined;
  for (const key of changedKeys) {
    const previousTarget = state.nativeSettingBindings[key];
    if (previousTarget && target !== previousTarget && state.pendingSettings) {
      state.retainedNativeSettings[previousTarget] = { ...state.retainedNativeSettings[previousTarget], [key]: state.pendingSettings[key] };
    }
    Object.assign(next, { [key]: settings[key] });
    state.pendingKeys.add(key);
    if (target && !API_KEY_SETTING_KEYS.includes(key)) {
      state.nativeSettingKeys.add(key);
      state.nativeSettingBindings[key] = target;
      if (hostSettingField(key)) queueHostSetting(state, key, settings[key]);
    }
  }
  state.pendingSettings = next;
  if (target) queuePlaybackSettings(state, next, changedKeys);
  persistIntents(state);
  if (state.pushTimer) clearTimeout(state.pushTimer);
  state.pushTimer = undefined;
  if (state.upgradeRequired) return;
  state.pushTimer = setTimeout(() => queueSettingsPush(state), SETTINGS_PUSH_DELAY);
}

onSettingsChange((next) => {
  const state = settingsSyncState;
  if (hasNativeProfiles() && !state.session) return;
  discardTransferredIntents(state);
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
  const syncableKeys = syncableSettingsKeys(changedKeys).filter((key) => !appliedNativeProjection || !PROFILE_SCOPED_SETTING_KEYS.includes(key));
  if (!syncableKeys.length) return;
  const session = currentSession();
  if (!session || state !== settingsSyncState || !sameSession(state.session, session)) return;
  scheduleSettingsPush(state, ownerNext, syncableKeys);
});

/** Sign out: clear storage, reset the cache, and notify subscribers so the nav drops back to signed-out. */
export function signOut(): Promise<AuthResult> {
  // clearSession retires authority synchronously, before waiting for the cooperative lock.
  const completion = clearSession();
  reconcileAuthority();
  return completion;
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
  for (const listener of listeners) { try { listener(value); } catch { /* isolated UI effect */ } }
}

// Pure subscription registration; no credential read/write at module import.
onSessionAuthority(reconcileAuthority);
