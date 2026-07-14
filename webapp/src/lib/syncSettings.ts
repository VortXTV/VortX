// Bidirectional mapping between the synced account doc's per-profile settings and the webapp's flat
// Settings shape. This is the read-down (account -> webapp) and write-up (webapp -> account) bridge so
// settings the user sets in a VortX app or the vortx.tv dashboard show on the web, and vice-versa.
//
// Two doc shapes carry the same values:
//   - doc.vortx.profiles[main].settings        -> app-authored mirror, top-level key `accentID`
//   - doc.profileEdits.roster[main].settings   -> web/dashboard-authored, top-level key `accent`
// Both nest playback/stream knobs under `settings.playback`. We read both (profileEdits wins when newer
// than the vortx mirror, matching the roster overlay rule), and we WRITE the dashboard-compatible shape
// (`accent`, nested `playback`) into doc.profileEdits so the webapp round-trips with the dashboard and
// the app treats it identically. Every field is validated against the webapp's own enums/ranges before
// it is applied, so a value the webapp does not understand is ignored rather than corrupting state.

import {
  ACCENTS,
  TEXT_MIN,
  TEXT_MAX,
  SUB_MIN,
  SUB_MAX,
  type Settings,
  type Background,
  type SubtitlesMode,
  type SafetyFilter,
  type SubtitleFont,
  type SubtitleColor,
  type SubtitleEdge,
  type SourceType,
} from "./settings";

type Obj = Record<string, unknown>;

