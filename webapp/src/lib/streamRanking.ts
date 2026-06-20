import type { Stream } from "./types";
import type { StreamGroup } from "./addon";

// Ranks loaded streams so the strongest source surfaces first and "Watch" can auto-pick one, and
// groups them per add-on for the source filter + quality picker. A focused port of the Apple app's
// StreamRanking.swift (and desktop/src/streamRanking.ts). The dominant signals are resolution, source
// class (remux > bluray > web > ...), HDR/Dolby Vision, audio, file size, and cache/instant markers.
//
// KEY WEB DIFFERENCE FROM DESKTOP: the web client has no embedded streaming server, so a TORRENT
// (infoHash, no url) stream is NOT playable here. `isPlayable` accepts only direct/debrid HTTP(S)
// urls. Torrent-only sources are still surfaced (see playableState) but greyed out with an
// explanation, per the README's "direct/debrid/HLS-first" contract.

export interface RankedGroup {
  base: string; // addon transport URL - the grouping key + stable id
  addon: string; // display name
  streams: Stream[];
}

/** A torrent stream: no direct url, but an infoHash a streaming server would be needed to play. */
export function isTorrent(stream: Stream): boolean {
  return !stream.url && !!stream.infoHash;
}

/** A stream the browser can play directly: any direct/debrid HTTP(S) url. Torrents are NOT playable
 *  on the web client (no streaming server) and YouTube-only streams are handled separately. */
export function isPlayable(stream: Stream): boolean {
  return !!stream.url && /^https?:\/\//i.test(stream.url);
}

/** Whether at least one source exists but none are playable (torrents only) - drives the empty-state
 *  copy that explains the web client needs direct/debrid links. */
export function hasOnlyUnplayable(groups: StreamGroup[]): boolean {
  const all = groups.flatMap((g) => g.streams);
  if (!all.length) return false;
  return !all.some(isPlayable);
}

// ---- Quality text parsing ----------------------------------------------------------------------

/** The lower-cased name + title + description + filename, where add-ons put their quality tags. */
function qualityText(s: Stream): string {
  return [s.name, s.title, s.description, s.behaviorHints?.filename]
    .filter(Boolean)
    .join(" ")
    .toLowerCase()
    .replace(/️/g, ""); // strip the variation selector so an emoji + selector matches the bare glyph
}

/** A token matched only at delimiter boundaries (no alphanumeric either side). */
function bounded(text: string, pattern: string): boolean {
  return new RegExp(`(?<![a-z0-9])(?:${pattern})(?![a-z0-9])`).test(text);
}

/** Explicit numeric resolution token; wins over marketing tokens (a "UHD.1080p" is a 1080p encode). */
function explicitResolution(t: string): number | null {
  const table: ReadonlyArray<readonly [string, number]> = [
    ["2160", 4000],
    ["1440", 1440],
    ["1080", 1080],
    ["720", 720],
    ["576", 540],
    ["480", 480],
  ];
  for (const [token, value] of table) {
    if (bounded(t, `${token}p?`)) return value;
  }
  return null;
}

function resolution(t: string): number {
  const r = explicitResolution(t);
  if (r !== null) return r;
  if (bounded(t, "4k") || bounded(t, "uhd")) return 4000;
  return 100; // unknown: below any labelled stream
}

/** A short resolution tag for the Watch button ("4K" / "1080p" / ...), or "Best" when unknown. */
export function qualityLabel(s: Stream): string {
  const t = qualityText(s);
  const r = explicitResolution(t);
  if (r !== null) return r >= 4000 ? "4K" : `${r}p`;
  if (bounded(t, "4k") || bounded(t, "uhd")) return "4K";
  return "Best";
}

function sizeGB(t: string): number {
  const m = t.match(/(\d+(?:\.\d+)?)\s*g(i)?b/);
  return m ? parseFloat(m[1]) : 0;
}

/** Whether this stream plays instantly (an explicit add-on cache marker, or a plain url). */
function isCached(s: Stream, text: string): boolean {
  if (
    text.includes("⏳") || // hourglass
    text.includes("⬇") || // down arrow
    text.includes("uncached") ||
    text.includes("not ready") ||
    bounded(text, "download")
  ) {
    return false;
  }
  if (
    text.includes("⚡") || // high voltage
    text.includes("+]") ||
    text.includes("instant") ||
    text.includes("cached")
  ) {
    return true;
  }
  return !!s.url && !s.infoHash;
}

