import { actionOf, escapeHtml } from "../lib/dom";
import { currentSession, signOut } from "../lib/account";
import { exportBackup, importBackup } from "../lib/store";
import {
  ACCENTS,
  getSettings,
  updateSettings,
  TEXT_MIN,
  TEXT_MAX,
  TEXT_STEP,
  SUB_MIN,
  SUB_MAX,
  SUB_STEP,
  type SubtitlesMode,
} from "../lib/settings";

// The Settings screen: the web twin of the Apple Settings Form, built from grouped surface-card sections
// with an uppercased eyebrow header + an explanatory footer (mirroring iOSSettingsView). Only the knobs
// that a serverless browser client can honour are shown - appearance (accent / background / text size),
// playback language + subtitles, the account, and About. Theme + text-size apply LIVE via lib/settings.

const LANGS: { code: string; name: string }[] = [
  { code: "", name: "Default" },
  { code: "en", name: "English" },
  { code: "es", name: "Spanish" },
  { code: "fr", name: "French" },
  { code: "de", name: "German" },
  { code: "it", name: "Italian" },
  { code: "pt", name: "Portuguese" },
  { code: "ru", name: "Russian" },
  { code: "ja", name: "Japanese" },
  { code: "ko", name: "Korean" },
  { code: "zh", name: "Chinese" },
  { code: "hi", name: "Hindi" },
  { code: "ar", name: "Arabic" },
];

let host: HTMLElement | null = null;

export function renderSettings(target: HTMLElement): void {
  host = target;
  const s = getSettings();
  target.innerHTML = `
    <div class="settings-page">
      <h1 class="t-screen settings-title">Settings</h1>
      ${accountSection()}
      ${appearanceSection(s.accentID, s.background, s.textScale)}
      ${playbackSection(s.audioLang, s.subtitleLang, s.subtitlesMode, s.autoplayTrailers)}
      ${subtitleStyleSection(s.subtitleScale, s.subtitleBackground)}
      ${ratingsSection(s.mdblistKey)}
      ${backupSection()}
      ${aboutSection()}
    </div>`;
  wireSettings(target);
}

function group(eyebrow: string, body: string, footer?: string): string {
  return `
    <section class="settings-section">
      <span class="settings-eyebrow t-eyebrow">${eyebrow}</span>
      <div class="surface-card settings-card">${body}</div>
      ${footer ? `<p class="settings-footer">${footer}</p>` : ""}
    </section>`;
}

function row(label: string, control: string, sub?: string): string {
  return `
    <div class="settings-row">
      <div class="settings-row-label">
        <span>${label}</span>
        ${sub ? `<span class="settings-row-sub">${sub}</span>` : ""}
      </div>
      <div class="settings-row-control">${control}</div>
    </div>`;
}

function accountSection(): string {
  const acct = currentSession()?.account;
  if (acct) {
    const who = escapeHtml(acct.username || acct.email || "Signed in");
    const sub = acct.email && acct.username ? escapeHtml(acct.email) : undefined;
    const body = row(who, `<button class="chip" data-action="account-signout">Sign out</button>`, sub);
    return group("Account", body, "Your library, add-ons, and settings sync across every VortX device, end to end encrypted.");
  }
  const body = `<a class="btn-primary settings-signin" href="#/login">Sign in to VortX</a>`;
  return group(
    "Account",
    body,
    "Sign in to sync your library, add-ons, and settings across every VortX device (end to end encrypted). You can keep using the web app signed out, stored only on this device.",
  );
}

function appearanceSection(accentID: string, background: string, textScale: number): string {
  const swatches = ACCENTS.map(
    (a) =>
      `<button class="swatch${a.id === accentID ? " selected" : ""}" style="--sw:${a.base}" data-action="set-accent" data-accent="${a.id}" title="${a.label}" aria-label="${a.label}"></button>`,
  ).join("");
  const bg = segmented([
    { value: "warm", label: "Warm", on: background === "warm" },
    { value: "oled", label: "OLED Black", on: background === "oled" },
  ], "set-bg", "bg");
  const pct = Math.round(textScale * 100);
  const stepper = `
    <div class="stepper">
      <button class="stepper-btn" data-action="text-size" data-dir="-1" ${textScale <= TEXT_MIN + 0.001 ? "disabled" : ""} aria-label="Smaller text">-</button>
      <span class="stepper-value">${pct}%</span>
      <button class="stepper-btn" data-action="text-size" data-dir="1" ${textScale >= TEXT_MAX - 0.001 ? "disabled" : ""} aria-label="Larger text">+</button>
    </div>`;
  const body =
    row("Accent", `<div class="swatches">${swatches}</div>`) +
    row("Background", bg) +
    row("App text size", stepper);
  return group("Appearance", body, "Accent, background, and text size apply across the whole app instantly.");
}

