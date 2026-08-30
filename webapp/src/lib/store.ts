import type { Addon, MetaItem } from "./types";
import { CINEMETA_URL, loadAddon } from "./addon";
import { activeScope } from "./profiles";
import {
  canonicalPlaybackIdentity,
  continueWatchingIdentityKeys,
  foldContinueWatching,
  identityKeysIntersect,
  type ContinueWatchingIdentity,
} from "./continue-watching-dedupe";

/** Per-profile storage key. The owner profile (scope "") uses the base key, so existing data, account
 *  hydration, and backup all stay on the canonical keys; overlay profiles get a suffixed key so each
 *  keeps its own local library and Continue Watching (the web twin of the apps' per-profile history). */
function scopedKey(base: string): string {
  const scope = activeScope();
  return scope ? `${base}.${scope}` : base;
}

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

// When signed in, add/remove pushes the new installed list UP to the account (the doc.addons web sibling)
// so add-ons added on the web reach the user's other devices. The pusher is INJECTED by account.ts (which
// owns the session + the encrypted write) to avoid a store -> account import cycle; null when signed out.
// The pusher carries an explicit add/remove signal so the account write can maintain the removal
// tombstone (doc.removedAddons) precisely - never inferred by diffing the merged set (which would
// false-tombstone app-installed add-ons the webapp simply doesn't hold locally).
export interface AddonSyncHint { added?: string; removed?: string }
let addonsSyncPusher: ((hint?: AddonSyncHint) => void) | null = null;
export function registerAddonsSyncPusher(fn: ((hint?: AddonSyncHint) => void) | null): void {
  addonsSyncPusher = fn;
}

/** Add a stream/catalog add-on by transport URL. Validates the manifest before persisting; returns
 *  the resolved Addon so the caller can refresh the UI. Throws if the URL is not a valid add-on. */
export async function addAddon(transportUrl: string): Promise<Addon> {
  const addon = await loadAddon(transportUrl.trim()); // validates scheme (https-only) + normalizes
  persist([...installedUrls(), addon.transportUrl]); // store exactly the normalized URL that loaded
  addonsSyncPusher?.({ added: addon.transportUrl }); // push + clear any prior removal tombstone for it
  return addon;
}

/** Remove an add-on by transport URL (Cinemeta cannot be removed - it backs Home + meta). */
export function removeAddon(transportUrl: string): void {
  if (transportUrl === CINEMETA_URL) return;
  persist(installedUrls().filter((u) => u !== transportUrl));
  addonsSyncPusher?.({ removed: transportUrl }); // push + write the removal tombstone so apps uninstall it
}

// --- Library (saved titles) ---------------------------------------------------------------------
// A local watchlist, separate from the apps' account library (the web client has no account sync).
// Slim MetaItems (id/type/name/poster) are enough to render a poster card and link to Detail.
const LIBRARY_KEY = "vortx.web.library.v1";

/** Saved titles, most-recently-added first. */
export function libraryItems(): MetaItem[] {
  try {
    const raw = localStorage.getItem(scopedKey(LIBRARY_KEY));
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
    localStorage.setItem(scopedKey(LIBRARY_KEY), JSON.stringify(next));
  } catch {
    /* storage disabled or full: library is best-effort */
  }
  return !exists;
}

/** Merge synced add-on transport URLs into the installed list (union, https-only, Cinemeta stays first).
 *  Used by account hydration so a signed-in user's add-ons from their other VortX devices appear here.
 *  Never removes - read-only sync, so it can't clobber the account's own add-on set. */
