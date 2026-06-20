// App settings: the web twin of the Apple app's Settings (Theme.swift / ThemeManager). The webapp ships
// the SAME knobs every platform has, scoped to what a serverless browser client can honour: appearance
// (accent theme, warm/OLED background, app text size) and playback language/subtitles. Persisted locally
// (localStorage) and APPLIED LIVE by overriding the CSS custom properties the whole UI already consumes
// (the :root gold theme in app.css is just the default; every control reads var(--accent*) / var(--bg) /
// surfaces, so writing overrides onto documentElement re-themes everything for free).

export type Background = "warm" | "oled";
export type SubtitlesMode = "off" | "on" | "forced";
export type SafetyFilter = "off" | "moderate" | "strict";
export type Performance = "auto" | "full" | "reduced";
export type SubtitleFont = "modern" | "classic" | "mono";
export type SubtitleColor = "white" | "yellow" | "cyan" | "mint";
export type SubtitleEdge = "outline" | "shadow" | "box" | "none";
export type SourceType = "debrid" | "usenet" | "torrent" | "direct";

export interface Settings {
  accentID: string;
  background: Background;
  textScale: number; // 0.80 - 1.40, matching ThemeManager.textScale
  audioLang: string; // ISO 639-1, "" = default
  subtitleLang: string; // ISO 639-1, "" = none
  subtitlesMode: SubtitlesMode;
  autoplayTrailers: boolean;
  mdblistKey: string; // optional MDBList API key for IMDb/RT/TMDB ratings on the detail page
  subtitleScale: number; // 0.7 - 1.8, scales the player's subtitle text (video::cue)
  subtitleBackground: boolean; // legacy translucent-backing flag; superseded by subtitleEdge (kept for migration)
  preferredQuality: number; // auto-pick resolution cap in p (2160/1080/720/480); 0 = Auto (absolute best)

  // ---- Parity with the Apple Settings (the owner's "same settings on every platform" rule) ----
  // Account / Metadata
  tmdbKey: string; // optional TMDB v4 key for richer metadata (twin of the app's Metadata row)
  // Playback
  directLinksOnly: boolean; // hide torrent/magnet sources; only direct + debrid links play
  skipStep: number; // player skip granularity in seconds (10 | 15 | 30)
  // Notifications
  episodeAlerts: boolean; // browser notification when a new episode of an opened series is about to air
  // Streams (filter + ranking, the web twin of iOSSettingsView's Streams group)
  useAddonOrder: boolean; // keep the add-on's own order instead of VortX's ranking
  sourceOrder: SourceType[]; // source-type priority, highest first
  safetyFilter: SafetyFilter; // hide CAM / fake-quality sources
  hideWords: string; // comma-separated words; a source whose label contains any is hidden
  requireWords: string; // comma-separated words; a source must contain all to be shown
  instantOnly: boolean; // only cached / instantly-playable sources
  hideDeadTorrents: boolean; // hide torrent sources with no seeders (limited effect on web)
  hdrOnly: boolean; // only HDR / Dolby Vision sources
  hideAV1: boolean; // hide AV1-encoded sources
  maxQuality: number; // resolution cap in p that FILTERS the source list (0 = unlimited)
  maxFileSizeGB: number; // file-size cap in GB that filters the list (0 = unlimited)
  // Appearance
  performance: Performance; // 'reduced' trims animations app-wide (a11y / low-power)
  // Subtitle Style
  subtitleFont: SubtitleFont;
  subtitleColor: SubtitleColor;
  subtitleEdge: SubtitleEdge; // outline / drop-shadow / box / none (the app's "Background" subtitle row)
}

/** The accent palette, ported 1:1 from ThemeManager.accents (the app's source of truth). base/bright are
 *  the fill + hover/glow; onAccent is the ink drawn ON the fill (per ThemeManager.onAccent). */
export interface Accent {
  id: string;
  label: string;
  base: string;
  bright: string;
  onAccent: string;
}

