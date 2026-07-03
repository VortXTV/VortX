import type { Stream } from "./types";
import type { StreamGroup } from "./addon";
import type { Settings } from "./settings";

// Ranks loaded streams so the strongest source surfaces first and "Watch" can auto-pick one, and
// groups them per add-on for the source filter + quality picker. A focused port of the Apple app's
// StreamRanking.swift (and desktop/src/streamRanking.ts). The dominant signals are resolution, source
// class (remux > bluray > web > ...), HDR/Dolby Vision, audio, file size, and cache/instant markers.
//
// KEY WEB DIFFERENCE FROM DESKTOP: the web client has no embedded streaming server, so a TORRENT
// (infoHash, no url) stream is NOT playable here. `isPlayable` accepts only direct/debrid HTTP(S)
// urls. Torrent-only sources are still surfaced (see playableState) but greyed out with an
// explanation, per the README's "direct/debrid/HLS-first" contract.
//
// MIN-SAFARI CONSTRAINT (conscious): the codec/quality-marker regexes below use lookbehind assertions
// ((?<![a-z0-9]) word-boundary guards on codec/container/CAM/AV1 tokens). Regex literals are parsed at
// script-parse time and the build target is es2021, so esbuild leaves lookbehind untouched (it cannot
// lower regex assertions). That means this module's minimum runtime is iOS Safari >= 16.4 (RegExp
// lookbehind support). This is the same baseline the CAM/FAKE/AV1 filters already required, so it is
// the effective web floor, not a new constraint. If the support matrix must reach older Safari, these
// guards have to be rewritten to a capture-group boundary-set form ((?:^|[^a-z0-9])(token)(?:[^a-z0-9]|$))
// rather than left as lookbehind.

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

/** Group the add-on stream responses into playable, per-add-on, best-first ranked groups. When
 *  `keepAddonOrder` is set (the "Use add-on ranking order" setting), the add-on's own order is preserved
 *  instead of VortX's quality ranking. */
export function rankedGroups(groups: StreamGroup[], keepAddonOrder = false): RankedGroup[] {
  const ranked: RankedGroup[] = [];
  for (const group of groups) {
    const playable = group.streams.filter(isPlayable);
    if (!playable.length) continue;
    const scored = playable.map((stream, index) => ({ stream, index, s: keepAddonOrder ? 0 : score(stream) }));
    scored.sort((a, b) => (a.s !== b.s ? b.s - a.s : a.index - b.index));
    ranked.push({
      base: group.transportUrl,
      addon: group.addonName,
      streams: scored.map((x) => x.stream),
    });
  }
  return ranked;
}

/** Mobile browsers (iOS Safari / Android Chrome) can't demux MKV and lack AC3/EAC3/DTS/TrueHD decoders, so
 *  an MKV / HEVC / lossless-audio source plays as a black <video>. Detect a mobile browser so the auto-pick
 *  prefers (and the player can gate on) a mobile-playable MP4/H.264/AAC source. */
export function isMobileBrowser(): boolean {
  if (typeof navigator === "undefined") return false;
  const ua = navigator.userAgent;
  const touchMac = /Macintosh/.test(ua) && ((navigator as { maxTouchPoints?: number }).maxTouchPoints ?? 0) > 1; // iPadOS masquerades as Mac
  return /iP(ad|hone|od)/.test(ua) || /Android/.test(ua) || touchMac;
}

/** True if a direct stream is likely to PLAY in a mobile browser: not flagged notWebReady, and not an MKV
 *  container / HEVC video / lossless-or-undecodable audio codec that mobile Safari/Chrome can't handle. A
 *  SOFT heuristic on the quality text + url; never a hard block (callers fall back to the best source). */
export function isMobileFriendly(s: Stream): boolean {
  if (s.behaviorHints?.notWebReady) return false;
  const t = (qualityText(s) + " " + (s.url ?? "")).toLowerCase();
  if (/(?<![a-z0-9])(mkv|matroska)(?![a-z0-9])|x-matroska/.test(t)) return false;
  if (/(?<![a-z0-9])(hevc|h\.?265|x265)(?![a-z0-9])/.test(t)) return false;                 // mobile HEVC-in-mp4 is spotty; prefer H.264
  if (/(?<![a-z0-9])(ac3|eac3|e-ac-3|dts|dts-hd|truehd|atmos)(?![a-z0-9])/.test(t)) return false; // no mobile decoder
  return true;
}

/** Prefer mobile-playable sources when the browser is mobile; fall back to the whole pool when none are. */
function mobilePool(pool: Stream[]): Stream[] {
  if (!isMobileBrowser()) return pool;
  const friendly = pool.filter(isMobileFriendly);
  return friendly.length ? friendly : pool;
}

/** Audio codecs NO browser can decode in an HTML5 <video> (AC3/E-AC3/DTS/TrueHD are the common culprits in
 *  debrid remuxes). When a source's label declares one of these, the video plays but the audio is silent -
 *  the D6 "mobile no audio" bug. Distinct from isMobileFriendly (which also gates MKV/HEVC on mobile only):
 *  this is a codec-only signal that holds on desktop too, used to prefer decodable audio and to explain an
 *  auto-advance honestly. A SOFT heuristic on the label text; never a hard block. */
export function hasUndecodableAudio(s: Stream): boolean {
  const t = (qualityText(s) + " " + (s.url ?? "")).toLowerCase();
  return /(?<![a-z0-9])(ac3|eac3|e-ac-3|e-ac3|dts|dts-hd|dts-ma|truehd|true-hd|atmos)(?![a-z0-9])/.test(t);
}

