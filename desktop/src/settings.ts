// Desktop Settings: Appearance (accent / background / app text size) applied LIVE by overriding the CSS
// custom properties the whole UI reads (same model as the webapp + ThemeManager). Persisted locally.
// Engine-independent, so this screen is browser-verifiable. (Playback/Subtitles/Account come later.)

export interface Settings {
  accentID: string;
  background: "warm" | "oled";
  textScale: number;
}

export interface Accent {
  id: string;
  label: string;
  base: string;
  bright: string;
  onAccent: string;
}

// Ported 1:1 from ThemeManager.accents (the app's source of truth), same as the webapp.
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

const OLED = { bg: "#000000", s1: "#0e0e0f", s2: "#181819", s3: "#242426", hairline: "#323234" };

export const TEXT_MIN = 0.8;
export const TEXT_MAX = 1.4;
export const TEXT_STEP = 0.05;

const KEY = "vortx.desktop.settings.v1";
const DEFAULTS: Settings = { accentID: "vortx", background: "warm", textScale: 1 };

let cache: Settings | null = null;

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

export function updateSettings(patch: Partial<Settings>): Settings {
  const next = { ...getSettings(), ...patch };
  cache = next;
  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    // private mode / quota - keep the in-memory value
  }
  applySettings(next);
  return next;
}

function accentById(id: string): Accent {
  return ACCENTS.find((a) => a.id === id) ?? ACCENTS[0];
}

/** Apply settings to the document by overriding the CSS variables styles.css cascades from. */
export function applySettings(s: Settings = getSettings()): void {
  const root = document.documentElement;
  const a = accentById(s.accentID);
  root.style.setProperty("--accent", a.base);
  root.style.setProperty("--accent-bright", a.bright);
  root.style.setProperty("--accent-soft", hexToRgba(a.base, 0.18));
  root.style.setProperty("--on-accent", a.onAccent);
  root.style.setProperty("--glow-accent", `0 0 18px ${hexToRgba(a.base, 0.6)}`);
  if (s.background === "oled") {
    root.style.setProperty("--bg", OLED.bg);
    root.style.setProperty("--surface", OLED.s1);
    root.style.setProperty("--surface-2", OLED.s2);
    root.style.setProperty("--surface-3", OLED.s3);
    root.style.setProperty("--hairline", OLED.hairline);
  } else {
    for (const v of ["--bg", "--surface", "--surface-2", "--surface-3", "--hairline"]) root.style.removeProperty(v);
  }
  if (Math.abs(s.textScale - 1) < 0.001) root.style.removeProperty("font-size");
  else root.style.setProperty("font-size", `${Math.round(16 * s.textScale)}px`);
}

function hexToRgba(hex: string, alpha: number): string {
  const h = hex.replace("#", "");
  return `rgba(${parseInt(h.slice(0, 2), 16)}, ${parseInt(h.slice(2, 4), 16)}, ${parseInt(h.slice(4, 6), 16)}, ${alpha})`;
}

function esc(v: string): string {
  return v.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

// ---- View -----------------------------------------------------------------

let host: HTMLElement | null = null;

export function renderSettings(target: HTMLElement): void {
  host = target;
  const s = getSettings();
  const swatches = ACCENTS.map(
    (a) =>
      `<button class="swatch${a.id === s.accentID ? " selected" : ""}" style="--sw:${a.base}" data-action="set-accent" data-accent="${a.id}" title="${a.label}" aria-label="${a.label}"></button>`,
  ).join("");
  const bg = `
    <div class="segmented">
      <button class="seg${s.background === "warm" ? " selected" : ""}" data-action="set-bg" data-bg="warm">Warm</button>
      <button class="seg${s.background === "oled" ? " selected" : ""}" data-action="set-bg" data-bg="oled">OLED Black</button>
    </div>`;
  const pct = Math.round(s.textScale * 100);
  const stepper = `
    <div class="stepper">
      <button class="stepper-btn" data-action="text-size" data-dir="-1" ${s.textScale <= TEXT_MIN + 0.001 ? "disabled" : ""}>-</button>
      <span class="stepper-value">${pct}%</span>
      <button class="stepper-btn" data-action="text-size" data-dir="1" ${s.textScale >= TEXT_MAX - 0.001 ? "disabled" : ""}>+</button>
    </div>`;
  target.innerHTML = `
    <div class="settings-page">
      <h1 class="settings-title">Settings</h1>
      <section class="settings-section">
        <span class="settings-eyebrow">Appearance</span>
        <div class="settings-card">
          <div class="settings-row"><span>Accent</span><div class="swatches">${swatches}</div></div>
          <div class="settings-row"><span>Background</span>${bg}</div>
          <div class="settings-row"><span>App text size</span>${stepper}</div>
        </div>
        <p class="settings-footer">Accent, background, and text size apply across the whole app instantly.</p>
      </section>
      <section class="settings-section">
        <span class="settings-eyebrow">About</span>
        <div class="settings-card">
          <div class="settings-row"><span>Version</span><span class="settings-sub">VortX for Desktop</span></div>
          <div class="settings-row"><span>Website</span><a class="inline-link" href="https://vortx.tv" target="_blank" rel="noopener">vortx.tv</a></div>
        </div>
      </section>
    </div>`;
}

/** Handle a settings control click. Returns true if it consumed the event (caller re-renders). */
export function handleSettingsClick(target: HTMLElement): boolean {
  const node = target.closest<HTMLElement>("[data-action]");
  const action = node?.dataset.action;
  if (!action) return false;
  if (action === "set-accent") {
    updateSettings({ accentID: node?.dataset.accent ?? "vortx" });
  } else if (action === "set-bg") {
    updateSettings({ background: node?.dataset.bg === "oled" ? "oled" : "warm" });
  } else if (action === "text-size") {
    const dir = Number(node?.dataset.dir) || 0;
    const next = Math.min(TEXT_MAX, Math.max(TEXT_MIN, Math.round((getSettings().textScale + dir * TEXT_STEP) / TEXT_STEP) * TEXT_STEP));
    updateSettings({ textScale: next });
  } else {
    return false;
  }
  if (host) renderSettings(host);
  return true;
}

// esc kept for any future dynamic strings in the view.
void esc;
