import type Hls from "hls.js";
import { icon } from "./icons";
import { escapeHtml } from "./dom";
import { getSettings, updateSettings } from "./settings";

// A full custom control chrome for the web player's <video>, replacing the bare native controls. Built in
// the app's vanilla-DOM idiom (no player library, so ~0 extra bundle and it matches the design tokens):
//   - scrubber with played + buffered fills, drag-to-seek, and a hover time tooltip
//   - play/pause + skip back/forward, current/total time
//   - volume (mute + slider), remembered across sessions
//   - a settings menu: Quality (from hls.js levels), Speed, Audio track (from hls.js audio tracks)
//   - an in-player Subtitles menu (the loaded <track>s, styled by the app's subtitle settings)
//   - Picture in Picture, Cast (Remote Playback API), Fullscreen
//   - a buffering spinner, click-to-toggle, double-click fullscreen, and auto-hide on inactivity
// player.ts owns the media (HLS attach, subtitles, resume/progress); this owns the UI. The two talk via the
// returned controller: setHls() wires the quality/audio menus once hls.js is up; refreshSubtitles() rebuilds
// the CC menu as <track>s arrive.

const VOL_KEY = "vortx.web.player.volume.v1";
const ASPECT_KEY = "vortx.web.player.aspect.v1";
const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
// Aspect / zoom, mirroring the apps' "Aspect Ratio" panel (original / fill / stretch).
const ASPECTS: Array<{ label: string; value: "contain" | "cover" | "fill" }> = [
  { label: "Fit", value: "contain" },
  { label: "Fill (crop)", value: "cover" },
  { label: "Stretch", value: "fill" },
];
// Sleep timer presets (minutes); the player pauses when the timer elapses.
const SLEEPS: Array<{ label: string; mins: number }> = [
  { label: "Off", mins: 0 },
  { label: "15 min", mins: 15 },
  { label: "30 min", mins: 30 },
  { label: "45 min", mins: 45 },
  { label: "1 hour", mins: 60 },
];
// In-player subtitle size presets (the apps expose size in the player; web stores it in settings).
const SUB_SIZES: Array<{ label: string; scale: number }> = [
  { label: "Small", scale: 0.8 },
  { label: "Medium", scale: 1 },
  { label: "Large", scale: 1.3 },
  { label: "Huge", scale: 1.6 },
];
const HIDE_AFTER_MS = 3000;

/** An intro / outro segment (seconds). While playback sits inside one, the chrome shows a Skip button that
 *  jumps to `end`. `kind` only drives the button label ("Skip Intro" vs "Skip Outro"). */
export interface SkipSegment {
  kind: "intro" | "outro";
  start: number;
  end: number;
}

export interface PlayerControlsCtx {
  title: string;
  skipStep: number;
  /** Intro / outro segments for a Skip button (empty when none are known). */
  skipSegments?: SkipSegment[];
  /** Show a Next Episode affordance (series with a following episode). */
  hasNextEpisode?: boolean;
  /** Play the next episode. */
  onNextEpisode?: () => void;
  /** Manually advance to the next fallback source (present only when a fallback exists). */
  onTryNextSource?: () => void;
}

export interface PlayerController {
  /** Wire the Quality + Audio-track menus from an hls.js instance (call once it exists; null for direct). */
  setHls(hls: Hls | null): void;
  /** Rebuild the Subtitles menu from the video's current text tracks (call after tracks are added). */
  refreshSubtitles(): void;
  /** Flag that the player auto-muted for autoplay (shows the tap-to-unmute pill). */
  setAutoMuted(on: boolean): void;
  /** Read-and-clear the auto-muted flag: true only if WE auto-muted (so a user gesture may restore sound). */
  consumeAutoMuted(): boolean;
  /** Show a transient toast (e.g. an honest "switched source" message). */
  toast(msg: string): void;
  /** Remove listeners + timers. */
  dispose(): void;
}

