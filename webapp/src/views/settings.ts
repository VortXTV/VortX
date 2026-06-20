import { actionOf, escapeHtml } from "../lib/dom";
import { currentSession, signOut } from "../lib/account";
import { exportBackup, importBackup } from "../lib/store";
import {
  ACCENTS,
  SUB_COLORS,
  getSettings,
  updateSettings,
  TEXT_MIN,
  TEXT_MAX,
  TEXT_STEP,
  SUB_MIN,
  SUB_MAX,
  SUB_STEP,
  type Settings,
  type SubtitlesMode,
  type SafetyFilter,
  type Performance,
  type SubtitleFont,
  type SubtitleColor,
  type SubtitleEdge,
  type SourceType,
} from "../lib/settings";

// The Settings screen: the web twin of the Apple Settings Form, built section-for-section to match the
// app (Account, Metadata, Playback, Notifications, Streams, Appearance, Audio & Subtitles, Subtitle
// Style, Backup, About). The four app sections a serverless browser tab cannot honour - Streaming Server,
// Advanced (mpv) options, audio-output device routing, Dolby-Vision/HDR tone-map - and Profiles (a
// separate subsystem) are intentionally omitted. Theme, text size, performance, and subtitle style apply
// LIVE via lib/settings (CSS-variable overrides); the Streams knobs feed lib/streamRanking's filters.

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

const SKIP_STEPS = [10, 15, 30];
const MAX_QUALITY_OPTS: { v: number; l: string }[] = [
  { v: 0, l: "Unlimited" },
  { v: 2160, l: "4K" },
  { v: 1080, l: "1080p" },
  { v: 720, l: "720p" },
];
const MAX_SIZE_OPTS: { v: number; l: string }[] = [
  { v: 0, l: "Unlimited" },
  { v: 5, l: "5 GB" },
  { v: 15, l: "15 GB" },
  { v: 40, l: "40 GB" },
];
const SUB_SIZES: { v: number; l: string }[] = [
  { v: 0.85, l: "Small" },
  { v: 1.0, l: "Medium" },
  { v: 1.25, l: "Large" },
  { v: 1.5, l: "Huge" },
];
const SOURCE_LABELS: Record<SourceType, { name: string; sub: string }> = {
  debrid: { name: "Debrid", sub: "Real-Debrid, AllDebrid, Premiumize, TorBox" },
  usenet: { name: "Usenet", sub: "NZB / Usenet sources" },
  torrent: { name: "Torrent", sub: "BitTorrent info-hash streams" },
  direct: { name: "Direct", sub: "Plain HTTP/HTTPS streams from add-ons" },
};

let host: HTMLElement | null = null;

