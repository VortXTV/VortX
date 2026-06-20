import type { Addon, MetaItem } from "./types";
import { CINEMETA_URL, loadAddon } from "./addon";

// The installed-add-on store. The web client has no account engine (that is the native app's job), so
// it keeps the list of installed add-on transport URLs in localStorage and resolves their manifests
// on boot. Cinemeta is always present so Home and Detail work out of the box; the user adds stream
// add-ons (debrid/direct) to get playable sources.

const STORAGE_KEY = "vortx.web.addons.v1";

/** The persisted transport URLs (manifest.json links), Cinemeta first, then user-added. */
export function installedUrls(): string[] {
  let saved: string[] = [];
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) saved = JSON.parse(raw) as string[];
  } catch {
    saved = [];
  }
  const urls = Array.isArray(saved) ? saved.filter((u) => typeof u === "string") : [];
  return urls.includes(CINEMETA_URL) ? urls : [CINEMETA_URL, ...urls];
}

/** Persist the transport URL list (keeping Cinemeta pinned first). */
function persist(urls: string[]): void {
  const deduped = Array.from(new Set(urls));
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(deduped));
  } catch {
    // Private-mode / quota: the in-memory list still works for this session.
  }
}

/** Resolve every installed add-on's manifest, in parallel. Cinemeta failing is non-fatal (Home will
 *  show its own error); a user add-on failing is dropped from this session's list. */
export async function loadInstalledAddons(): Promise<Addon[]> {
  const urls = installedUrls();
  const results = await Promise.allSettled(urls.map((u) => loadAddon(u)));
  const addons: Addon[] = [];
  for (const r of results) {
    if (r.status === "fulfilled") addons.push(r.value);
  }
  return addons;
}

/** Add a stream/catalog add-on by transport URL. Validates the manifest before persisting; returns
 *  the resolved Addon so the caller can refresh the UI. Throws if the URL is not a valid add-on. */
export async function addAddon(transportUrl: string): Promise<Addon> {
  const normalized = transportUrl.trim();
  const addon = await loadAddon(normalized);
  persist([...installedUrls(), normalized]);
  return addon;
}

/** Remove an add-on by transport URL (Cinemeta cannot be removed - it backs Home + meta). */
export function removeAddon(transportUrl: string): void {
  if (transportUrl === CINEMETA_URL) return;
  persist(installedUrls().filter((u) => u !== transportUrl));
}

// --- Library (saved titles) ---------------------------------------------------------------------
// A local watchlist, separate from the apps' account library (the web client has no account sync).
// Slim MetaItems (id/type/name/poster) are enough to render a poster card and link to Detail.
const LIBRARY_KEY = "vortx.web.library.v1";

/** Saved titles, most-recently-added first. */
export function libraryItems(): MetaItem[] {
  try {
    const raw = localStorage.getItem(LIBRARY_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? (parsed as MetaItem[]) : [];
  } catch {
    return [];
  }
}

/** Whether a title id is currently saved. */
export function inLibrary(id: string): boolean {
  return libraryItems().some((e) => e.id === id);
}

/** Add or remove a title; returns true if it is now saved. */
export function toggleLibrary(item: MetaItem): boolean {
  const current = libraryItems();
  const exists = current.some((e) => e.id === item.id);
  const slim: MetaItem = { id: item.id, type: item.type, name: item.name, poster: item.poster };
  const next = exists ? current.filter((e) => e.id !== item.id) : [slim, ...current];
  try {
    localStorage.setItem(LIBRARY_KEY, JSON.stringify(next));
  } catch {
    /* storage disabled or full: library is best-effort */
  }
  return !exists;
}

// --- Continue Watching --------------------------------------------------------------------------
// In-progress titles, recorded by the player as you watch (position + duration). Local to this browser
// (the web client has no account sync). A title past 95% is treated as finished and dropped.
const CW_KEY = "vortx.web.cw.v1";

export interface CWEntry extends MetaItem {
  position: number;
  duration: number;
  updatedAt: number;
}

/** In-progress titles, most-recently-watched first. */
export function continueWatching(): CWEntry[] {
  try {
    const raw = localStorage.getItem(CW_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    if (!Array.isArray(parsed)) return [];
    return (parsed as CWEntry[]).sort((a, b) => b.updatedAt - a.updatedAt);
  } catch {
    return [];
  }
}

/** The saved resume position (seconds) for a title id, or 0 if none. */
export function cwPosition(id: string): number {
  return continueWatching().find((e) => e.id === id)?.position ?? 0;
}

/** Record playback progress; drops the title (finished) once past 95%. */
export function recordProgress(
  item: { id: string; type: string; name: string; poster?: string },
  position: number,
  duration: number,
): void {
  if (!isFinite(position) || !isFinite(duration) || duration <= 0) return;
  const others = continueWatching().filter((e) => e.id !== item.id);
  if (position / duration > 0.95) {
    persistCW(others);
    return;
  }
  const entry: CWEntry = {
    id: item.id,
    type: item.type,
    name: item.name,
    poster: item.poster,
    position,
    duration,
    updatedAt: Date.now(),
  };
  persistCW([entry, ...others].slice(0, 40));
}

/** Remove a title from Continue Watching. */
export function clearProgress(id: string): void {
  persistCW(continueWatching().filter((e) => e.id !== id));
}

function persistCW(entries: CWEntry[]): void {
  try {
    localStorage.setItem(CW_KEY, JSON.stringify(entries));
  } catch {
    /* storage disabled or full: best-effort */
  }
}

// --- Recent searches ----------------------------------------------------------------------------
// The last few search queries, newest first, so the Search page can offer one-tap repeats. Local only.
const RECENT_KEY = "vortx.web.recent.v1";
const RECENT_MAX = 8;

/** Recent search queries, newest first. */
export function recentSearches(): string[] {
  try {
    const raw = localStorage.getItem(RECENT_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? (parsed as string[]).filter((s) => typeof s === "string") : [];
  } catch {
    return [];
  }
}

/** Record a search query (trimmed, de-duped case-insensitively, capped). */
export function addRecentSearch(query: string): void {
  const q = query.trim();
  if (!q) return;
  const next = [q, ...recentSearches().filter((s) => s.toLowerCase() !== q.toLowerCase())].slice(0, RECENT_MAX);
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify(next));
  } catch {
    /* storage disabled or full: best-effort */
  }
}

/** Remove a title from the Library by id (the rail × control). */
export function removeFromLibrary(id: string): void {
  try {
    localStorage.setItem(LIBRARY_KEY, JSON.stringify(libraryItems().filter((e) => e.id !== id)));
  } catch {
    /* storage disabled or full: best-effort */
  }
}