/** mm:ss, or h:mm:ss past an hour. NaN/Infinity render as a stable placeholder. */
function fmt(sec: number): string {
  if (!isFinite(sec) || sec < 0) return "0:00";
  const s = Math.floor(sec % 60);
  const m = Math.floor((sec / 60) % 60);
  const h = Math.floor(sec / 3600);
  const mm = h ? String(m).padStart(2, "0") : String(m);
  return (h ? `${h}:` : "") + `${mm}:${String(s).padStart(2, "0")}`;
}

function menuItems(rows: Array<{ label: string; value: string; active: boolean }>, action: string): string {
  return rows
    .map(
      (r) =>
        `<button class="pl-menu-item${r.active ? " is-active" : ""}" role="menuitemradio" aria-checked="${r.active}" data-action="${action}" data-value="${escapeHtml(r.value)}">${escapeHtml(r.label)}</button>`,
    )
    .join("");
}

export function mountControls(host: HTMLElement, video: HTMLVideoElement, ctx: PlayerControlsCtx): PlayerController {
  let hls: Hls | null = null;
  let hideTimer = 0;
  let scrubbing = false;
  let openMenu: "settings" | "subs" | null = null;
  let sleepTimer = 0;
  let sleepMins = 0;
  let autoMuted = false; // set when the player muted itself for autoplay (drives the tap-to-unmute pill)
  const skipSegments = ctx.skipSegments ?? [];

  const remotePlayback = (video as unknown as { remote?: { state?: string } }).remote;
  const canCast = typeof remotePlayback === "object" && remotePlayback !== null && "watchAvailability" in (remotePlayback as object);

  const stageRoot = document.createElement("div");
  stageRoot.className = "pl-stage";
  stageRoot.id = "pl-stage";
  stageRoot.innerHTML = `
      <div class="pl-spinner" id="pl-spinner" aria-hidden="true"></div>
      <div class="pl-toptint" aria-hidden="true"></div>
      <div class="pl-bottomtint" aria-hidden="true"></div>

      <div class="pl-top">
        <button class="pl-icon pl-back" data-action="close-player" aria-label="Back">${icon("chevron-left") || "‹"}<span>Back</span></button>
        <div class="pl-title">${escapeHtml(ctx.title)}</div>
      </div>

      <button class="pl-unmute" id="pl-unmute" hidden aria-label="Tap to unmute">${icon("volume-x") || "🔇"}<span>Tap to unmute</span></button>

      <div class="pl-corner">
        <button class="pl-skipseg" id="pl-skipseg" hidden></button>
        ${ctx.hasNextEpisode ? `<button class="pl-next" id="pl-next" aria-label="Next episode">${icon("fast-forward") || "⟳"}<span>Next Episode</span></button>` : ""}
      </div>

      <div class="pl-center">
        <button class="pl-icon pl-skip" id="pl-rew" aria-label="Skip back ${ctx.skipStep} seconds">${icon("rewind") || "⟲"}<small>${ctx.skipStep}</small></button>
        <button class="pl-icon pl-bigplay" id="pl-bigplay" aria-label="Play/pause"></button>
        <button class="pl-icon pl-skip" id="pl-ff" aria-label="Skip forward ${ctx.skipStep} seconds">${icon("fast-forward") || "⟳"}<small>${ctx.skipStep}</small></button>
      </div>

      <div class="pl-bottom">
        <div class="pl-seek" id="pl-seek" role="slider" tabindex="0" aria-label="Seek" aria-valuemin="0" aria-valuemax="0" aria-valuenow="0">
          <div class="pl-seek-track"><div class="pl-seek-buffered" id="pl-buffered"></div><div class="pl-seek-played" id="pl-played"></div><div class="pl-seek-handle" id="pl-handle"></div></div>
          <div class="pl-seek-tip" id="pl-tip" aria-hidden="true">0:00</div>
        </div>
        <div class="pl-bar">
          <button class="pl-icon" id="pl-play" aria-label="Play/pause"></button>
          <div class="pl-vol">
            <button class="pl-icon" id="pl-mute" aria-label="Mute"></button>
            <input class="pl-vol-slider" id="pl-vol" type="range" min="0" max="1" step="0.05" value="1" aria-label="Volume" />
          </div>
          <div class="pl-time"><span id="pl-cur">0:00</span> <span class="pl-time-sep">/</span> <span id="pl-dur">0:00</span></div>
          <div class="pl-spacer"></div>
          <button class="pl-icon" id="pl-subs-btn" aria-label="Subtitles" aria-haspopup="true">${icon("subtitles") || "CC"}</button>
          <button class="pl-icon" id="pl-snap" aria-label="Save frame">${icon("camera") || "▣"}</button>
          <button class="pl-icon" id="pl-settings-btn" aria-label="Settings" aria-haspopup="true">${icon("settings") || "⚙"}</button>
          ${canCast ? `<button class="pl-icon" id="pl-cast" aria-label="Cast">${icon("cast") || "▶"}</button>` : ""}
          <button class="pl-icon" id="pl-pip" aria-label="Picture in picture">${icon("pip") || "⧉"}</button>
          <button class="pl-icon" id="pl-fs" aria-label="Fullscreen">${icon("fullscreen") || "⤢"}</button>
        </div>
      </div>

      <div class="pl-menu" id="pl-menu-settings" role="menu" hidden></div>
      <div class="pl-menu" id="pl-menu-subs" role="menu" hidden></div>`;
  host.appendChild(stageRoot);

  const $ = <T extends HTMLElement = HTMLElement>(id: string) => host.querySelector<T>("#" + id);
  const stage = $("pl-stage")!;
  const seek = $("pl-seek")!;
  const played = $("pl-played")!;
  const buffered = $("pl-buffered")!;
  const handle = $("pl-handle")!;
  const tip = $("pl-tip")!;
  const settingsMenu = $("pl-menu-settings")!;
  const subsMenu = $("pl-menu-subs")!;

  const PLAY = icon("play") || "►";
  const PAUSE = icon("pause") || "❚❚";

  // ---- restore remembered volume ----
  try {
    const v = JSON.parse(localStorage.getItem(VOL_KEY) ?? "null") as { volume?: number; muted?: boolean } | null;
    if (v && typeof v.volume === "number") video.volume = Math.min(1, Math.max(0, v.volume));
    if (v && typeof v.muted === "boolean") video.muted = v.muted;
  } catch {
    /* default volume */
  }

  // ---- restore aspect (object-fit) ----
  try {
    const a = localStorage.getItem(ASPECT_KEY);
    if (a === "contain" || a === "cover" || a === "fill") video.style.objectFit = a;
  } catch {
    /* default fit */
  }

  // ---- play/pause ----
  const togglePlay = () => {
    if (video.paused || video.ended) void video.play().catch(() => undefined);
    else video.pause();
  };
  const renderPlay = () => {
    const m = video.paused ? PLAY : PAUSE;
    $("pl-play")!.innerHTML = m;
    $("pl-bigplay")!.innerHTML = video.paused ? PLAY : PAUSE;
    stage.classList.toggle("is-paused", video.paused);
  };
  $("pl-play")!.addEventListener("click", togglePlay);
  $("pl-bigplay")!.addEventListener("click", togglePlay);
  $("pl-rew")!.addEventListener("click", () => (video.currentTime = Math.max(0, video.currentTime - ctx.skipStep)));
  $("pl-ff")!.addEventListener("click", () => (video.currentTime = Math.min(video.duration || Infinity, video.currentTime + ctx.skipStep)));

  // ---- seek (played + buffered + drag + hover tip) ----
  const pctFromEvent = (clientX: number) => {
    const r = seek.getBoundingClientRect();
    return Math.min(1, Math.max(0, (clientX - r.left) / r.width));
  };
  const renderProgress = () => {
    const d = video.duration;
    if (!isFinite(d) || d <= 0) return;
    played.style.width = `${(video.currentTime / d) * 100}%`;
    handle.style.left = `${(video.currentTime / d) * 100}%`;
    let end = 0;
    for (let i = 0; i < video.buffered.length; i++) {
      if (video.buffered.start(i) <= video.currentTime) end = Math.max(end, video.buffered.end(i));
    }
    buffered.style.width = `${(end / d) * 100}%`;
    seek.setAttribute("aria-valuemax", String(Math.floor(d)));
    seek.setAttribute("aria-valuenow", String(Math.floor(video.currentTime)));
    seek.setAttribute("aria-valuetext", fmt(video.currentTime));
  };
  const seekTo = (clientX: number) => {
    const d = video.duration;
    if (isFinite(d) && d > 0) video.currentTime = pctFromEvent(clientX) * d;
  };
  seek.addEventListener("pointerdown", (e) => {
    scrubbing = true;
    seek.setPointerCapture(e.pointerId);
    seekTo(e.clientX);
  });
  seek.addEventListener("pointermove", (e) => {
    const d = video.duration;
    if (isFinite(d) && d > 0) {
      tip.textContent = fmt(pctFromEvent(e.clientX) * d);
      tip.style.left = `${pctFromEvent(e.clientX) * 100}%`;
    }
    if (scrubbing) seekTo(e.clientX);
  });
  const endScrub = () => (scrubbing = false);
  seek.addEventListener("pointerup", endScrub);
  seek.addEventListener("pointercancel", endScrub);

  // ---- volume ----
  const volSlider = $<HTMLInputElement>("pl-vol")!;
  const renderVolume = () => {
    volSlider.value = String(video.muted ? 0 : video.volume);
    const off = video.muted || video.volume === 0;
    $("pl-mute")!.innerHTML = off ? icon("volume-x") || "🔇" : video.volume < 0.5 ? icon("volume-1") || "🔉" : icon("volume-2") || "🔊";
    try {
      localStorage.setItem(VOL_KEY, JSON.stringify({ volume: video.volume, muted: video.muted }));
    } catch {
      /* best-effort */
    }
  };
  $("pl-mute")!.addEventListener("click", () => (video.muted = !video.muted));
  volSlider.addEventListener("input", () => {
    video.volume = Number(volSlider.value);
    video.muted = video.volume === 0;
  });

  // ---- time ----
  const renderTime = () => {
    $("pl-cur")!.textContent = fmt(video.currentTime);
    $("pl-dur")!.textContent = fmt(video.duration);
  };

  // ---- fullscreen / pip / cast ----
  $("pl-fs")!.addEventListener("click", () => {
    if (document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
    else void host.requestFullscreen().catch(() => undefined);
  });
  $("pl-pip")!.addEventListener("click", () => {
    if (document.pictureInPictureElement) void document.exitPictureInPicture().catch(() => undefined);
    else if (document.pictureInPictureEnabled) void video.requestPictureInPicture().catch(() => undefined);
  });
  $("pl-cast")?.addEventListener("click", () => {
    (video as unknown as { remote?: { prompt?: () => Promise<void> } }).remote?.prompt?.().catch(() => undefined);
  });

  // ---- next episode ----
  $("pl-next")?.addEventListener("click", () => ctx.onNextEpisode?.());

  // ---- skip intro / outro ----
  // The button is shown only while playback is inside a known segment; clicking it jumps past the segment.
  const skipBtn = $("pl-skipseg");
  let activeSeg: SkipSegment | null = null;
  const renderSkip = () => {
    if (!skipBtn) return;
    const t = video.currentTime;
    const seg = skipSegments.find((s) => t >= s.start && t < s.end - 0.5) ?? null;
    if (seg === activeSeg) return;
    activeSeg = seg;
    if (seg) {
      skipBtn.textContent = seg.kind === "outro" ? "Skip Outro" : "Skip Intro";
      skipBtn.hidden = false;
    } else {
      skipBtn.hidden = true;
    }
  };
  skipBtn?.addEventListener("click", () => {
    if (activeSeg) video.currentTime = activeSeg.end;
    renderSkip();
  });

  // ---- tap-to-unmute pill (D6 autoplay) ----
  const unmuteBtn = $("pl-unmute");
  const hideUnmute = () => {
    autoMuted = false;
    if (unmuteBtn) unmuteBtn.hidden = true;
  };
  unmuteBtn?.addEventListener("click", (e) => {
    e.stopPropagation();
    video.muted = false;
    if (video.volume === 0) video.volume = 1;
    hideUnmute();
  });

  // ---- menus ----
  const closeMenus = () => {
    settingsMenu.hidden = true;
    subsMenu.hidden = true;
    openMenu = null;
  };
  const buildSettingsMenu = () => {
    const sections: string[] = [];
    // Quality (hls levels). -1 == Auto. levels[].height gives the resolution.
    const levels = (hls?.levels ?? []) as Array<{ height?: number; bitrate?: number }>;
    if (levels.length > 1) {
      const cur = hls ? hls.currentLevel : -1;
      const rows = [{ label: "Auto", value: "-1", active: cur === -1 }].concat(
        levels.map((l, i) => ({
          label: l.height ? `${l.height}p` : l.bitrate ? `${Math.round(l.bitrate / 1000)} kbps` : `Level ${i + 1}`,
          value: String(i),
          active: cur === i,
        })),
      );
      sections.push(`<div class="pl-menu-h">Quality</div>${menuItems(rows, "player-quality")}`);
    }
    // Audio tracks (hls). Only when there's a real choice.
    const audio = (hls?.audioTracks ?? []) as Array<{ name?: string; lang?: string }>;
    if (audio.length > 1 && hls) {
      const curA = hls.audioTrack;
      const rows = audio.map((a, i) => ({ label: a.name || a.lang || `Audio ${i + 1}`, value: String(i), active: curA === i }));
      sections.push(`<div class="pl-menu-h">Audio</div>${menuItems(rows, "player-audio")}`);
    }
    // Speed (always available).
    const rate = video.playbackRate || 1;
    const speedRows = SPEEDS.map((s) => ({ label: s === 1 ? "Normal" : `${s}x`, value: String(s), active: Math.abs(s - rate) < 0.01 }));
    sections.push(`<div class="pl-menu-h">Speed</div>${menuItems(speedRows, "player-speed")}`);
    // Aspect ratio / zoom (object-fit), mirroring the apps' Aspect Ratio panel.
    const fit = video.style.objectFit || "contain";
    const aspectRows = ASPECTS.map((a) => ({ label: a.label, value: a.value, active: fit === a.value }));
    sections.push(`<div class="pl-menu-h">Aspect Ratio</div>${menuItems(aspectRows, "player-aspect")}`);
    // Sleep timer: pause playback after the chosen delay.
    const sleepRows = SLEEPS.map((s) => ({ label: s.label, value: String(s.mins), active: sleepMins === s.mins }));
    sections.push(`<div class="pl-menu-h">Sleep Timer</div>${menuItems(sleepRows, "player-sleep")}`);
    settingsMenu.innerHTML = sections.join("");
  };
  const buildSubsMenu = () => {
    const tracks = Array.from(video.textTracks).filter((t) => t.kind === "subtitles" || t.kind === "captions");
    const anyShowing = tracks.some((t) => t.mode === "showing");
    const rows = [{ label: "Off", value: "-1", active: !anyShowing }].concat(
      tracks.map((t, i) => ({ label: t.label || (t.language || `Track ${i + 1}`).toUpperCase(), value: String(i), active: t.mode === "showing" })),
    );
    // In-player subtitle style (size + background), mirroring the apps' Subtitle Settings panel. These map
    // to the global subtitle settings, applied live to the video's cues via CSS vars.
    const s = getSettings();
    const sizeRows = SUB_SIZES.map((z) => ({ label: z.label, value: String(z.scale), active: Math.abs(s.subtitleScale - z.scale) < 0.05 }));
    const bgRows = [
      { label: "On", value: "box", active: s.subtitleEdge === "box" },
      { label: "Off", value: "outline", active: s.subtitleEdge !== "box" },
    ];
    subsMenu.innerHTML =
      `<div class="pl-menu-h">Subtitles</div>${tracks.length ? menuItems(rows, "player-subtitle") : '<div class="pl-menu-empty">No subtitles for this source</div>'}` +
      `<div class="pl-menu-h">Size</div>${menuItems(sizeRows, "player-subsize")}` +
      `<div class="pl-menu-h">Background</div>${menuItems(bgRows, "player-subbg")}`;
  };
  $("pl-settings-btn")!.addEventListener("click", () => {
    const show = openMenu !== "settings";
    closeMenus();
    if (show) {
      buildSettingsMenu();
      settingsMenu.hidden = false;
      openMenu = "settings";
    }
  });
  $("pl-subs-btn")!.addEventListener("click", () => {
    const show = openMenu !== "subs";
    closeMenus();
    if (show) {
      buildSubsMenu();
      subsMenu.hidden = false;
      openMenu = "subs";
    }
  });

  // Escape: first close an open menu instead of closing the whole player. Capture phase + stopPropagation
  // so this runs before (and suppresses) the global Escape handler in main.ts whenever a menu is open.
  const onDocKeydown = (e: KeyboardEvent) => {
    if (e.key === "Escape" && openMenu) {
      e.stopPropagation();
      closeMenus();
    }
  };
  document.addEventListener("keydown", onDocKeydown, true);

  // Menu item clicks (delegated on the stage so rebuilt menus stay wired).
  stage.addEventListener("click", (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>("[data-action]");
    if (!btn) return;
    const action = btn.dataset.action;
    const value = btn.dataset.value ?? "";
    if (action === "player-quality" && hls) {
      hls.currentLevel = Number(value);
      buildSettingsMenu();
    } else if (action === "player-audio" && hls) {
      hls.audioTrack = Number(value);
      buildSettingsMenu();
    } else if (action === "player-speed") {
      video.playbackRate = Number(value);
      buildSettingsMenu();
    } else if (action === "player-subtitle") {
      const tracks = Array.from(video.textTracks).filter((t) => t.kind === "subtitles" || t.kind === "captions");
      const pick = Number(value);
      tracks.forEach((t, i) => (t.mode = i === pick ? "showing" : "disabled"));
      buildSubsMenu();
      closeMenus();
    } else if (action === "player-aspect") {
      const fit = value === "cover" || value === "fill" ? value : "contain";
      video.style.objectFit = fit;
      try {
        localStorage.setItem(ASPECT_KEY, fit);
      } catch {
        /* best-effort */
      }
      buildSettingsMenu();
    } else if (action === "player-sleep") {
      sleepMins = Number(value);
      window.clearTimeout(sleepTimer);
      if (sleepMins > 0) sleepTimer = window.setTimeout(() => video.pause(), sleepMins * 60_000);
      buildSettingsMenu();
    } else if (action === "player-subsize") {
      updateSettings({ subtitleScale: Number(value) });
      buildSubsMenu();
    } else if (action === "player-subbg") {
      updateSettings({ subtitleEdge: value === "box" ? "box" : "outline" });
      buildSubsMenu();
    }
  });

  // ---- snapshot / frame grab ----
  const flash = (msg: string) => {
    const n = document.createElement("div");
    n.className = "pl-flash";
    n.textContent = msg;
    stageRoot.appendChild(n);
    window.setTimeout(() => n.remove(), 2600);
  };
  $("pl-snap")!.addEventListener("click", () => {
    try {
      const canvas = document.createElement("canvas");
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      if (!canvas.width || !canvas.height) return;
      canvas.getContext("2d")?.drawImage(video, 0, 0, canvas.width, canvas.height);
      canvas.toBlob((blob) => {
        if (!blob) return;
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = `vortx-frame-${Math.floor(video.currentTime)}s.png`;
        a.click();
        window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      }, "image/png");
      flash("Frame saved");
    } catch {
      // A canvas tainted by a non-CORS source can't be exported (browser security).
      flash("Frame grab isn't available for this source");
    }
  });

  // ---- stage tap / double-tap gestures ----
  // Desktop (fine pointer): click on the bare backdrop toggles play, double-click toggles fullscreen -
  // the familiar web-player behavior. Touch (coarse pointer): a single tap toggles the chrome, and a
  // double-tap on the left / right half seeks back / forward by the skip step (yt/twitch mobile idiom).
  const isTouch = typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
  let lastTap = 0;
  let tapTimer = 0;
  const seekBy = (delta: number) => {
    video.currentTime = Math.min(video.duration || Infinity, Math.max(0, video.currentTime + delta));
    flash(delta < 0 ? `« ${Math.abs(delta)}s` : `${delta}s »`);
  };
  stage.addEventListener("click", (e) => {
    if (e.target !== stage) return; // only the bare backdrop, not a control
    if (openMenu) {
      closeMenus(); // first backdrop click dismisses an open menu
      return;
    }
    if (!isTouch) {
      togglePlay();
      return;
    }
    // Touch: distinguish single tap (toggle chrome) from double tap (directional seek).
    const now = Date.now();
    if (now - lastTap < 300) {
      window.clearTimeout(tapTimer);
      lastTap = 0;
      const r = stage.getBoundingClientRect();
      seekBy((e as MouseEvent).clientX - r.left < r.width / 2 ? -ctx.skipStep : ctx.skipStep);
      return;
    }
    lastTap = now;
    tapTimer = window.setTimeout(() => {
      // Single tap: toggle chrome visibility.
      if (stage.classList.contains("pl-hidden")) show();
      else stage.classList.add("pl-hidden");
    }, 300);
  });
  stage.addEventListener("dblclick", (e) => {
    if (e.target !== stage || isTouch) return; // touch double-taps are handled on click above
    $("pl-fs")!.click();
  });

  // ---- auto-hide ----
  const show = () => {
    stage.classList.remove("pl-hidden");
    window.clearTimeout(hideTimer);
    if (!video.paused && !openMenu) hideTimer = window.setTimeout(() => stage.classList.add("pl-hidden"), HIDE_AFTER_MS);
  };
  stage.addEventListener("pointermove", show);
  stage.addEventListener("pointerdown", show);
  stage.addEventListener("focusin", show);

  // ---- buffering spinner ----
  const spinner = $("pl-spinner")!;
  const onWaiting = () => (spinner.style.opacity = "1");
  const onPlaying = () => (spinner.style.opacity = "0");

  // ---- bind video events ----
  const onTime = () => {
    if (!scrubbing) renderProgress();
    renderTime();
    renderSkip();
  };
  video.addEventListener("timeupdate", onTime);
  video.addEventListener("progress", renderProgress);
  video.addEventListener("durationchange", () => {
    renderProgress();
    renderTime();
  });
  video.addEventListener("play", () => {
    renderPlay();
    show();
  });
  video.addEventListener("pause", () => {
    renderPlay();
    show();
  });
  video.addEventListener("volumechange", () => {
    renderVolume();
    // A manual unmute (or the media becoming audible again) retires the tap-to-unmute pill.
    if (!video.muted) hideUnmute();
  });
  video.addEventListener("ratechange", () => openMenu === "settings" && buildSettingsMenu());
  video.addEventListener("waiting", onWaiting);
  video.addEventListener("playing", onPlaying);
  video.addEventListener("canplay", onPlaying);

  // initial paint
  renderPlay();
  renderVolume();
  renderTime();
  show();

  return {
    setHls(next: Hls | null) {
      hls = next;
      if (openMenu === "settings") buildSettingsMenu();
    },
    refreshSubtitles() {
      if (openMenu === "subs") buildSubsMenu();
    },
    setAutoMuted(on: boolean) {
      autoMuted = on;
      if (unmuteBtn) unmuteBtn.hidden = !on;
      if (on) show(); // reveal the chrome so the pill is visible for the user's first tap
    },
    consumeAutoMuted() {
      const was = autoMuted;
      hideUnmute();
      return was;
    },
    toast(msg: string) {
      flash(msg);
    },
    dispose() {
      window.clearTimeout(hideTimer);
      window.clearTimeout(sleepTimer);
      window.clearTimeout(tapTimer);
      document.removeEventListener("keydown", onDocKeydown, true);
    },
  };
}