/** Whether a source is LIKELY to have browser-decodable audio: it either declares a browser-friendly codec
 *  (AAC/Opus/MP3/FLAC/Vorbis), or it declares no undecodable codec at all (unknown -> optimistically allow,
 *  since most web-dl/mp4 encodes carry AAC). Used to rank/auto-advance toward a source that will actually
 *  produce sound in the browser. */
export function hasDecodableAudio(s: Stream): boolean {
  return !hasUndecodableAudio(s);
}

/** An ordered fallback chain of playable sources for one title/episode, best-first, with sources whose audio
 *  the browser can decode preferred ahead of the rest. The player walks this list: it starts on the best
 *  source, and on a decode error or detected silent-audio it advances to the next entry. Sources are still
 *  ranked by quality WITHIN each audio-decodability bucket, so we never drop from a decodable 4K to a
 *  decodable 480p unnecessarily, and undecodable-audio sources stay as a last resort rather than vanishing
 *  (some browsers/OSes DO carry the codec, so they can still work). On mobile the mobile-friendly filter is
 *  applied to the decodable bucket first as well. */
export function playbackFallbacks(groups: RankedGroup[]): Stream[] {
  const all = groups.flatMap((g) => g.streams).filter(isPlayable);
  if (!all.length) return [];
  const byScore = (a: Stream, b: Stream): number => score(b) - score(a);
  const decodable = all.filter(hasDecodableAudio).sort(byScore);
  const undecodable = all.filter((s) => !hasDecodableAudio(s)).sort(byScore);
  // On mobile, float the mobile-friendly decodable sources to the very front (they also avoid MKV/HEVC),
  // but keep the rest of the decodable sources next so a fallback is always available.
  if (isMobileBrowser()) {
    const friendly = decodable.filter(isMobileFriendly);
    const rest = decodable.filter((s) => !isMobileFriendly(s));
    return [...friendly, ...rest, ...undecodable];
  }
  return [...decodable, ...undecodable];
}

/** The single best playable stream across all groups, for the one-press "Watch". On mobile, prefers a
 *  mobile-playable source so Watch doesn't auto-pick an MKV/HEVC that renders a black <video>. */
export function best(groups: RankedGroup[]): Stream | undefined {
  const all = groups.flatMap((g) => g.streams).filter(isPlayable);
  if (!all.length) return undefined;
  const pool = mobilePool(all);
  return pool.reduce((b, s) => (score(s) > score(b) ? s : b));
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
  const pool = mobilePool(eligible.length ? eligible : all);
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

// ---- Source filtering (the Streams settings group) ----------------------------------------------

/** CAM / telesync / screener markers - hidden by the Safety filter (moderate+). */
const CAM_RE = /(?<![a-z0-9])(?:cam|cam[ .\-_]?rip|hdcam|ts|telesync|tele[ .\-_]?cine|tc|hdts|scr|screener|workprint|wp)(?![a-z0-9])/;
/** Outright fake / spam markers - hidden by the Safety filter at the strict level. */
const FAKE_RE = /(?<![a-z0-9])(?:fake|spam|virus|password)(?![a-z0-9])/;

function isAV1(t: string): boolean {
  return /(?<![a-z0-9])av1(?![a-z0-9])/.test(t);
}

function isHDRish(t: string): boolean {
  return t.includes("hdr") || t.includes("dolby vision") || t.includes("dolbyvision") || t.includes("dovi");
}

/** A torrent source advertising zero seeders (so it would never start). Torrents are unplayable on web
 *  regardless, but this still prunes them from the surfaced (greyed) list when the user asks. */
function isDeadTorrent(s: Stream, t: string): boolean {
  if (!isTorrent(s)) return false;
  return /(?<![a-z0-9])0\s*(?:seed|seeds|seeders|peers)(?![a-z0-9])/.test(t) || /👤\s*0(?![0-9])/.test(t);
}

function csvWords(raw: string): string[] {
  return raw
    .split(",")
    .map((w) => w.trim().toLowerCase())
    .filter(Boolean);
}

/** Apply the user's Streams settings (filters) to the raw add-on responses, before ranking/grouping.
 *  Returns groups with the same shape but pruned `streams`. Filters that only make sense for torrents
 *  (dead-torrent, direct-links-only) still run so the surfaced/greyed torrent list honours them too. */
export function applyStreamFilters(groups: StreamGroup[], s: Settings): StreamGroup[] {
  const hide = csvWords(s.hideWords);
  const need = csvWords(s.requireWords);
  const filterOne = (stream: Stream): boolean => {
    const t = qualityText(stream);
    if (s.directLinksOnly && isTorrent(stream)) return false;
    if (s.instantOnly && !isCached(stream, t)) return false;
    if (s.hideDeadTorrents && isDeadTorrent(stream, t)) return false;
    if (s.hdrOnly && !isHDRish(t)) return false;
    if (s.hideAV1 && isAV1(t)) return false;
    if (s.safetyFilter !== "off" && CAM_RE.test(t)) return false;
    if (s.safetyFilter === "strict" && FAKE_RE.test(t)) return false;
    if (s.maxQuality) {
      const r = resolutionOf(stream);
      if (r !== null && r > s.maxQuality) return false;
    }
    if (s.maxFileSizeGB) {
      const gb = sizeGB(t);
      if (gb > 0 && gb > s.maxFileSizeGB) return false;
    }
    if (hide.length && hide.some((w) => t.includes(w))) return false;
    if (need.length && !need.every((w) => t.includes(w))) return false;
    return true;
  };
  return groups.map((g) => ({ ...g, streams: g.streams.filter(filterOne) }));
}
