// App settings: the web twin of the Apple app's Settings (Theme.swift / ThemeManager). The webapp ships
// the SAME knobs every platform has, scoped to what a serverless browser client can honour: appearance
// (accent theme, warm/OLED background, app text size) and playback language/subtitles. Persisted locally
// (localStorage) and APPLIED LIVE by overriding the CSS custom properties the whole UI already consumes
// (the :root gold theme in app.css is just the default; every control reads var(--accent*) / var(--bg) /
// surfaces, so writing overrides onto documentElement re-themes everything for free).

export type Background = "warm" | "oled";
export type SubtitlesMode = "off" | "on" | "forced";

export interface Settings {
  accentID: string;
  background: Background;
  textScale: number; // 0.80 - 1.40, matching ThemeManager.textScale
  audioLang: string; // ISO 639-1, "" = default
  subtitleLang: string; // ISO 639-1, "" = none
  subtitlesMode: SubtitlesMode;
  autoplayTrailers: boolean;
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
};

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

  // App text size: scale the root font so rem/em-based UI text follows (ThemeManager.textScale twin).
  if (Math.abs(s.textScale - 1) < 0.001) root.style.removeProperty("font-size");
  else root.style.setProperty("font-size", `${Math.round(16 * s.textScale)}px`);
}

/** "#rrggbb" + alpha -> "rgba(r,g,b,a)" for the soft/glow tints. */
function hexToRgba(hex: string, alpha: number): string {
  const h = hex.replace("#", "");
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
