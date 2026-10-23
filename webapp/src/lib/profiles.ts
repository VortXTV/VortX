// Local per-device profiles - the web twin of the Apple app's Profiles. Each profile keeps its own look
// (accent, background, text size) and languages; switching a profile applies them live. This MVP layer
// sits ON TOP of lib/settings.ts (the live applied layer): switching loads a profile's snapshot into the
// active Settings, and editing a look/language setting while a profile is active saves back to it. Stored
// locally (localStorage); the account-synced roster (doc.vortx.profiles) + per-profile library + PIN are
// the next phases. No engine, no account dependency - works signed out.

import { getSettings, updateSettings, onSettingsChange, type Settings, type Background, type SubtitlesMode } from "./settings";

/** The subset of Settings a profile owns (its "look" + preferred languages). */
type ProfileLook = Pick<Settings, "accentID" | "background" | "textScale" | "audioLang" | "subtitleLang" | "subtitlesMode">;

export interface Profile {
  id: string;
  name: string;
  avatar: string; // a single emoji glyph
  look: ProfileLook;
  /** Native PIN/parental enforcement is unavailable here; never open that profile's resources. */
  restricted?: boolean;
  /** Credential-free native account-binding revision; local look intent never crosses a rebind. */
  nativeBinding?: string;
}

export const PROFILE_AVATARS = [
  "🦊", "🐼", "🐨", "🐯", "🦁", "🐸", "🐙", "🦄", "🐲", "🌸", "⚡", "🎬", "🎮", "🍿", "🚀", "👾",
] as const;

const KEY = "vortx.web.profiles.v1";
const ACTIVE_KEY = "vortx.web.activeProfile.v1";
const NATIVE_LOOK_DEFAULTS: ProfileLook = { accentID: "ember", background: "warm", textScale: 1, audioLang: "", subtitleLang: "", subtitlesMode: "always" };

const listeners = new Set<() => void>();
let nativeLookPusher: ((profileId: string, binding: string, patch: Partial<ProfileLook>) => void) | undefined;
export function registerNativeLookSyncPusher(pusher: typeof nativeLookPusher): void { nativeLookPusher = pusher; }
export function pendingNativeLookIntent(profileId: string, binding: string): Partial<ProfileLook> { return nativeLookIntent(profileId, binding); }
export function retireNativeLookIntent(scope: string, profileId: string, binding: string, accepted: Partial<ProfileLook>): void {
  if (nativeScope !== scope) return;
  const pending = nativeLookIntent(profileId, binding);
  for (const key of Object.keys(accepted) as (keyof ProfileLook)[]) if (pending[key] === accepted[key]) delete pending[key];
  try {
    const key = nativeLookKey(profileId, binding);
    if (Object.keys(pending).length) localStorage.setItem(key, JSON.stringify(pending)); else localStorage.removeItem(key);
  } catch { /* A live newer edit must never be retired by this receipt. */ }
}
let cache: Profile[] | null = null;
let nativeRoster: Profile[] | null = null;
let nativeScope = "";
const activeKey = (): string => nativeRoster ? `${ACTIVE_KEY}.${nativeScope}` : ACTIVE_KEY;
export function hasNativeProfiles(): boolean { return nativeScope !== ""; }
export function blockNativeProfiles(scope: string): void {
  nativeScope = scope;
  if (nativeRoster) nativeRoster = nativeRoster.map((profile) => ({ ...profile, restricted: true }));
}

/** Accepted native roster is authoritative, including deletions; legacy local profiles stay intact. */
export function setNativeProfiles(scope: string, roster: (SyncedProfile & { look: Partial<ProfileLook>; restricted: boolean; binding: string })[] | null): boolean {
  const previous = JSON.stringify(nativeRoster);
  nativeScope = scope;
  nativeRoster = roster ? roster.map((profile) => ({ id: profile.id, name: profile.name,
    avatar: profile.avatar || "🍿", look: { ...NATIVE_LOOK_DEFAULTS, ...Object.fromEntries(Object.keys(NATIVE_LOOK_DEFAULTS)
      .filter((key) => key in profile.look).map((key) => [key, profile.look[key as keyof ProfileLook]])),
      ...nativeLookIntent(profile.id, profile.binding) }, restricted: profile.restricted, nativeBinding: profile.binding })) : null;
  if (nativeRoster && (!nativeRoster.some((profile) => profile.id === activeProfileId() && !profile.restricted))) {
    try { localStorage.setItem(activeKey(), nativeRoster.find((profile) => !profile.restricted)?.id ?? nativeRoster[0].id); } catch { /* optional */ }
  }
  return previous !== JSON.stringify(nativeRoster);
}