const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const bool = (v: unknown): boolean | undefined => (typeof v === "boolean" ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const clamp = (n: number, lo: number, hi: number): number => Math.min(hi, Math.max(lo, n));
function oneOf<T extends string>(v: unknown, set: readonly T[]): T | undefined {
  return typeof v === "string" && (set as readonly string[]).includes(v) ? (v as T) : undefined;
}

const BACKGROUNDS = ["warm", "oled"] as const;
const SUB_MODES: readonly SubtitlesMode[] = ["off", "on", "forced"];
const SAFETY: readonly SafetyFilter[] = ["off", "moderate", "strict"];
const SUB_FONT_IDS: readonly SubtitleFont[] = ["modern", "classic", "mono"];
const SUB_COLOR_IDS: readonly SubtitleColor[] = ["white", "yellow", "cyan", "mint"];
const SUB_EDGE_IDS: readonly SubtitleEdge[] = ["outline", "shadow", "box", "none"];
const SOURCE_TYPES: readonly SourceType[] = ["debrid", "usenet", "torrent", "direct"];
// The app's legal Max-quality caps (iOSSettingsView Picker tags): 0 / 720 / 1080 / 4000. 4K is 4000 (NOT
// 2160) because the app's cap compares against a resolution SCORE where a 2160p token parses to 4000
// (StreamRanking.resolution); a legacy web build stored the 4K cap as 2160, so read-down normalizes that.
const MAX_RES_VALUES: readonly number[] = [0, 720, 1080, 4000];
// The app's legal Minimum-quality floors (iOSSettingsView Picker tags): 0 / 720 / 1080 / 2160. 4K is 2160
// here (NOT 4000) because the floor compares against a KNOWN raw resolution height, not the score.
const MIN_RES_VALUES: readonly number[] = [0, 720, 1080, 2160];

/** The MAIN/owner profile id in the synced doc (the profile whose settings mirror the webapp's single
 *  global Settings). The entry flagged `main`, else the first profile. Null when there are no profiles. */
export function mainProfileId(doc: Obj): string | null {
  const vortx = obj(doc.vortx);
  const profiles = Array.isArray(vortx.profiles) ? (vortx.profiles as unknown[]) : [];
  const rows = profiles.filter((p): p is Obj => !!p && typeof p === "object" && (p as Obj).id != null);
  if (!rows.length) return null;
  const main = rows.find((p) => p.main === true) ?? rows[0];
  return String(main.id);
}

/** Merge the app-mirror and (when newer) the web/dashboard overlay into one settings object for the main
 *  profile: top-level {...} plus a merged `playback`. Returns {} when there is no main profile. Exported
 *  so write-up can use it as the base it merges webapp-owned keys over (preserving unmodeled keys). */
export function effectiveMainSettings(doc: Obj): Obj {
  const vortx = obj(doc.vortx);
  const mainId = mainProfileId(doc);
  if (!mainId) return {};
  const profiles = (Array.isArray(vortx.profiles) ? vortx.profiles : []) as Obj[];
  const base = obj(profiles.find((p) => obj(p).id != null && String(obj(p).id) === mainId)?.settings);

  let overlay: Obj = {};
  const edits = obj(doc.profileEdits);
  const newer = (num(edits.editedAt) ?? 0) > (num(vortx.updatedAt) ?? 0);
  if (newer && Array.isArray(edits.roster)) {
    const e = (edits.roster as Obj[]).find((r) => obj(r).id != null && String(obj(r).id) === mainId);
    if (e) overlay = obj(e.settings);
  }
  return { ...base, ...overlay, playback: { ...obj(base.playback), ...obj(overlay.playback) } };
}

/** READ-DOWN: build a validated Partial<Settings> from the synced doc's main-profile settings. Only keys
 *  present and valid are included, so missing/odd values fall back to the webapp's current value. */
export function settingsPatchFromDoc(doc: Obj): Partial<Settings> {
  const s = effectiveMainSettings(doc);
  const p = obj(s.playback);
  const out: Partial<Settings> = {};

  // Appearance (top-level on the settings object).
  const accent = str(s.accentID) ?? str(s.accent); // app uses accentID, dashboard uses accent
  if (accent && ACCENTS.some((a) => a.id === accent)) out.accentID = accent;
  const bg = oneOf<Background>(s.oled === true ? "oled" : s.oled === false ? "warm" : undefined, BACKGROUNDS);
  if (bg) out.background = bg;
  const ts = num(s.textScale);
  if (ts !== undefined) out.textScale = clamp(ts, TEXT_MIN, TEXT_MAX);

  // Playback + subtitles.
  const audio = str(p.audioLang);
  if (audio !== undefined) out.audioLang = audio;
  const sub = str(p.subtitleLang);
  if (sub !== undefined) out.subtitleLang = sub;
  const mode = oneOf<SubtitlesMode>(p.forced ?? p.forcedPolicy, SUB_MODES);
  if (mode) out.subtitlesMode = mode;
  const font = oneOf<SubtitleFont>(p.subFont, SUB_FONT_IDS);
  if (font) out.subtitleFont = font;
  const color = oneOf<SubtitleColor>(p.subColor, SUB_COLOR_IDS);
  if (color) out.subtitleColor = color;
  const edge = oneOf<SubtitleEdge>(p.subBackground, SUB_EDGE_IDS);
  if (edge) out.subtitleEdge = edge;
  const ss = num(p.subSizeScale);
  if (ss !== undefined) out.subtitleScale = clamp(ss, SUB_MIN, SUB_MAX);

  // Stream filtering + ranking.
  const ao = bool(p.useAddonOrder);
  if (ao !== undefined) out.useAddonOrder = ao;
  if (Array.isArray(p.sourceTypeOrder)) {
    const order = (p.sourceTypeOrder as unknown[]).map((x) => oneOf<SourceType>(x, SOURCE_TYPES)).filter((x): x is SourceType => !!x);
    if (order.length) out.sourceOrder = [...new Set(order)];
  }
  const safety = oneOf<SafetyFilter>(p.safetyMode, SAFETY);
  if (safety) out.safetyFilter = safety;
  const inst = bool(p.instantOnly);
  if (inst !== undefined) out.instantOnly = inst;
  const dead = bool(p.hideDeadTorrents);
  if (dead !== undefined) out.hideDeadTorrents = dead;
  const hdr = bool(p.hdrOnly);
  if (hdr !== undefined) out.hdrOnly = hdr;
  const av1 = bool(p.excludeAV1);
  if (av1 !== undefined) out.hideAV1 = av1;
  const exc = str(p.excludeKeywords);
  if (exc !== undefined) out.hideWords = exc;
  const inc = str(p.includeKeywords);
  if (inc !== undefined) out.requireWords = inc;
  const maxRes = num(p.maxResolution);
  if (maxRes !== undefined) {
    const cap = maxRes === 2160 ? 4000 : maxRes; // legacy 2160 -> the app's 4000 4K tag
    if (MAX_RES_VALUES.includes(cap)) out.maxQuality = cap; // ignore anything outside the legal cap set
  }
  const minRes = num(p.minResolution);
  if (minRes !== undefined && MIN_RES_VALUES.includes(minRes)) out.minQuality = minRes; // legal floors only
  const hideUnknownRes = bool(p.hideUnknownResolution);
  if (hideUnknownRes !== undefined) out.hideUnknownResolution = hideUnknownRes;
  const prefAudio = bool(p.preferredAudioOnly);
  if (prefAudio !== undefined) out.preferredAudioOnly = prefAudio;
  const maxGb = num(p.maxFileSizeGB);
  if (maxGb !== undefined) out.maxFileSizeGB = maxGb;

  return out;
}

/** WRITE-UP: merge the webapp's Settings (the keys the webapp owns) onto the main profile's EXISTING
 *  settings object, preserving keys the webapp does not model (avatar, isKids, subSize, keywordsAreRegex,
 *  etc.) so a web write never drops an app/dashboard value. Returns the new settings object to store at
 *  doc.profileEdits.roster[main].settings (dashboard-compatible shape: `accent` + nested `playback`). */
export function mergeWebappSettingsIntoProfile(existing: unknown, s: Settings): Obj {
  const base = obj(existing);
  return {
    ...base,
    // Write BOTH accent (dashboard key) and accentID (app key) to the same value so neither reader, nor
    // the webapp's own read-down (which prefers accentID), is masked by a stale value left in the base.
    accent: s.accentID,
    accentID: s.accentID,
    oled: s.background === "oled",
    textScale: s.textScale,
    playback: {
      ...obj(base.playback),
      audioLang: s.audioLang,
      subtitleLang: s.subtitleLang,
      forced: s.subtitlesMode,
      subFont: s.subtitleFont,
      subColor: s.subtitleColor,
      subBackground: s.subtitleEdge,
      subSizeScale: s.subtitleScale,
      useAddonOrder: s.useAddonOrder,
      sourceTypeOrder: s.sourceOrder,
      safetyMode: s.safetyFilter,
      instantOnly: s.instantOnly,
      hideDeadTorrents: s.hideDeadTorrents,
      hdrOnly: s.hdrOnly,
      excludeAV1: s.hideAV1,
      excludeKeywords: s.hideWords,
      includeKeywords: s.requireWords,
      // maxQuality already holds the app's Max-quality tag (4K = 4000; 1080/720/0 unchanged), so this
      // round-trips to the app's `maxResolution` (iOSSettingsView Picker .tag(4000)) without translation.
      maxResolution: s.maxQuality,
      // #117 floor/quality-filter twins, using the EXACT doc field names the app reads (Profiles.swift
      // playbackPrefs) and writes (VortXSyncManager), so a web edit round-trips to Apple devices and the
      // dashboard. minResolution encodes 4K as 2160 (the app's Minimum-quality tag), NOT 4000.
      minResolution: s.minQuality,
      hideUnknownResolution: s.hideUnknownResolution,
      preferredAudioOnly: s.preferredAudioOnly,
      maxFileSizeGB: s.maxFileSizeGB,
    },
  };
}