// ---- Scoring -----------------------------------------------------------------------------------

const scoreCache = new WeakMap<Stream, number>();

/** Base quality score: resolution + source class + HDR + size + audio + cached, best-first. */
export function score(s: Stream): number {
  const cached = scoreCache.get(s);
  if (cached !== undefined) return cached;
  const t = qualityText(s);
  let value = resolution(t);
  // Source ladder: remux > bluray > web-dl > webrip > hdtv > dvdrip > tv captures.
  if (t.includes("remux")) value += 250;
  else if (t.includes("bluray") || t.includes("blu-ray") || bounded(t, "b[dr][ .\\-_]?rip")) value += 120;
  else if (bounded(t, "web[ .\\-_]?dl")) value += 100;
  else if (bounded(t, "web[ .\\-_]?rip")) value += 40;
  else if (bounded(t, "web")) value += 100;
  else if (t.includes("hdtv")) value -= 150;
  else if (bounded(t, "dvd[ .\\-_]?rip")) value -= 200;
  if (t.includes("hdr") || t.includes("dolby vision") || t.includes("dolbyvision") || t.includes("dovi")) {
    value += 80;
  }
  // File size is the strongest objective signal WITHIN a resolution tier (capped so it never lifts a
  // 1080p over a 4K).
  value += Math.min(Math.round(sizeGB(t) * 6), 600);
  if (t.includes("atmos") || t.includes("truehd") || t.includes("true-hd")) value += 70;
  else if (t.includes("dts-hd") || t.includes("dts hd") || t.includes("dts-ma")) value += 50;
  else if (t.includes("dts")) value += 20;
  // Cached/instant dominates within its tier.
  if (isCached(s, t)) value += 8000;
  scoreCache.set(s, value);
  return value;
}

/** Group the add-on stream responses into playable, per-add-on, best-first ranked groups. */
export function rankedGroups(groups: StreamGroup[]): RankedGroup[] {
  const ranked: RankedGroup[] = [];
  for (const group of groups) {
    const playable = group.streams.filter(isPlayable);
    if (!playable.length) continue;
    const scored = playable.map((stream, index) => ({ stream, index, s: score(stream) }));
    scored.sort((a, b) => (a.s !== b.s ? b.s - a.s : a.index - b.index));
    ranked.push({
      base: group.transportUrl,
      addon: group.addonName,
      streams: scored.map((x) => x.stream),
    });
  }
  return ranked;
}

/** The single best playable stream across all groups, for the one-press "Watch". */
export function best(groups: RankedGroup[]): Stream | undefined {
  const all = groups.flatMap((g) => g.streams).filter(isPlayable);
  if (!all.length) return undefined;
  return all.reduce((b, s) => (score(s) > score(b) ? s : b));
}

/** A stream's resolution as a number (2160 / 1080 / ...), or null when the source doesn't declare one. */
export function resolutionOf(s: Stream): number | null {
  const label = qualityLabel(s);
  if (label === "4K") return 2160;
  const m = label.match(/^(\d+)p$/);
  return m ? Number(m[1]) : null;
}

/** Auto-pick honoring a preferred max resolution: the highest-SCORED playable stream at or under `maxRes`
 *  (sources with no declared resolution are allowed through). maxRes = 0 means "Auto" -> the absolute best.
 *  Falls back to the absolute best when nothing meets the cap, so the user is never left with no source. */
export function pickPreferred(groups: RankedGroup[], maxRes: number): Stream | undefined {
  if (!maxRes) return best(groups);
  const all = groups.flatMap((g) => g.streams).filter(isPlayable);
  if (!all.length) return undefined;
  const eligible = all.filter((s) => {
    const r = resolutionOf(s);
    return r === null || r <= maxRes;
  });
  const pool = eligible.length ? eligible : all;
  return pool.reduce((b, s) => (score(s) > score(b) ? s : b));
}