/** Snapshot the look fields out of the live Settings (used to seed a new profile / the default). */
function lookFromSettings(s: Settings = getSettings()): ProfileLook {
  return {
    accentID: s.accentID,
    background: s.background,
    textScale: s.textScale,
    audioLang: s.audioLang,
    subtitleLang: s.subtitleLang,
    subtitlesMode: s.subtitlesMode,
  };
}

function randomId(): string {
  // crypto is a guaranteed browser global; randomUUID where available, else random bytes (never Math.random).
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(b, (x: number) => x.toString(16).padStart(2, "0")).join("");
}

function persist(profiles: Profile[]): void {
  if (nativeRoster) {
    for (const profile of profiles) {
      const previous = nativeRoster.find((row) => row.id === profile.id);
      if (!previous || !profile.nativeBinding || previous.restricted) continue;
      const patch = nativeLookIntent(profile.id, profile.nativeBinding);
      const changed: Partial<ProfileLook> = {};
      for (const key of Object.keys(profile.look) as (keyof ProfileLook)[]) {
        if (previous.look[key] !== profile.look[key]) {
          Object.assign(patch, { [key]: profile.look[key] }); Object.assign(changed, { [key]: profile.look[key] });
        }
      }
      try { if (Object.keys(patch).length) localStorage.setItem(nativeLookKey(profile.id, profile.nativeBinding), JSON.stringify(patch)); }
      catch { /* Network journal and current live look remain available when storage is blocked. */ }
      if (Object.keys(changed).length) nativeLookPusher?.(profile.id, profile.nativeBinding, changed);
    }
    nativeRoster = profiles;
    listeners.forEach((fn) => fn());
    return; // Native display edits must never overwrite the signed-out/local roster.
  }
  cache = profiles;
  try {
    localStorage.setItem(KEY, JSON.stringify(profiles));
  } catch {
    /* private mode / quota: keep the in-memory roster for this session */
  }
  listeners.forEach((fn) => fn());
}

function nativeLookKey(profileId: string, binding: string): string {
  return `${KEY}.look-intent.${encodeURIComponent(nativeScope)}.${profileId}.${encodeURIComponent(binding)}`;
}
function nativeLookIntent(profileId: string, binding: string): Partial<ProfileLook> {
  try {
    const raw = JSON.parse(localStorage.getItem(nativeLookKey(profileId, binding)) ?? "{}");
    const defaults = NATIVE_LOOK_DEFAULTS;
    return Object.fromEntries(Object.keys(defaults).filter((key) => typeof raw[key] === typeof defaults[key as keyof ProfileLook])
      .map((key) => [key, raw[key]]));
  } catch { return {}; }
}

/** The profile roster. Seeds a single default profile (snapshotting the current settings) on first read,
 *  so there is always at least one profile and the owner's existing look is preserved. */
export function profiles(): Profile[] {
  if (nativeRoster) return nativeRoster;
  if (cache) return cache;
  let parsed: Profile[] = [];
  try {
    const raw = localStorage.getItem(KEY);
    parsed = raw ? (JSON.parse(raw) as Profile[]) : [];
  } catch {
    parsed = [];
  }
  const valid = Array.isArray(parsed) ? parsed.filter((p) => p && typeof p.id === "string" && typeof p.name === "string") : [];
  if (!valid.length) {
    const def: Profile = { id: randomId(), name: "You", avatar: PROFILE_AVATARS[0], look: lookFromSettings() };
    cache = [def];
    persist(cache);
    return cache;
  }
  cache = valid;
  return cache;
}

/** The owner profile (index 0) - it uses the base storage keys (its library/history is the un-namespaced
 *  set + the account-synced one), so existing data is never orphaned by introducing profiles. */
export function isOwnerProfile(id: string): boolean {
  return profiles()[0]?.id === id;
}

export function activeProfileId(): string {
  const list = profiles();
  let id = "";
  try {
    id = localStorage.getItem(activeKey()) ?? "";
  } catch {
    id = "";
  }
  return list.some((p) => p.id === id) ? id : list[0].id;
}

export function activeProfile(): Profile {
  const id = activeProfileId();
  return profiles().find((p) => p.id === id) ?? profiles()[0];
}

/** Storage scope for per-profile data: "" for the owner (base keys), else the profile id. Consumed by
 *  store.ts to namespace library / continue-watching / recent searches per profile. */
export function activeScope(): string {
  const id = activeProfileId();
  return isOwnerProfile(id) ? "" : id;
}

/** Switch the active profile and apply its look + languages to the live Settings. */
export function setActiveProfile(id: string): void {
  const p = profiles().find((x) => x.id === id);
  if (!p || p.restricted) return;
  try {
    localStorage.setItem(activeKey(), id);
  } catch {
    /* best-effort */
  }
  updateSettings({ ...p.look }); // re-themes live via applySettings
  listeners.forEach((fn) => fn());
  // Library, Continue Watching, and Home read per-profile (scoped) storage, so the active route must
  // re-render against the new profile's space. main.ts listens for this and re-renders.
  if (typeof window !== "undefined") window.dispatchEvent(new Event("vortx:profile-changed"));
}