function playbackSection(audioLang: string, subtitleLang: string, mode: SubtitlesMode, autoplay: boolean): string {
  const audio = langSelect("audio-lang", audioLang, "Original");
  const subs = langSelect("subtitle-lang", subtitleLang, "None");
  const subMode = segmented([
    { value: "off", label: "Off", on: mode === "off" },
    { value: "on", label: "On", on: mode === "on" },
    { value: "forced", label: "Forced", on: mode === "forced" },
  ], "subtitles-mode", "mode");
  const trailers = toggle("toggle-autoplay", autoplay);
  const body =
    row("Audio language", audio) +
    row("Subtitle language", subs) +
    row("Subtitles", subMode) +
    row("Autoplay trailers", trailers, "Play a muted preview on the featured hero");
  return group("Playback & Subtitles", body, "Preferred languages are requested when a source offers multiple tracks.");
}

function ratingsSection(mdblistKey: string): string {
  const input = `<input class="field settings-key" type="text" id="mdblist-key" data-key-input="mdblist"
    placeholder="MDBList API key" value="${escapeHtml(mdblistKey)}" autocomplete="off" spellcheck="false" aria-label="MDBList API key" />`;
  return group(
    "Ratings",
    row("MDBList key", input),
    `Add a free key from mdblist.com to show IMDb, Rotten Tomatoes, and TMDB ratings on detail pages.`,
  );
}

function subtitleStyleSection(scale: number, background: boolean): string {
  const pct = Math.round(scale * 100);
  const stepper = `
    <div class="stepper">
      <button class="stepper-btn" data-action="sub-size" data-dir="-1" ${scale <= SUB_MIN + 0.001 ? "disabled" : ""} aria-label="Smaller subtitles">-</button>
      <span class="stepper-value">${pct}%</span>
      <button class="stepper-btn" data-action="sub-size" data-dir="1" ${scale >= SUB_MAX - 0.001 ? "disabled" : ""} aria-label="Larger subtitles">+</button>
    </div>`;
  const body =
    row("Subtitle size", stepper) +
    row("Background", toggle("toggle-sub-bg", background), "A translucent backing behind subtitle text");
  return group("Subtitle Style", body, "Applies to the player's subtitle track.");
}

function backupSection(): string {
  const body = `
    <div class="settings-actions">
      <button class="chip" data-action="export-backup">Export backup</button>
      <label class="chip backup-import" role="button">Import backup<input type="file" accept="application/json,.json" data-import-backup hidden /></label>
    </div>`;
  return group(
    "Backup & Restore",
    body,
    "Export your add-ons, library, continue-watching, and settings to a file, or restore from one. Signed in, these also sync across your devices.",
  );
}

function aboutSection(): string {
  const body =
    row("Version", `<span class="settings-row-sub">VortX for Web · 0.1</span>`) +
    row("Website", `<a class="inline-link" href="https://vortx.tv" target="_blank" rel="noopener">vortx.tv</a>`);
  return group("About", body);
}

// ---- Controls -----------------------------------------------------------------------------------

function segmented(opts: { value: string; label: string; on: boolean }[], action: string, dataKey: string): string {
  const items = opts
    .map(
      (o) =>
        `<button class="seg${o.on ? " selected" : ""}" data-action="${action}" data-${dataKey}="${o.value}">${o.label}</button>`,
    )
    .join("");
  return `<div class="segmented" role="group">${items}</div>`;
}

function toggle(action: string, on: boolean): string {
  return `<button class="switch${on ? " on" : ""}" role="switch" aria-checked="${on}" data-action="${action}"><span class="switch-knob"></span></button>`;
}

