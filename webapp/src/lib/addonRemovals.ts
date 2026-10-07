/** Same monotone install/remove receipts as Apple's AddonTombstones. Hydration must never
 * turn an old flat removal list into a fresh removal that defeats an explicit reinstall. */
export function effectiveAddonRemovals(doc: Record<string, unknown>): Set<string> {
  const object = (value: unknown): Record<string, unknown> =>
    value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
  const normalize = (value: string) => value.trim().toLowerCase();
  const validStamp = (value: unknown): value is number =>
    typeof value === "number" && Number.isFinite(value) && value >= 0;
  const removed = new Map<string, number>();
  const added = new Map<string, number>();
  const stamped = new Set<string>();
  const put = (map: Map<string, number>, raw: string, stamp: number) => {
    const url = normalize(raw);
    if (url && url.length <= 2048) map.set(url, Math.max(map.get(url) ?? 0, stamp));
  };
  const vortx = object(doc.vortx);
  for (const [url, value] of Object.entries(object(vortx.deletedAddonsTs))) {
    const entry = object(value);
    if (validStamp(entry.removedAt)) { put(removed, url, entry.removedAt); stamped.add(normalize(url)); }
    if (validStamp(entry.addedAt)) { put(added, url, entry.addedAt); stamped.add(normalize(url)); }
  }
  for (const [url, value] of Object.entries(object(doc.removedAddons))) {
    // The website writes numeric epoch milliseconds. Bad/old values remain legacy receipts,
    // not wall-clock "now", so importing the same document is deterministic.
    put(removed, url, validStamp(value) ? value : 1);
  }
  for (const list of [doc.webAddonRemovals, vortx.deletedAddons]) {
    if (!Array.isArray(list)) continue;
    for (const url of list) {
      if (typeof url === "string" && !stamped.has(normalize(url))) put(removed, url, 1);
    }
  }
  return new Set([...removed].filter(([url, time]) => time > (added.get(url) ?? 0)).map(([url]) => url));
}

/** Explicit website user intent writes the same timestamp receipts the apps consume.
 * Merely hydrating an installed list must never call this or mint new timestamps. */
export function applyAddonIntents(doc: Record<string, unknown>,
  hint: { added?: string[]; removed?: string[] } | undefined, now: number): void {
  if (!hint || !Number.isFinite(now) || now < 0) return;
  const object = (value: unknown): Record<string, unknown> =>
    value && typeof value === "object" && !Array.isArray(value) ? { ...value as Record<string, unknown> } : {};
  const vortx = object(doc.vortx);
  const stamps = object(vortx.deletedAddonsTs);
  const webRemoved = object(doc.removedAddons);
  const normalize = (value: string) => value.trim().toLowerCase();
  const write = (raw: string, field: "addedAt" | "removedAt") => {
    const url = normalize(raw);
    if (!url || url.length > 2048) return;
    const entry: Record<string, unknown> = {};
    // Fold casing aliases before writing, retaining newer receipts from another device.
    for (const [key, value] of Object.entries(stamps)) if (normalize(key) === url) {
      for (const [name, field] of Object.entries(object(value)))
        if (name !== "addedAt" && name !== "removedAt") entry[name] = field;
      for (const name of ["addedAt", "removedAt"]) {
        const time = object(value)[name];
        if (typeof time === "number" && Number.isFinite(time) && time >= 0)
          entry[name] = Math.max(Number(entry[name] ?? 0), time);
      }
      delete stamps[key];
    }
    // Older website clients store real removal clocks in this sibling map. Deleting its alias
    // before folding it could let a stale reinstall erase a newer device's removal.
    for (const [key, value] of Object.entries(webRemoved)) if (normalize(key) === url) {
      const time = typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 1;
      entry.removedAt = Math.max(Number(entry.removedAt ?? 0), time);
    }
    entry[field] = Math.max(Number(entry[field] ?? 0), now);
    stamps[url] = entry;
    for (const key of Object.keys(webRemoved)) if (normalize(key) === url) delete webRemoved[key];
    if (field === "removedAt") webRemoved[url] = entry.removedAt;
  };
  for (const url of hint.removed ?? []) write(url, "removedAt");
  for (const url of hint.added ?? []) write(url, "addedAt");
  vortx.deletedAddonsTs = stamps;
  doc.vortx = vortx;
  doc.removedAddons = webRemoved;
  const removed = effectiveAddonRemovals(doc);
  doc.webAddonRemovals = [...removed];
  vortx.deletedAddons = [...removed];
}