export function mergeInstalledAddons(urls: string[]): boolean {
  const existing = new Set(installedUrls());
  const added = urls
    .filter((u): u is string => typeof u === "string" && /^https:\/\//i.test(u.trim()))
    .map((u) => u.trim())
    .filter((u) => !existing.has(u));
  if (!added.length) return false;
  persist([...installedUrls(), ...added]); // persist() de-dupes + pins Cinemeta first
  return true;
}

/** Prune tombstoned add-ons from the local installed list (read-down of doc.removedAddons). This is what
 *  makes a removal STICK across a sync: mergeInstalledAddons only ever unions, so an add-on the user
 *  deleted that still lives in another channel (the app's vortx.addons, a Stremio re-import) would be
 *  re-added and reappear as installed. Cinemeta is never pruned (it backs Home + meta). Returns true only
 *  when something was actually removed, so it can gate a re-render. */
export function pruneInstalledAddons(removedUrls: string[]): boolean {
  const remove = new Set(removedUrls.filter((u) => typeof u === "string" && u !== CINEMETA_URL));
  if (!remove.size) return false;
  const current = installedUrls();
  const next = current.filter((u) => !remove.has(u));
  if (next.length === current.length) return false; // nothing tombstoned was actually installed
  persist(next);
  return true;
}

/** Apply a synced add-on ORDER to the local list (read-down): take the synced order as canonical for the
 *  URLs we have installed, then append any local-only URLs in their current order (never drops a local
 *  add-on). Cinemeta stays pinned first so Home + meta always work. Persists + returns true only when the
 *  order actually changes, so it never triggers a redundant re-render. https-only, like mergeInstalledAddons. */
export function applyAddonOrder(orderedUrls: string[]): boolean {
  const cleanOrder = orderedUrls
    .filter((u): u is string => typeof u === "string" && /^https:\/\//i.test(u.trim()))
    .map((u) => u.trim());
  if (!cleanOrder.length) return false;
  const current = installedUrls();
  const currentSet = new Set(current);
  const ordered: string[] = [];
  const seen = new Set<string>([CINEMETA_URL]); // Cinemeta is pinned first below, never in the middle
  for (const u of cleanOrder) {
    if (currentSet.has(u) && !seen.has(u)) { ordered.push(u); seen.add(u); }
  }
  for (const u of current) {
    if (!seen.has(u)) { ordered.push(u); seen.add(u); }
  }
  const next = [CINEMETA_URL, ...ordered];
  if (next.length === current.length && next.every((u, i) => u === current[i])) return false;
  persist(next);
  return true;
}

/** Merge synced library items into the local library (union by id; existing entries win). Slimmed to the
 *  same id/type/name/poster shape the local library stores. */
export function mergeLibrary(items: MetaItem[]): void {
  const valid = items.filter(
    (m) => m && typeof m.id === "string" && typeof m.type === "string" && typeof m.name === "string",
  );
  if (!valid.length) return;
  // Account hydration ALWAYS targets the owner library (base key), never an active overlay profile -
  // overlay profiles stay local and must never receive or mutate the account library.
  let existing: MetaItem[] = [];
  try {
    const raw = localStorage.getItem(LIBRARY_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    if (Array.isArray(parsed)) existing = parsed as MetaItem[];
  } catch {
    existing = [];
  }
  const seen = new Set(existing.map((e) => e.id));
  const additions = valid
    .filter((m) => !seen.has(m.id))
    .map((m) => ({ id: m.id, type: m.type, name: m.name, poster: m.poster }));
  if (!additions.length) return;
  try {
    localStorage.setItem(LIBRARY_KEY, JSON.stringify([...existing, ...additions]));
  } catch {
    /* best-effort */
  }
}

// --- Hidden home rails --------------------------------------------------------------------------
// Catalog rails the user has hidden from Home (competitor-parity home customization; Stremio paywalls
// catalog hide/reorder). Keys are the catalog identity (type:id:addon). Local to this browser.
const HIDDEN_RAILS_KEY = "vortx.web.hiddenRails.v1";

function hiddenRailSet(): Set<string> {
  try {
    const raw = localStorage.getItem(HIDDEN_RAILS_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    return new Set(Array.isArray(parsed) ? (parsed as string[]) : []);
  } catch {
    return new Set();
  }
}

/** How many home rails are currently hidden (drives the "Show hidden" affordance in Settings). */
export function hiddenRailCount(): number {
  return hiddenRailSet().size;
}

export function isRailHidden(key: string): boolean {
  return hiddenRailSet().has(key);
}

/** Hide a rail by key (persisted; the Board skips it on its next render). */
export function hideRail(key: string): void {
  const set = hiddenRailSet();
  set.add(key);
  try {
    localStorage.setItem(HIDDEN_RAILS_KEY, JSON.stringify([...set]));
  } catch {
    /* storage disabled/full: best-effort */
  }
}

/** Restore every hidden rail. */
export function clearHiddenRails(): void {
  try {
    localStorage.removeItem(HIDDEN_RAILS_KEY);
  } catch {
    /* best-effort */
  }
}

// --- Continue Watching --------------------------------------------------------------------------
// In-progress titles, recorded by the player as you watch (position + duration). Storage is profile-scoped
// in this browser and the account layer mirrors its live entries. A title past 95% is treated as finished.
const CW_KEY = "vortx.web.cw.v1";
const CW_TOMBSTONE_KEY = "vortx.web.cw.removed.v1";

export interface CWEntry extends MetaItem {
  /** The actual PLAYED id the position belongs to: the episode id for a series, the title id for a movie.
   *  `id` (from MetaItem) stays the title/series id so the rail card links to the title's Detail and a
   *  series collapses to one card. Keying the position by resumeId stops one episode resuming at another's time. */
  resumeId: string;
  position: number;
  duration: number;
  updatedAt: number;
}

export interface CWTombstone {
  keys: string[];
  removedAt: number;
}

function cwIdentity(entry: CWEntry): ContinueWatchingIdentity {
  return {
    id: entry.id,
    type: entry.type,
    aliases: [entry.resumeId],
    freshness: entry.updatedAt,
    hasValidProgress:
      Number.isFinite(entry.position) && Number.isFinite(entry.duration) && entry.position > 0 && entry.duration > 0,
  };
}

function readCWTombstones(key: string): CWTombstone[] {
  try {
    const raw = localStorage.getItem(key);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    if (!Array.isArray(parsed)) return [];
    return (parsed as CWTombstone[]).filter(
      (entry) =>
        entry &&
        Array.isArray(entry.keys) &&
        entry.keys.every((value) => typeof value === "string") &&
        Number.isFinite(entry.removedAt),
    );
  } catch {
    return [];
  }
}

function isTombstoned(entry: CWEntry, tombstones: CWTombstone[]): boolean {
  const keys = continueWatchingIdentityKeys(cwIdentity(entry));
  const updatedAt = Number.isFinite(entry.updatedAt) ? entry.updatedAt : 0;
  return tombstones.some(
    (tombstone) => tombstone.removedAt >= updatedAt && identityKeysIntersect(keys, new Set(tombstone.keys)),
  );
}

function readCWKey(key: string, tombstoneKey: string): CWEntry[] {
  try {
    const raw = localStorage.getItem(key);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    if (!Array.isArray(parsed)) return [];
    const tombstones = readCWTombstones(tombstoneKey);
    return (parsed as CWEntry[])
      .filter(
        (entry) =>
          entry &&
          typeof entry.id === "string" &&
          typeof entry.type === "string" &&
          typeof entry.resumeId === "string",
      )
      .filter((entry) => !isTombstoned(entry, tombstones))
      .sort((a, b) => {
        const lhs = Number.isFinite(a.updatedAt) ? a.updatedAt : 0;
        const rhs = Number.isFinite(b.updatedAt) ? b.updatedAt : 0;
        return rhs - lhs;
      });
  } catch {
    return [];
  }
}

/** Every stored progress entry (one per played id), most-recently-watched first. */
function rawCW(): CWEntry[] {
  return readCWKey(scopedKey(CW_KEY), scopedKey(CW_TOMBSTONE_KEY));
}

/** In-progress titles for the rail, most-recent first, collapsed to ONE card per title (a series with
 *  several watched episodes shows once and links to its Detail). */
export function continueWatching(): CWEntry[] {
  return foldContinueWatching(rawCW(), cwIdentity);
}

/** The saved resume position (seconds) for a PLAYED id (episode id for a series), or 0 if none. */
export function cwPosition(resumeId: string): number {
  return (
    rawCW().find((entry) => canonicalPlaybackIdentity(entry.resumeId, entry.type) === canonicalPlaybackIdentity(resumeId, entry.type))
      ?.position ?? 0
  );
}

/** The saved watched FRACTION (0..1) for a played id, or 0 if none / unknown duration. */
export function cwProgress(resumeId: string): number {
  const e = rawCW().find(
    (entry) => canonicalPlaybackIdentity(entry.resumeId, entry.type) === canonicalPlaybackIdentity(resumeId, entry.type),
  );
  return e && e.duration > 0 ? Math.min(1, e.position / e.duration) : 0;
}

/** The PLAYED id to resume for a title (e.g. the last-watched episode id of a series), or null if the
 *  title has no in-progress entry. Drives the series "Resume S#E#" hero action. */
export function cwResumeId(titleId: string): string | null {
  return (
    continueWatching().find((entry) =>
      identityKeysIntersect(
        continueWatchingIdentityKeys(cwIdentity(entry)),
        continueWatchingIdentityKeys({ id: titleId, type: entry.type }),
      ),
    )?.resumeId ?? null
  );
}

// Write-up trigger: fires after any local CW change so the account can push the active profile's web
// watch-progress up to the bilateral doc.webProgress field (debounced in account.ts), making what you
// watch on the web reach your apps and other browsers. No-op signed out.
let cwSyncPusher: (() => void) | null = null;
export function registerCwSyncPusher(fn: (() => void) | null): void {
  cwSyncPusher = fn;
}

/** One bilateral web-progress entry, the shape both the app and other web clients read out of
 *  doc.webProgress: id = display id, v = played id (episode), t/d = seconds, lastWatched = epoch ms. */
export interface WebProgressEntry {
  id: string;
  type: string;
  v: string;
  t: number;
  d: number;
  lastWatched: number;
  name?: string;
  poster?: string;
}

/** The ACTIVE profile's local Continue Watching mapped into the bilateral webProgress entry shape. The
 *  account pusher reads this for the current scope and writes it under doc.webProgress.owner (owner) or
 *  .byProfile[profileId] (overlay). cwEntriesFrom on the read side consumes the same shape verbatim. */
export function webProgressEntries(): WebProgressEntry[] {
  return rawCW().map((e) => ({
    id: e.id,
    type: e.type,
    v: e.resumeId,
    t: e.position,
    d: e.duration,
    lastWatched: e.updatedAt,
    name: e.name,
    poster: e.poster,
  }));
}

/** The ACTIVE profile's timestamped removal/finished records for bilateral account sync. */
export function webProgressTombstones(): CWTombstone[] {
  return readCWTombstones(scopedKey(CW_TOMBSTONE_KEY));
}

export function mergeCWTombstones(left: CWTombstone[], right: CWTombstone[]): CWTombstone[] {
  const merged: CWTombstone[] = [];
  for (const candidate of [...left, ...right]) {
    if (!candidate || !Array.isArray(candidate.keys) || !Number.isFinite(candidate.removedAt)) continue;
    const keys = new Set(candidate.keys.filter((key) => typeof key === "string"));
    if (!keys.size) continue;
    let removedAt = candidate.removedAt;
    for (let i = merged.length - 1; i >= 0; i -= 1) {
      const existing = merged[i];
      if (!identityKeysIntersect(keys, new Set(existing.keys))) continue;
      existing.keys.forEach((key) => keys.add(key));
      removedAt = Math.max(removedAt, existing.removedAt);
      merged.splice(i, 1);
    }
    merged.push({ keys: [...keys].sort(), removedAt });
  }
  return merged.sort((a, b) => b.removedAt - a.removedAt).slice(0, 100);
}

function writeCWTombstone(key: string, keys: Set<string>, removedAt: number): void {
  const next = mergeCWTombstones(readCWTombstones(key), [{ keys: [...keys], removedAt }]);
  try {
    localStorage.setItem(key, JSON.stringify(next));
  } catch {
    /* storage disabled or full: the local live-set removal still applies */
  }
}

/** Record playback progress for `item` (its `resumeId` is the played id, defaulting to the display id);
 *  drops that played id once past 95% (finished). */
export function recordProgress(
  item: { id: string; type: string; name: string; poster?: string; resumeId?: string },
  position: number,
  duration: number,
): void {
  if (!isFinite(position) || !isFinite(duration) || duration <= 0) return;
  const resumeId = item.resumeId ?? item.id;
  const resumeKey = canonicalPlaybackIdentity(resumeId, item.type);
  const current = rawCW();
  const previous = current.find((entry) => canonicalPlaybackIdentity(entry.resumeId, entry.type) === resumeKey);
  const others = current.filter((entry) => canonicalPlaybackIdentity(entry.resumeId, entry.type) !== resumeKey);
  if (position / duration >= 0.95) {
    persistCW(others);
    const seed = previous ?? {
      id: item.id,
      type: item.type,
      name: item.name,
      poster: item.poster,
      resumeId,
      position,
      duration,
      updatedAt: Date.now(),
    };
    const removalKeys = continueWatchingIdentityKeys(cwIdentity(seed));
    let expanded = true;
    while (expanded) {
      expanded = false;
      for (const entry of current) {
        const keys = continueWatchingIdentityKeys(cwIdentity(entry));
        if (!identityKeysIntersect(removalKeys, keys)) continue;
        for (const key of keys) {
          if (!removalKeys.has(key)) { removalKeys.add(key); expanded = true; }
        }
      }
    }
    writeCWTombstone(scopedKey(CW_TOMBSTONE_KEY), removalKeys, Date.now());
    cwSyncPusher?.(); // finishing a title is a CW change too - push the dropped state up
    return;
  }
  const entry: CWEntry = {
    id: item.id,
    type: item.type,
    name: item.name,
    poster: item.poster,
    resumeId,
    position,
    duration,
    updatedAt: Date.now(),
  };
  persistCW([entry, ...others].slice(0, 40));
  cwSyncPusher?.(); // debounced account write-up of the active profile's web progress
}

/** Remove a title from Continue Watching (every played-id entry that shares this display id). */
export function clearProgress(id: string): void {
  const entries = rawCW();
  const visible = continueWatching().find((entry) => entry.id === id) ??
    continueWatching().find((entry) => entry.id.trim().toLowerCase() === id.trim().toLowerCase());
  if (!visible) return;
  const removalKeys = continueWatchingIdentityKeys(cwIdentity(visible));
  // Complete the alias component before deleting, including a late bridge row.
  let changed = true;
  while (changed) {
    changed = false;
    for (const entry of entries) {
      const keys = continueWatchingIdentityKeys(cwIdentity(entry));
      if (!identityKeysIntersect(removalKeys, keys)) continue;
      for (const key of keys) {
        if (!removalKeys.has(key)) {
          removalKeys.add(key);
          changed = true;
        }
      }
    }
  }
  persistCW(entries.filter((entry) => !identityKeysIntersect(removalKeys, continueWatchingIdentityKeys(cwIdentity(entry)))));
  const tombstoneKey = scopedKey(CW_TOMBSTONE_KEY);
  const removedAt = Date.now();
  writeCWTombstone(tombstoneKey, removalKeys, removedAt);
  cwSyncPusher?.(); // publish the active live set; this scope's tombstone still blocks stale hydration
}

function persistCW(entries: CWEntry[]): void {
  try {
    localStorage.setItem(scopedKey(CW_KEY), JSON.stringify(entries));
  } catch {
    /* storage disabled or full: best-effort */
  }
}

/** Merge externally-sourced Continue Watching entries (derived from the synced account library's watch
 *  progress) into the OWNER (base) store - account watch history belongs to the owner, never an active
 *  overlay profile, mirroring how mergeLibrary always targets the base key. Union by canonical resumeId; a fresher
 *  local entry (newer updatedAt) is never clobbered. Only in-progress entries (0 < position/duration <
 *  0.95) are kept. Returns whether anything changed (so the caller can trigger a re-render). */
export function mergeContinueWatching(entries: CWEntry[]): boolean {
  return mergeContinueWatchingAt(CW_KEY, CW_TOMBSTONE_KEY, entries);
}

function mergeContinueWatchingAt(key: string, tombstoneKey: string, entries: CWEntry[]): boolean {
  const tombstones = readCWTombstones(tombstoneKey);
  const incoming = entries.filter(
    (entry) =>
      entry &&
      typeof entry.id === "string" &&
      typeof entry.type === "string" &&
      typeof entry.resumeId === "string" &&
      entry.duration > 0 &&
      entry.position > 0 &&
      entry.position / entry.duration < 0.95 &&
      !isTombstoned(entry, tombstones),
  );
  if (!incoming.length) return false;
  const existing = readCWKey(key, tombstoneKey);
  const byResume = new Map<string, CWEntry>();
  let changed = false;
  const merge = (entry: CWEntry, incomingEntry: boolean) => {
    const resumeKey = canonicalPlaybackIdentity(entry.resumeId, entry.type) ??
      `${entry.type.trim().toLowerCase()}\u001f${entry.resumeId.trim().toLowerCase()}`;
    const current = byResume.get(resumeKey);
    if (!current) {
      byResume.set(resumeKey, entry);
      if (incomingEntry) changed = true;
      return;
    }
    if (entry.updatedAt > current.updatedAt) {
      byResume.set(resumeKey, entry);
      changed = true;
    }
  };
  for (const entry of existing) merge(entry, false);
  for (const entry of incoming) merge(entry, true);
  // Canonical variants already present on disk collapse on the next real merge too.
  if (byResume.size < existing.length) changed = true;
  if (!changed) return false;
  const next = [...byResume.values()].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 40);
  try {
    localStorage.setItem(key, JSON.stringify(next));
  } catch {
    /* best-effort */
  }
  return true;
}

// --- Per-profile (scoped) hydration -------------------------------------------------------------
// Account hydration of a SECONDARY (overlay) profile's synced library / continue-watching writes into
// that profile's own scoped key (LIBRARY_KEY.<scope> / CW_KEY.<scope>), matching scopedKey()'s scheme,
// so switching to that profile shows its own titles + resume points. scope "" targets the owner (base
// key). Read-only union (existing local entries win); never deletes. Returns whether anything changed.

function scopedBaseKey(base: string, scope: string): string {
  return scope ? `${base}.${scope}` : base;
}

/** Merge a profile's synced library into its scoped key (union by id, existing wins). */
export function mergeLibraryForScope(scope: string, items: MetaItem[]): boolean {
  const valid = items.filter(
    (m) => m && typeof m.id === "string" && typeof m.type === "string" && typeof m.name === "string",
  );
  if (!valid.length) return false;
  const key = scopedBaseKey(LIBRARY_KEY, scope);
  let existing: MetaItem[] = [];
  try {
    const raw = localStorage.getItem(key);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    if (Array.isArray(parsed)) existing = parsed as MetaItem[];
  } catch {
    existing = [];
  }
  const seen = new Set(existing.map((e) => e.id));
  const additions = valid
    .filter((m) => !seen.has(m.id))
    .map((m) => ({ id: m.id, type: m.type, name: m.name, poster: m.poster }));
  if (!additions.length) return false;
  try {
    localStorage.setItem(key, JSON.stringify([...existing, ...additions]));
  } catch {
    /* best-effort */
  }
  return true;
}

/** Merge a profile's synced continue-watching into its scoped key (union by resumeId, fresher wins). */
export function mergeContinueWatchingForScope(scope: string, entries: CWEntry[]): boolean {
  const key = scopedBaseKey(CW_KEY, scope);
  return mergeContinueWatchingAt(key, scopedBaseKey(CW_TOMBSTONE_KEY, scope), entries);
}

/** Merge remote timestamped removals before live hydration, then prune any now-covered local rows. */
export function mergeContinueWatchingTombstonesForScope(scope: string, incoming: CWTombstone[]): boolean {
  const key = scopedBaseKey(CW_KEY, scope);
  const tombstoneKey = scopedBaseKey(CW_TOMBSTONE_KEY, scope);
  const existing = readCWTombstones(tombstoneKey);
  const next = mergeCWTombstones(existing, incoming);
  const tombstonesChanged = JSON.stringify(next) !== JSON.stringify(existing);
  if (tombstonesChanged) {
    try {
      localStorage.setItem(tombstoneKey, JSON.stringify(next));
    } catch {
      return false;
    }
  }
  const raw = readCWKey(key, tombstoneKey);
  let storedCount = 0;
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(key) ?? "[]");
    storedCount = Array.isArray(parsed) ? parsed.length : 0;
  } catch {
    storedCount = 0;
  }
  const pruned = raw.length !== storedCount;
  if (pruned) {
    try {
      localStorage.setItem(key, JSON.stringify(raw));
    } catch {
      return tombstonesChanged;
    }
  }
  return tombstonesChanged || pruned;
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
    localStorage.setItem(scopedKey(LIBRARY_KEY), JSON.stringify(libraryItems().filter((e) => e.id !== id)));
  } catch {
    /* storage disabled or full: best-effort */
  }
}