/** Create a new profile seeded from the current look, switch to it, and return it. */
export function addProfile(name: string, avatar: string): Profile {
  if (hasNativeProfiles()) throw new Error("Manage account profiles in VortX; native profile edit events are not supported here yet.");
  const p: Profile = { id: randomId(), name: name.trim() || "New profile", avatar, look: lookFromSettings() };
  persist([...profiles(), p]);
  setActiveProfile(p.id);
  return p;
}

/** Rename / re-avatar a profile (not its look - that follows the live Settings while active). */
export function updateProfileMeta(id: string, patch: { name?: string; avatar?: string }): void {
  if (hasNativeProfiles()) return;
  persist(
    profiles().map((p) =>
      p.id === id ? { ...p, name: (patch.name ?? p.name).trim() || p.name, avatar: patch.avatar ?? p.avatar } : p,
    ),
  );
}

/** Delete a profile. The owner (index 0) cannot be deleted; deleting the active one falls back to the owner. */
export function deleteProfile(id: string): void {
  if (hasNativeProfiles()) return;
  if (isOwnerProfile(id) || profiles().length <= 1) return;
  const next = profiles().filter((p) => p.id !== id);
  persist(next);
  if (activeProfileId() === id) setActiveProfile(next[0].id);
}

/** A synced profile from the account doc (doc.vortx.profiles, normalized by account.ts): the roster the
 *  Apple app emits and the dashboard reads. Only the fields the web roster needs today. */
export interface SyncedProfile {
  id: string;
  name: string;
  main?: boolean;
  avatar?: string;
}

/** Reconcile the account-synced roster into the local profile store, so a signed-in user finally sees
 *  their real multi-profile roster instead of just the local "You". The synced MAIN profile maps onto the
 *  local owner (index 0, base storage, keeping its local id so existing owner data is never orphaned);
 *  each secondary synced profile becomes an overlay profile keyed by its SYNCED id, so its scoped library
 *  + continue-watching (written by store.mergeLibraryForScope/mergeContinueWatchingForScope under that id)
 *  line up. Names + avatars come from the roster; per-profile look sync is a later phase, so an existing
 *  profile keeps its local look and a new one is seeded from the current settings. Purely-local profiles
 *  not in the roster are preserved (a read-only sync never deletes them). Returns true if anything changed. */
export function mergeSyncedProfiles(roster: SyncedProfile[]): boolean {
  const valid = (Array.isArray(roster) ? roster : []).filter(
    (p) => p && typeof p.id === "string" && typeof p.name === "string",
  );
  if (!valid.length) return false;
  const local = profiles();
  const owner = local[0];
  const main = valid.find((p) => p.main) ?? valid[0];
  const byId = new Map(local.map((p) => [p.id, p] as const));
  const next: Profile[] = [];
  // Owner row: keep the local id + base storage, adopt the synced main's name/avatar.
  next.push({ ...owner, name: main.name.trim() || owner.name, avatar: main.avatar || owner.avatar });
  // Secondary synced profiles, keyed by their synced id (so scoped storage matches).
  for (const sp of valid) {
    if (sp.id === main.id) continue;
    const existing = byId.get(sp.id);
    next.push({
      id: sp.id,
      name: sp.name.trim() || existing?.name || "Profile",
      avatar: sp.avatar || existing?.avatar || PROFILE_AVATARS[next.length % PROFILE_AVATARS.length],
      look: existing?.look ?? lookFromSettings(),
    });
  }
  // Keep purely-local overlay profiles the synced roster does not include.
  for (const p of local.slice(1)) {
    if (!next.some((n) => n.id === p.id)) next.push(p);
  }
  if (JSON.stringify(next) === JSON.stringify(local)) return false;
  persist(next);
  return true;
}

export function onProfilesChange(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

// Save look/language edits back to the ACTIVE profile, so each profile remembers its own appearance. This
// is idempotent during a switch (we apply the new profile's look, which then saves back to the same
// profile). Registered once at module load.
onSettingsChange((s) => {
  const id = activeProfileId();
  const look = lookFromSettings(s);
  const list = profiles();
  const cur = list.find((p) => p.id === id);
  if (!cur) return;
  // Only write if the look actually changed, to avoid churn.
  if (JSON.stringify(cur.look) === JSON.stringify(look)) return;
  persist(list.map((p) => (p.id === id ? { ...p, look } : p)));
});

export type { Background, SubtitlesMode, ProfileLook };