function langSelect(id: string, value: string, defaultLabel: string): string {
  const opts = LANGS.map((l) => {
    const label = l.code === "" ? defaultLabel : l.name;
    return `<option value="${l.code}"${l.code === value ? " selected" : ""}>${label}</option>`;
  }).join("");
  return `<select class="settings-select" id="${id}" data-select="${id}">${opts}</select>`;
}

// ---- Interaction --------------------------------------------------------------------------------

/** Click handler for the settings controls (buttons). Returns true if it consumed the event. */
export function handleSettingsClick(target: EventTarget | null): boolean {
  const hit = actionOf(target);
  if (!hit) return false;
  switch (hit.action) {
    case "set-accent":
      updateSettings({ accentID: hit.node.dataset.accent ?? "vortx" });
      rerender();
      return true;
    case "set-bg":
      updateSettings({ background: hit.node.dataset.bg === "oled" ? "oled" : "warm" });
      rerender();
      return true;
    case "text-size": {
      const dir = Number(hit.node.dataset.dir) || 0;
      const next = clampScale(getSettings().textScale + dir * TEXT_STEP);
      updateSettings({ textScale: next });
      rerender();
      return true;
    }
    case "subtitles-mode":
      updateSettings({ subtitlesMode: (hit.node.dataset.mode as SubtitlesMode) ?? "on" });
      rerender();
      return true;
    case "toggle-autoplay":
      updateSettings({ autoplayTrailers: !getSettings().autoplayTrailers });
      rerender();
      return true;
    case "account-signout":
      signOut();
      rerender();
      return true;
    case "sub-size": {
      const dir = Number(hit.node.dataset.dir) || 0;
      const next = clampSub(getSettings().subtitleScale + dir * SUB_STEP);
      updateSettings({ subtitleScale: next });
      rerender();
      return true;
    }
    case "toggle-sub-bg":
      updateSettings({ subtitleBackground: !getSettings().subtitleBackground });
      rerender();
      return true;
    case "export-backup":
      downloadBackup();
      return true;
    default:
      return false;
  }
}

/** Download the local data as a JSON file (Backup). */
function downloadBackup(): void {
  const blob = new Blob([exportBackup()], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "vortx-backup.json";
  a.click();
  URL.revokeObjectURL(url);
}

/** Attach change listeners for the native <select> controls (language pickers) + the MDBList key input. */
function wireSettings(target: HTMLElement): void {
  target.querySelectorAll<HTMLSelectElement>("select[data-select]").forEach((sel) => {
    sel.addEventListener("change", () => {
      if (sel.dataset.select === "audio-lang") updateSettings({ audioLang: sel.value });
      else if (sel.dataset.select === "subtitle-lang") updateSettings({ subtitleLang: sel.value });
    });
  });
  const keyInput = target.querySelector<HTMLInputElement>('input[data-key-input="mdblist"]');
  keyInput?.addEventListener("change", () => updateSettings({ mdblistKey: keyInput.value.trim() }));

  const importInput = target.querySelector<HTMLInputElement>("input[data-import-backup]");
  importInput?.addEventListener("change", () => {
    const file = importInput.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      if (importBackup(String(reader.result))) location.reload();
      else flashImportError(importInput);
    };
    reader.readAsText(file);
  });
}

/** Inline "Invalid backup file" feedback on the Import control (no window.alert). */
function flashImportError(input: HTMLInputElement): void {
  const label = input.closest<HTMLElement>(".backup-import");
  if (!label) return;
  const prev = label.firstChild?.textContent ?? "Import backup";
  if (label.firstChild) label.firstChild.textContent = "Invalid backup file";
  input.value = "";
  setTimeout(() => {
    if (label.firstChild) label.firstChild.textContent = prev;
  }, 2000);
}

function rerender(): void {
  if (host) renderSettings(host);
}

function clampScale(v: number): number {
  return Math.min(TEXT_MAX, Math.max(TEXT_MIN, Math.round(v / TEXT_STEP) * TEXT_STEP));
}

function clampSub(v: number): number {
  return Math.min(SUB_MAX, Math.max(SUB_MIN, Math.round(v / SUB_STEP) * SUB_STEP));
}