// ---- Backup & Restore (export / import the local data as a JSON file) ----
// Mirrors the apps' Backup & Restore. The account session token is deliberately excluded (it is not
// portable data; the account itself syncs server-side). Import overwrites these keys, then the caller
// reloads so every module re-reads fresh state.

const BACKUP_KEYS = [
  "vortx.web.settings.v1",
  "vortx.web.addons.v1",
  "vortx.web.library.v1",
  "vortx.web.cw.v1",
  "vortx.web.cw.removed.v1",
  "vortx.web.recent.v1",
];

/** Serialize the local data (settings, add-ons, library, continue-watching, recent) to a JSON string.
 *  Metadata API keys (MDBList/TMDB) are REDACTED so the plaintext file is safe to store/share - they are
 *  re-enterable after restore. Add-on transport URLs can also embed debrid keys, so the file is flagged
 *  credential-bearing for the export UI to warn on. */
export function exportBackup(): string {
  const data: Record<string, unknown> = {};
  for (const key of BACKUP_KEYS) {
    const raw = localStorage.getItem(key);
    if (raw == null) continue;
    try {
      data[key] = JSON.parse(raw);
    } catch {
      // skip a corrupt key rather than fail the whole export
    }
  }
  let redactedKeys = false;
  const settings = data["vortx.web.settings.v1"];
  if (settings && typeof settings === "object" && !Array.isArray(settings)) {
    for (const k of ["mdblistKey", "tmdbKey"] as const) {
      if ((settings as Record<string, unknown>)[k]) {
        (settings as Record<string, unknown>)[k] = "";
        redactedKeys = true;
      }
    }
  }
  return JSON.stringify(
    {
      app: "vortx-web",
      version: 1,
      redactedKeys,
      note: "Keep this file private: add-on URLs can contain your debrid keys. Metadata API keys are redacted; re-add them after restoring.",
      data,
    },
    null,
    2,
  );
}

