import type { Ctx, MetaDetails, Stream } from "./engine";
import { addonNamesByBase } from "./engine";
import { isTorrent, torrentsAvailable } from "./server";

// Ranks loaded streams so the strongest source surfaces first and "Watch Now" can auto-pick one, and
// groups them per add-on for the source filter + quality picker. A focused TypeScript port of the
// Apple app's StreamRanking.swift / CoreStreamSourceGroup. Direct/debrid (`url`) streams always play;
// TORRENT (`infoHash`) streams play too once the embedded streaming server is up (see server.ts), and
// the dominant signals are resolution, source class (remux > bluray > web > …), HDR/Dolby Vision,
// audio, and whether the source is cached/instant.

export interface StreamSourceGroup {
  base: string; // addon transport URL, the grouping key + stable id
  addon: string; // display name, resolved from ctx manifests
  streams: Stream[];
}

/**
 * A stream the desktop can play: any direct/debrid HTTP(S) `url`, plus TORRENT (`infoHash`) streams
 * once the embedded server is running, it turns the infoHash into a playable file endpoint. With the
 * server down, torrents are filtered out (the detail page then explains the empty state).
 */
export function isPlayable(stream: Stream): boolean {
  if (stream.url && /^https?:\/\//i.test(stream.url)) return true;
  return isTorrent(stream) && torrentsAvailable();
}

/** Group the engine's ready stream responses by add-on, mirroring CoreBridge.streamGroups(). */
export function streamGroups(md: MetaDetails | null, ctx: Ctx | null): StreamSourceGroup[] {
  const names = addonNamesByBase(ctx);
  const groups: StreamSourceGroup[] = [];
  for (const group of md?.streams ?? []) {
    if (group.content?.type !== "Ready") continue;
    const streams = (group.content.content ?? []).filter(isPlayable);
    if (!streams.length) continue;
    const base = group.request?.base ?? "addon";
    groups.push({ base, addon: names[base] ?? "Add-on", streams });
  }
  return groups;
}

// ---- Quality text parsing ----------------------------------------------------------------------

/** The lower-cased name + description + filename, where add-ons put their quality tags. */
function qualityText(s: Stream): string {
  return [s.name, s.description, s.behaviorHints?.filename]
    .filter(Boolean)
    .join(" ")
    .toLowerCase()
    .replace(/️/g, ""); // strip the variation selector so "⚡️" matches a bare "⚡"
}

/** A token matched only at delimiter boundaries (no alphanumeric either side). */
function bounded(text: string, pattern: string): boolean {
  return new RegExp(`(?<![a-z0-9])(?:${pattern})(?![a-z0-9])`).test(text);
}

/** Explicit numeric resolution token; wins over marketing tokens (a "UHD.1080p" is a 1080p encode). */
function explicitResolution(t: string): number | null {
  for (const [token, value] of [
    ["2160", 4000],
    ["1440", 1440],
    ["1080", 1080],
    ["720", 720],
    ["576", 540],
    ["480", 480],
  ] as const) {
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

/** A short resolution tag for the Watch-Now button ("4K" / "1080p" / …), or "Best" when unknown. */
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

/** Whether this stream plays instantly (an explicit add-on cache marker, or a plain URL). */
function isCached(s: Stream, text: string): boolean {
  if (
    text.includes("⏳") ||
    text.includes("⬇") ||
    text.includes("uncached") ||
    text.includes("not ready") ||
    bounded(text, "download")
  ) {
    return false;
  }
  if (
    text.includes("⚡") ||
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
  // File size is the strongest objective signal WITHIN a resolution tier (capped so it never lifts
  // a 1080p over a 4K).
  value += Math.min(Math.round(sizeGB(t) * 6), 600);
  if (t.includes("atmos") || t.includes("truehd") || t.includes("true-hd")) value += 70;
  else if (t.includes("dts-hd") || t.includes("dts hd") || t.includes("dts-ma")) value += 50;
  else if (t.includes("dts")) value += 20;
  // Cached/instant dominates within its tier.
  if (isCached(s, t)) value += 8000;
  scoreCache.set(s, value);
  return value;
}

/** Each group's streams sorted best-first, stable within equal scores (add-on order preserved). */
export function rankedGroups(groups: StreamSourceGroup[]): StreamSourceGroup[] {
  return groups.map((group) => {
    const scored = group.streams.map((stream, index) => ({ stream, index, s: score(stream) }));
    scored.sort((a, b) => (a.s !== b.s ? b.s - a.s : a.index - b.index));
    return { ...group, streams: scored.map((x) => x.stream) };
  });
}

/** The single best playable stream across all groups, for the one-press "Watch Now". */
export function best(groups: StreamSourceGroup[]): Stream | undefined {
  const all = groups.flatMap((g) => g.streams).filter(isPlayable);
  if (!all.length) return undefined;
  return all.reduce((b, s) => (score(s) > score(b) ? s : b));
}

/** Enriched label for the Watch-Now button, from the EXACT stream best() plays ("4K · HDR · Remux"). */
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
export function tiers(groups: StreamSourceGroup[]): string[] {
  const present = new Set<string>();
  for (const s of groups.flatMap((g) => g.streams)) present.add(tierOf(s));
  return ["4K", "1080p", "720p", "Others"].filter((t) => present.has(t));
}

export interface QualityOption {
  label: string;
  stream: Stream;
}

/** Distinct flavor variants inside one resolution tier ("Dolby Vision · Remux · 12.4 GB"), best-first. */
export function variantOptions(groups: StreamSourceGroup[], wanted: string): QualityOption[] {
  const playable = groups.flatMap((g) => g.streams).filter((s) => tierOf(s) === wanted);
  const best: Record<string, { score: number; stream: Stream }> = {};
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
    if (best[key] && best[key].score >= sc) continue;
    best[key] = { score: sc, stream: s };
  }
  return Object.entries(best)
    .map(([key, v]) => {
      const sizeMatch = qualityText(v.stream).match(/(\d+(?:\.\d+)?)\s*(gb|gib)/);
      const size = sizeMatch ? sizeMatch[0].toUpperCase().replace("GIB", "GB") : null;
      return { label: size ? `${key}  ·  ${size}` : key, stream: v.stream };
    })
    .sort((a, b) => score(b.stream) - score(a.stream))
    .slice(0, 8);
}

/** Source-class / cache tags for a stream row, the way the Apple app's sourceDetail labels them. */
export function sourceTags(s: Stream): string {
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
  return tags.join(" · ");
}
