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
}

export const PROFILE_AVATARS = [
  "🦊", "🐼", "🐨", "🐯", "🦁", "🐸", "🐙", "🦄", "🐲", "🌸", "⚡", "🎬", "🎮", "🍿", "🚀", "👾",
] as const;

const KEY = "vortx.web.profiles.v1";
const ACTIVE_KEY = "vortx.web.activeProfile.v1";

const listeners = new Set<() => void>();
let cache: Profile[] | null = null;

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
  cache = profiles;
  try {
    localStorage.setItem(KEY, JSON.stringify(profiles));
  } catch {
    /* private mode / quota: keep the in-memory roster for this session */
  }
  listeners.forEach((fn) => fn());
}

/** The profile roster. Seeds a single default profile (snapshotting the current settings) on first read,
 *  so there is always at least one profile and the owner's existing look is preserved. */
export function profiles(): Profile[] {
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
    id = localStorage.getItem(ACTIVE_KEY) ?? "";
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
  if (!p) return;
  try {
    localStorage.setItem(ACTIVE_KEY, id);
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
  const p: Profile = { id: randomId(), name: name.trim() || "New profile", avatar, look: lookFromSettings() };
  persist([...profiles(), p]);
  setActiveProfile(p.id);
  return p;
}

/** Rename / re-avatar a profile (not its look - that follows the live Settings while active). */
export function updateProfileMeta(id: string, patch: { name?: string; avatar?: string }): void {
  persist(
    profiles().map((p) =>
      p.id === id ? { ...p, name: (patch.name ?? p.name).trim() || p.name, avatar: patch.avatar ?? p.avatar } : p,
    ),
  );
}

/** Delete a profile. The owner (index 0) cannot be deleted; deleting the active one falls back to the owner. */
export function deleteProfile(id: string): void {
  if (isOwnerProfile(id) || profiles().length <= 1) return;
  const next = profiles().filter((p) => p.id !== id);
  persist(next);
  if (activeProfileId() === id) setActiveProfile(next[0].id);
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

export type { Background, SubtitlesMode };