/** Type-check one backup value before it is written to localStorage (defends against a malformed or
 *  hostile import injecting unexpected shapes). */
function validBackupValue(key: string, val: unknown): boolean {
  switch (key) {
    case "vortx.web.settings.v1":
      return !!val && typeof val === "object" && !Array.isArray(val);
    case "vortx.web.addons.v1":
      // https-only: a hostile backup file can't inject http/javascript:/data: add-on URLs.
      return Array.isArray(val) && val.every((u) => typeof u === "string" && /^https:\/\//i.test(u));
    case "vortx.web.recent.v1":
      return Array.isArray(val) && val.every((s) => typeof s === "string");
    case "vortx.web.library.v1":
    case "vortx.web.cw.v1":
      return Array.isArray(val) && val.every((e) => !!e && typeof e === "object" && !Array.isArray(e));
    case "vortx.web.cw.removed.v1":
      return Array.isArray(val) && val.every((e) => {
        if (!e || typeof e !== "object" || Array.isArray(e)) return false;
        const tombstone = e as Record<string, unknown>;
        return Array.isArray(tombstone.keys) &&
          tombstone.keys.every((key) => typeof key === "string") &&
          typeof tombstone.removedAt === "number" && Number.isFinite(tombstone.removedAt);
      });
    default:
      return false;
  }
}

/** Restore from an exportBackup() string. Validates the envelope + every present key's shape BEFORE
 *  writing anything (all-or-nothing, so a bad file never half-applies). Returns true on success. */
export function importBackup(json: string): boolean {
  try {
    if (json.length > 5_000_000) return false; // 5 MB sanity cap
    const parsed = JSON.parse(json) as { data?: Record<string, unknown> };
    const data = parsed?.data;
    if (!data || typeof data !== "object" || Array.isArray(data)) return false;
    for (const key of BACKUP_KEYS) {
      if (key in data && !validBackupValue(key, data[key])) return false; // reject the whole import
    }
    for (const key of BACKUP_KEYS) {
      if (key in data) localStorage.setItem(key, JSON.stringify(data[key]));
    }
    return true;
  } catch {
    return false;
  }
}