export function renderSettings(target: HTMLElement): void {
  host = target;
  const s = getSettings();
  target.innerHTML = `
    <div class="settings-page">
      <h1 class="t-screen settings-title">Settings</h1>
      ${accountSection()}
      ${metadataSection(s.mdblistKey, s.tmdbKey)}
      ${playbackSection(s.directLinksOnly, s.skipStep, s.preferredQuality, s.autoplayTrailers)}
      ${notificationsSection(s.episodeAlerts)}
      ${streamsSection(s)}
      ${appearanceSection(s.accentID, s.background, s.textScale, s.performance)}
      ${audioSubtitlesSection(s.audioLang, s.subtitleLang, s.subtitlesMode)}
      ${subtitleStyleSection(s.subtitleScale, s.subtitleFont, s.subtitleColor, s.subtitleEdge)}
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

function metadataSection(mdblistKey: string, tmdbKey: string): string {
  const body =
    row("MDBList key", secretField("mdblist-key", "mdblist", mdblistKey, "MDBList API key")) +
    row("TMDB key", secretField("tmdb-key", "tmdb", tmdbKey, "TMDB v4 read access token"));
  return group(
    "Metadata",
    body,
    "Add a free MDBList key (mdblist.com) for IMDb, Rotten Tomatoes, and TMDB ratings on detail pages. A TMDB key enriches posters and descriptions.",
  );
}

function playbackSection(
  directLinksOnly: boolean,
  skipStep: number,
  preferredQuality: number,
  autoplay: boolean,
): string {
  const quality = segmented(
    [
      { value: "0", label: "Auto", on: preferredQuality === 0 },
      { value: "2160", label: "4K", on: preferredQuality === 2160 },
      { value: "1080", label: "1080p", on: preferredQuality === 1080 },
      { value: "720", label: "720p", on: preferredQuality === 720 },
      { value: "480", label: "480p", on: preferredQuality === 480 },
    ],
    "set-quality",
    "q",
  );
  const skip = segmented(
    SKIP_STEPS.map((n) => ({ value: String(n), label: `${n}s`, on: skipStep === n })),
    "set-skip",
    "skip",
  );
  const body =
    row("Direct links only", toggle("toggle-direct", directLinksOnly), "Hide torrent and magnet sources; only direct and debrid links play") +
    row("Preferred quality", quality, "Auto-play the best source at or under this resolution") +
    row("Skip step", skip, "How far the player skip controls jump") +
    row("Autoplay trailers", toggle("toggle-autoplay", autoplay), "Play a muted preview on the featured hero");
  return group("Playback", body);
}

function notificationsSection(episodeAlerts: boolean): string {
  return group(
    "Notifications",
    row("New episode alerts", toggle("toggle-alerts", episodeAlerts)),
    "Get a browser notification when a new episode of a series you opened is about to air. Your browser will ask for notification permission the first time you turn this on.",
  );
}

/** One-tap quality presets: each bundles several Streams knobs. "Custom" = none match exactly. */
const QUALITY_PRESETS: Record<"best" | "balanced" | "fast", Partial<Settings>> = {
  best: { preferredQuality: 0, maxQuality: 0, maxFileSizeGB: 0, instantOnly: false, hideDeadTorrents: true, safetyFilter: "moderate" },
  balanced: { preferredQuality: 1080, maxQuality: 1080, maxFileSizeGB: 15, instantOnly: false, hideDeadTorrents: true, safetyFilter: "moderate" },
  fast: { preferredQuality: 720, maxQuality: 720, maxFileSizeGB: 5, instantOnly: true, hideDeadTorrents: true, safetyFilter: "moderate" },
};

/** Which quality preset the current settings exactly match, or null (Custom). */
function presetOf(s: Settings): keyof typeof QUALITY_PRESETS | null {
  for (const [name, p] of Object.entries(QUALITY_PRESETS) as [keyof typeof QUALITY_PRESETS, Partial<Settings>][]) {
    if ((Object.keys(p) as (keyof Settings)[]).every((k) => s[k] === p[k])) return name;
  }
  return null;
}

function streamsSection(s: Settings): string {
  const preset = presetOf(s);
  const presetSeg = segmented(
    [
      { value: "best", label: "Best", on: preset === "best" },
      { value: "balanced", label: "Balanced", on: preset === "balanced" },
      { value: "fast", label: "Fast", on: preset === "fast" },
    ],
    "set-preset",
    "preset",
  );
  const safety = segmented(
    [
      { value: "off", label: "Off", on: s.safetyFilter === "off" },
      { value: "moderate", label: "Moderate", on: s.safetyFilter === "moderate" },
      { value: "strict", label: "Strict", on: s.safetyFilter === "strict" },
    ],
    "set-safety",
    "safety",
  );
  const maxQ = segmented(
    MAX_QUALITY_OPTS.map((o) => ({ value: String(o.v), label: o.l, on: s.maxQuality === o.v })),
    "set-maxq",
    "mq",
  );
  const maxS = segmented(
    MAX_SIZE_OPTS.map((o) => ({ value: String(o.v), label: o.l, on: s.maxFileSizeGB === o.v })),
    "set-maxsize",
    "ms",
  );
  const body =
    row("Quality preset", presetSeg, preset === null ? "Custom" : undefined) +
    row("Use add-on ranking order", toggle("toggle-addon-order", s.useAddonOrder)) +
    reorderList(s.sourceOrder) +
    row("Safety filter", safety) +
    row("Hide words", textField("hide-words", "hide", s.hideWords, "cam, ts, hdcam")) +
    row("Require words", textField("require-words", "require", s.requireWords, "remux, 2160p")) +
    row("Instant sources only", toggle("toggle-instant", s.instantOnly)) +
    row("Hide dead torrents", toggle("toggle-dead", s.hideDeadTorrents)) +
    row("HDR sources only", toggle("toggle-hdr", s.hdrOnly)) +
    row("Hide AV1 sources", toggle("toggle-av1", s.hideAV1)) +
    row("Max quality", maxQ) +
    row("Max file size", maxS);
  return group(
    "Streams",
    body,
    "When add-on ranking order is off, VortX ranks sources by quality. Filters apply to every source list. Source priority and torrent / Usenet filters carry over to your other VortX devices; torrents are shown here but cannot play in the browser.",
  );
}

function appearanceSection(accentID: string, background: string, textScale: number, performance: Performance): string {
  const swatches = ACCENTS.map(
    (a) =>
      `<button class="swatch${a.id === accentID ? " selected" : ""}" style="--sw:${a.base}" data-action="set-accent" data-accent="${a.id}" title="${a.label}" aria-label="${a.label}"></button>`,
  ).join("");
  const bg = segmented([
    { value: "warm", label: "Warm", on: background === "warm" },
    { value: "oled", label: "OLED Black", on: background === "oled" },
  ], "set-bg", "bg");
  const perf = segmented(
    [
      { value: "auto", label: "Auto", on: performance === "auto" },
      { value: "full", label: "Full", on: performance === "full" },
      { value: "reduced", label: "Reduced", on: performance === "reduced" },
    ],
    "set-perf",
    "perf",
  );
  const body =
    row("Accent", `<div class="swatches">${swatches}</div>`) +
    row("Background", bg) +
    row("App text size", stepper("text-size", Math.round(textScale * 100), textScale <= TEXT_MIN + 0.001, textScale >= TEXT_MAX - 0.001, "text")) +
    row("Performance", perf, "Reduced trims animations for low-power devices");
  return group("Appearance", body, "Accent, background, text size, and performance apply across the whole app instantly.");
}

function audioSubtitlesSection(audioLang: string, subtitleLang: string, mode: SubtitlesMode): string {
  const subMode = segmented([
    { value: "off", label: "Off", on: mode === "off" },
    { value: "on", label: "On", on: mode === "on" },
    { value: "forced", label: "Forced", on: mode === "forced" },
  ], "subtitles-mode", "mode");
  const body =
    row("Audio language", langSelect("audio-lang", audioLang, "Original")) +
    row("Subtitle language", langSelect("subtitle-lang", subtitleLang, "None")) +
    row("Subtitles", subMode);
  return group("Audio & Subtitles", body, "Preferred languages are requested when a source offers multiple tracks.");
}

function subtitleStyleSection(scale: number, font: SubtitleFont, color: SubtitleColor, edge: SubtitleEdge): string {
  const fontSeg = segmented(
    [
      { value: "modern", label: "Modern", on: font === "modern" },
      { value: "classic", label: "Classic", on: font === "classic" },
      { value: "mono", label: "Mono", on: font === "mono" },
    ],
    "set-sub-font",
    "font",
  );
  const colorSwatches = (Object.keys(SUB_COLORS) as SubtitleColor[])
    .map(
      (c) =>
        `<button class="swatch${c === color ? " selected" : ""}" style="--sw:${SUB_COLORS[c]}" data-action="set-sub-color" data-color="${c}" title="${c}" aria-label="${c}"></button>`,
    )
    .join("");
  const edgeSeg = segmented(
    [
      { value: "outline", label: "Outline", on: edge === "outline" },
      { value: "shadow", label: "Shadow", on: edge === "shadow" },
      { value: "box", label: "Box", on: edge === "box" },
      { value: "none", label: "None", on: edge === "none" },
    ],
    "set-sub-edge",
    "edge",
  );
  const sizeSeg = segmented(
    SUB_SIZES.map((o) => ({ value: String(o.v), label: o.l, on: Math.abs(scale - o.v) < 0.01 })),
    "set-sub-size",
    "size",
  );
  const body =
    row("Font", fontSeg) +
    row("Size", sizeSeg) +
    row("Fine size", stepper("sub-size", Math.round(scale * 100), scale <= SUB_MIN + 0.001, scale >= SUB_MAX - 0.001, "subtitle")) +
    row("Color", `<div class="swatches">${colorSwatches}</div>`) +
    row("Background", edgeSeg);
  return group("Subtitle Style", body, "Styles the player's subtitle track.");
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
    row("Player", `<span class="settings-row-sub">hls.js · native &lt;video&gt;</span>`) +
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

/** A -/+ stepper showing a percentage. `dir` is carried on data-dir; `kind` distinguishes which value. */
function stepper(action: string, pct: number, atMin: boolean, atMax: boolean, kind: string): string {
  return `
    <div class="stepper">
      <button class="stepper-btn" data-action="${action}" data-dir="-1" ${atMin ? "disabled" : ""} aria-label="Smaller ${kind}">-</button>
      <span class="stepper-value">${pct}%</span>
      <button class="stepper-btn" data-action="${action}" data-dir="1" ${atMax ? "disabled" : ""} aria-label="Larger ${kind}">+</button>
    </div>`;
}

function textField(id: string, key: string, value: string, placeholder: string): string {
  return `<input class="field settings-key" type="text" id="${id}" data-text-input="${key}"
    placeholder="${escapeHtml(placeholder)}" value="${escapeHtml(value)}" autocomplete="off" spellcheck="false" aria-label="${escapeHtml(placeholder)}" />`;
}

/** A masked (password-dots) field for secrets like API keys, with a Show/Hide reveal toggle. */
function secretField(id: string, key: string, value: string, placeholder: string): string {
  return `<span class="secret-field">
    <input class="field settings-key" type="password" id="${id}" data-text-input="${key}"
      placeholder="${escapeHtml(placeholder)}" value="${escapeHtml(value)}" autocomplete="off" autocapitalize="none"
      spellcheck="false" aria-label="${escapeHtml(placeholder)}" />
    <button type="button" class="chip secret-reveal" data-action="toggle-secret" data-target="${id}" aria-label="Show or hide ${escapeHtml(placeholder)}">Show</button>
  </span>`;
}

function langSelect(id: string, value: string, defaultLabel: string): string {
  const opts = LANGS.map((l) => {
    const label = l.code === "" ? defaultLabel : l.name;
    return `<option value="${l.code}"${l.code === value ? " selected" : ""}>${label}</option>`;
  }).join("");
  return `<select class="settings-select" id="${id}" data-select="${id}">${opts}</select>`;
}

/** The source-type priority list (highest first), each row with up/down controls. */
function reorderList(order: SourceType[]): string {
  return order
    .map((type, i) => {
      const info = SOURCE_LABELS[type];
      const up = `<button class="stepper-btn" data-action="source-move" data-type="${type}" data-dir="-1" ${i === 0 ? "disabled" : ""} aria-label="Move ${info.name} up">↑</button>`;
      const down = `<button class="stepper-btn" data-action="source-move" data-type="${type}" data-dir="1" ${i === order.length - 1 ? "disabled" : ""} aria-label="Move ${info.name} down">↓</button>`;
      return row(info.name, `<div class="reorder-ctl">${up}${down}</div>`, info.sub);
    })
    .join("");
}

// ---- Interaction --------------------------------------------------------------------------------

/** Click handler for the settings controls (buttons). Returns true if it consumed the event. */
export function handleSettingsClick(target: EventTarget | null): boolean {
  const hit = actionOf(target);
  if (!hit) return false;
  const d = hit.node.dataset;
  switch (hit.action) {
    case "set-accent":
      return commit({ accentID: d.accent ?? "vortx" });
    case "set-bg":
      return commit({ background: d.bg === "oled" ? "oled" : "warm" });
    case "set-perf":
      return commit({ performance: (d.perf as Performance) ?? "auto" });
    case "text-size":
      return commit({ textScale: clampScale(getSettings().textScale + (Number(d.dir) || 0) * TEXT_STEP) });
    case "subtitles-mode":
      return commit({ subtitlesMode: (d.mode as SubtitlesMode) ?? "on" });
    case "set-quality":
      return commit({ preferredQuality: Number(d.q) || 0 });
    case "set-skip":
      return commit({ skipStep: Number(d.skip) || 10 });
    case "set-preset": {
      const preset = QUALITY_PRESETS[d.preset as keyof typeof QUALITY_PRESETS];
      return preset ? commit(preset) : false;
    }
    case "set-safety":
      return commit({ safetyFilter: (d.safety as SafetyFilter) ?? "off" });
    case "set-maxq":
      return commit({ maxQuality: Number(d.mq) || 0 });
    case "set-maxsize":
      return commit({ maxFileSizeGB: Number(d.ms) || 0 });
    case "toggle-addon-order":
      return commit({ useAddonOrder: !getSettings().useAddonOrder });
    case "toggle-instant":
      return commit({ instantOnly: !getSettings().instantOnly });
    case "toggle-dead":
      return commit({ hideDeadTorrents: !getSettings().hideDeadTorrents });
    case "toggle-hdr":
      return commit({ hdrOnly: !getSettings().hdrOnly });
    case "toggle-av1":
      return commit({ hideAV1: !getSettings().hideAV1 });
    case "toggle-direct":
      return commit({ directLinksOnly: !getSettings().directLinksOnly });
    case "toggle-autoplay":
      return commit({ autoplayTrailers: !getSettings().autoplayTrailers });
    case "toggle-alerts":
      return toggleAlerts();
    case "source-move":
      return moveSource(d.type as SourceType, Number(d.dir) || 0);
    case "set-sub-font":
      return commit({ subtitleFont: (d.font as SubtitleFont) ?? "modern" });
    case "set-sub-color":
      return commit({ subtitleColor: (d.color as SubtitleColor) ?? "white" });
    case "set-sub-edge":
      return commit({ subtitleEdge: (d.edge as SubtitleEdge) ?? "outline" });
    case "set-sub-size":
      return commit({ subtitleScale: clampSub(Number(d.size) || 1) });
    case "sub-size":
      return commit({ subtitleScale: clampSub(getSettings().subtitleScale + (Number(d.dir) || 0) * SUB_STEP) });
    case "account-signout":
      signOut();
      rerender();
      return true;
    case "toggle-secret": {
      const input = host?.querySelector<HTMLInputElement>("#" + (hit.node.dataset.target ?? ""));
      if (input) {
        const masked = input.type === "password";
        input.type = masked ? "text" : "password";
        hit.node.textContent = masked ? "Hide" : "Show";
      }
      return true;
    }
    case "export-backup":
      downloadBackup();
      return true;
    default:
      return false;
  }
}

/** Persist a settings patch, re-render the screen, and report the click as consumed. */
function commit(patch: Partial<Settings>): boolean {
  updateSettings(patch);
  rerender();
  return true;
}

/** Toggle new-episode alerts; request browser notification permission the first time it is turned on. */
function toggleAlerts(): boolean {
  const next = !getSettings().episodeAlerts;
  updateSettings({ episodeAlerts: next });
  if (next && "Notification" in window && Notification.permission === "default") {
    void Notification.requestPermission();
  }
  rerender();
  return true;
}

/** Reorder a source type within the priority list (immutably). */
function moveSource(type: SourceType, dir: number): boolean {
  const order = [...getSettings().sourceOrder];
  const i = order.indexOf(type);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= order.length) return true;
  const swapped = order[j];
  order[j] = order[i];
  order[i] = swapped;
  updateSettings({ sourceOrder: order });
  rerender();
  return true;
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

/** Attach change listeners for the native <select> controls (languages) + the text inputs (keys/filters). */
function wireSettings(target: HTMLElement): void {
  target.querySelectorAll<HTMLSelectElement>("select[data-select]").forEach((sel) => {
    sel.addEventListener("change", () => {
      if (sel.dataset.select === "audio-lang") updateSettings({ audioLang: sel.value });
      else if (sel.dataset.select === "subtitle-lang") updateSettings({ subtitleLang: sel.value });
    });
  });

  target.querySelectorAll<HTMLInputElement>("input[data-text-input]").forEach((inp) => {
    inp.addEventListener("change", () => {
      const val = inp.value.trim();
      switch (inp.dataset.textInput) {
        case "mdblist":
          updateSettings({ mdblistKey: val });
          break;
        case "tmdb":
          updateSettings({ tmdbKey: val });
          break;
        case "hide":
          updateSettings({ hideWords: val });
          break;
        case "require":
          updateSettings({ requireWords: val });
          break;
      }
    });
  });

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