/** Enriched label for the Watch button, from the EXACT stream best() plays ("4K - HDR - Remux"). */
export function watchLabel(s: Stream): string {
  const t = qualityText(s);
  const tags = [qualityLabel(s)];
  if (t.includes("dolby vision") || t.includes("dolbyvision") || t.includes("dovi")) tags.push("DV");
  else if (t.includes("hdr")) tags.push("HDR");
  if (t.includes("remux")) tags.push("Remux");
  else if (t.includes("bluray") || t.includes("blu-ray")) tags.push("BluRay");
  else if (bounded(t, "web[ .\\-_]?(dl|rip)?")) tags.push("WEB");
  return tags.join(" · ");
}

// ---- Quality picker (two levels: resolution tier, then flavor variant) -------------------------

function tierOf(s: Stream): string {
  switch (qualityLabel(s)) {
    case "4K":
      return "4K";
    case "1080p":
      return "1080p";
    case "720p":
      return "720p";
    default:
      return "Others";
  }
}

/** The resolution tiers that actually have playable sources, in fixed order. */
export function tiers(groups: RankedGroup[]): string[] {
  const present = new Set<string>();
  for (const s of groups.flatMap((g) => g.streams)) present.add(tierOf(s));
  return ["4K", "1080p", "720p", "Others"].filter((t) => present.has(t));
}

export interface QualityOption {
  label: string;
  stream: Stream;
}

/** Distinct flavor variants inside one resolution tier ("Dolby Vision - Remux - 12.4 GB"), best-first. */
export function variantOptions(groups: RankedGroup[], wanted: string): QualityOption[] {
  const playable = groups.flatMap((g) => g.streams).filter((s) => tierOf(s) === wanted);
  const bestByKey: Record<string, { score: number; stream: Stream }> = {};
  for (const s of playable) {
    const t = qualityText(s);
    const tags: string[] = [];
    if (t.includes("dolby vision") || t.includes("dolbyvision") || t.includes("dovi")) tags.push("Dolby Vision");
    else if (t.includes("hdr")) tags.push("HDR");
    if (t.includes("remux")) tags.push("Remux");
    else if (t.includes("bluray") || t.includes("blu-ray")) tags.push("BluRay");
    else if (t.includes("web")) tags.push("WEB");
    if (t.includes("atmos")) tags.push("Atmos");
    else if (t.includes("truehd")) tags.push("TrueHD");
    else if (t.includes("dts-hd") || t.includes("dts hd")) tags.push("DTS-HD");
    const key = tags.length ? tags.join(" · ") : "Standard";
    const sc = score(s);
    if (bestByKey[key] && bestByKey[key].score >= sc) continue;
    bestByKey[key] = { score: sc, stream: s };
  }
  return Object.entries(bestByKey)
    .map(([key, v]) => {
      const sizeMatch = qualityText(v.stream).match(/(\d+(?:\.\d+)?)\s*(gb|gib)/);
      const size = sizeMatch ? sizeMatch[0].toUpperCase().replace("GIB", "GB") : null;
      return { label: size ? `${key}  ·  ${size}` : key, stream: v.stream };
    })
    .sort((a, b) => score(b.stream) - score(a.stream))
    .slice(0, 8);
}

/** Source-class / cache tags for a stream row, the way the Apple app's sourceDetail labels them. */
/** The quality/source signals for a stream, as a list (resolution, source type, HDR, audio, cache). The
 *  detail UI renders each as its own colored chip; sourceTags keeps the joined-string form for any caller. */
export function sourceTagList(s: Stream): string[] {
  const t = qualityText(s);
  const tags: string[] = [qualityLabel(s)];
  if (t.includes("remux")) tags.push("Remux");
  else if (t.includes("bluray") || t.includes("blu-ray")) tags.push("BluRay");
  else if (t.includes("web")) tags.push("WEB");
  if (t.includes("dolby vision") || t.includes("dolbyvision") || t.includes("dovi")) tags.push("DV");
  else if (t.includes("hdr")) tags.push("HDR");
  if (t.includes("atmos")) tags.push("Atmos");
  else if (t.includes("dts-hd") || t.includes("dts hd")) tags.push("DTS-HD");
  else if (t.includes("dts")) tags.push("DTS");
  if (isCached(s, t)) tags.push("Cached");
  return tags.filter(Boolean);
}

export function sourceTags(s: Stream): string {
  return sourceTagList(s).join(" · ");
}