export const ACCENTS: Accent[] = [
  { id: "vortx", label: "VortX", base: "#d97706", bright: "#f59e0b", onAccent: "#0f0d0a" },
  { id: "ember", label: "Ember", base: "#f2784b", bright: "#ff9163", onAccent: "#1b110b" },
  { id: "ocean", label: "Ocean", base: "#4c90e2", bright: "#6fb0fb", onAccent: "#1a1a1c" },
  { id: "forest", label: "Forest", base: "#60b471", bright: "#7ad48d", onAccent: "#1a1a1c" },
  { id: "royal", label: "Royal", base: "#9473e6", bright: "#b18ffb", onAccent: "#1a1a1c" },
  { id: "crimson", label: "Crimson", base: "#e24f5b", bright: "#fb6b76", onAccent: "#f7f7f5" },
  { id: "gold", label: "Gold", base: "#e2b44a", bright: "#facd66", onAccent: "#1a1a1c" },
  { id: "rose", label: "Rose", base: "#ed739e", bright: "#ff8fb5", onAccent: "#1a1a1c" },
  { id: "mono", label: "Mono", base: "#d1ccc2", bright: "#ebe8e1", onAccent: "#1a1a1c" },
];

/** OLED background overrides (ThemeManager oled branch): true black canvas + neutral surfaces. */
const OLED = { bg: "#000000", surface1: "#0e0e0f", surface2: "#181819", surface3: "#242426", hairline: "#323234" };

/** Subtitle color presets (the app's Subtitle Style "Color" row). */
export const SUB_COLORS: Record<SubtitleColor, string> = {
  white: "#ffffff",
  yellow: "#f5d061",
  cyan: "#7fdbff",
  mint: "#8ce0b0",
};

/** Subtitle font presets - the app's "Modern / Classic / Mono" choices map to web font stacks. */
export const SUB_FONTS: Record<SubtitleFont, string> = {
  modern: "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
  classic: "'Times New Roman', Georgia, serif",
  mono: "'SF Mono', 'Roboto Mono', ui-monospace, monospace",
};

export const TEXT_MIN = 0.8;
export const TEXT_MAX = 1.4;
export const TEXT_STEP = 0.05;

const KEY = "vortx.web.settings.v1";

const DEFAULTS: Settings = {
  accentID: "vortx",
  background: "warm",
  textScale: 1,
  audioLang: "",
  subtitleLang: "",
  subtitlesMode: "on",
  autoplayTrailers: true,
  mdblistKey: "",
  subtitleScale: 1,
  subtitleBackground: true,
  preferredQuality: 0,
  tmdbKey: "",
  directLinksOnly: false,
  skipStep: 10,
  episodeAlerts: false,
  useAddonOrder: false,
  sourceOrder: ["debrid", "usenet", "torrent", "direct"],
  safetyFilter: "off",
  hideWords: "",
  requireWords: "",
  instantOnly: false,
  hideDeadTorrents: false,
  hdrOnly: false,
  hideAV1: false,
  maxQuality: 0,
  maxFileSizeGB: 0,
  performance: "auto",
  subtitleFont: "modern",
  subtitleColor: "white",
  subtitleEdge: "outline",
};

export const SUB_MIN = 0.7;
export const SUB_MAX = 1.8;
export const SUB_STEP = 0.1;

let cache: Settings | null = null;
const listeners = new Set<(s: Settings) => void>();

/** Read the persisted settings, merged over defaults (tolerant of corrupt / partial JSON). */
export function getSettings(): Settings {
  if (cache) return cache;
  try {
    const raw = localStorage.getItem(KEY);
    cache = raw ? { ...DEFAULTS, ...(JSON.parse(raw) as Partial<Settings>) } : { ...DEFAULTS };
  } catch {
    cache = { ...DEFAULTS };
  }
  return cache;
}

