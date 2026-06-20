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