/** Patch + persist + apply + notify. Returns the new settings. */
export function updateSettings(patch: Partial<Settings>): Settings {
  const next = { ...getSettings(), ...patch };
  cache = next;
  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    // private mode / quota - keep the in-memory value so the UI still reflects the change this session.
  }
  applySettings(next);
  listeners.forEach((fn) => fn(next));
  return next;
}

export function onSettingsChange(fn: (s: Settings) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function accentById(id: string): Accent {
  return ACCENTS.find((a) => a.id === id) ?? ACCENTS[0];
}

/** Apply settings to the document by overriding the CSS variables app.css already cascades from. Called
 *  once on boot and on every change, so theme + text size take effect live with no reload. */
export function applySettings(s: Settings = getSettings()): void {
  const root = document.documentElement;
  const accent = accentById(s.accentID);
  root.style.setProperty("--accent", accent.base);
  root.style.setProperty("--accent-bright", accent.bright);
  root.style.setProperty("--accent-soft", hexToRgba(accent.base, 0.18));
  root.style.setProperty("--on-accent", accent.onAccent);
  root.style.setProperty("--glow-accent", `0 0 18px ${hexToRgba(accent.base, 0.6)}`);

  if (s.background === "oled") {
    root.style.setProperty("--bg", OLED.bg);
    root.style.setProperty("--surface", OLED.surface1);
    root.style.setProperty("--surface-2", OLED.surface2);
    root.style.setProperty("--surface-3", OLED.surface3);
    root.style.setProperty("--hairline", OLED.hairline);
  } else {
    // Warm: revert to the :root defaults.
    for (const v of ["--bg", "--surface", "--surface-2", "--surface-3", "--hairline"]) root.style.removeProperty(v);
  }

  // App text size: a unitless multiplier on the responsive root font-size (app.css html calc), so rem/em
  // UI text follows both the viewport and the preference (ThemeManager.textScale twin).
  if (Math.abs(s.textScale - 1) < 0.001) root.style.removeProperty("--text-scale");
  else root.style.setProperty("--text-scale", String(s.textScale));

  // Performance: 'reduced' trims animations app-wide (the app's Performance row; also an a11y win). CSS
  // keys off [data-perf="reduced"] to near-zero all transition/animation durations.
  root.dataset.perf = s.performance === "reduced" ? "reduced" : "full";

  // Subtitle style: the player's native <track> cues read these via `video::cue` (see app.css).
  root.style.setProperty("--sub-scale", String(s.subtitleScale));
  root.style.setProperty("--sub-color", SUB_COLORS[s.subtitleColor] ?? SUB_COLORS.white);
  root.style.setProperty("--sub-font", SUB_FONTS[s.subtitleFont] ?? SUB_FONTS.modern);
  applySubtitleEdge(root, s.subtitleEdge);
}

/** Map the subtitle "Background" choice to the cue backing + text edge (`video::cue` reads both vars). */
function applySubtitleEdge(root: HTMLElement, edge: SubtitleEdge): void {
  const outline =
    "-1px -1px 0 #000, 1px -1px 0 #000, -1px 1px 0 #000, 1px 1px 0 #000, 0 0 4px rgba(0,0,0,0.9)";
  switch (edge) {
    case "box":
      root.style.setProperty("--sub-bg", "rgba(0, 0, 0, 0.75)");
      root.style.setProperty("--sub-shadow", "none");
      break;
    case "shadow":
      root.style.setProperty("--sub-bg", "transparent");
      root.style.setProperty("--sub-shadow", "2px 2px 4px rgba(0,0,0,0.95)");
      break;
    case "none":
      root.style.setProperty("--sub-bg", "transparent");
      root.style.setProperty("--sub-shadow", "none");
      break;
    case "outline":
    default:
      root.style.setProperty("--sub-bg", "transparent");
      root.style.setProperty("--sub-shadow", outline);
      break;
  }
}

/** "#rrggbb" + alpha -> "rgba(r,g,b,a)" for the soft/glow tints. */
function hexToRgba(hex: string, alpha: number): string {
  const h = hex.replace("#", "");
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
