import type Hls from "hls.js";
import type { ErrorData } from "hls.js";
import { el } from "./dom";
import { cwPosition, recordProgress } from "./store";
import { getSettings } from "./settings";
import type { SubtitleTrack } from "./addon";
import { mountControls, type PlayerController } from "./playerControls";

/** The slim title context the player needs to record Continue Watching progress. */
interface CWItem {
  id: string;
  type: string;
  name: string;
  poster?: string;
  /** The actual played id (episode id for a series); the resume position is keyed by this, not `id`. */
  resumeId?: string;
}

// The web player sink. The detail page resolves a direct/debrid HTTP(S) url and hands it here. Unlike
// the desktop player (libmpv via Tauri) the web client plays in a plain HTML5 <video> element:
//
//   - .m3u8 (HLS): hls.js attaches Media Source Extensions in browsers that support it (Chrome,
//     Firefox, Edge). Safari plays HLS natively, so we use the native path there (Safari has no MSE
//     for fMP4 HLS the way hls.js wants and its native HLS is excellent).
//   - everything else (mp4, mkv-if-the-browser-can, debrid direct links): set video.src directly and
//     let the browser's media stack handle it.
//
// hls.js is dynamically imported so its ~150KB only loads when the user actually plays something - the
// Board and Detail surfaces never pay for it (see vite.config manualChunks + this await import()).

const PLAYER_HOST_ID = "player";
const HLS_EXT = /\.m3u8(\?|$)/i;

let hls: Hls | null = null;
let keyHandler: ((e: KeyboardEvent) => void) | null = null;
let subtitleBlobs: string[] = [];
let controller: PlayerController | null = null;
// Monotonic session id: bumped on every play() and close() so an in-flight `await import("hls.js")` can
// detect that the player was closed (or a new source started) while it was loading and bail out instead of
// attaching a stale hls.js instance to a torn-down video (which leaked a worker and threw on a null
// controller).
let playToken = 0;
// Aborts in-flight subtitle fetches when the session ends, so a slow fetch can't push a blob URL into a
// session that has already been closed.
let subAbort: AbortController | null = null;

/** Whether a url looks like an HLS playlist. */
function isHls(url: string): boolean {
  return HLS_EXT.test(url);
}

// Variable playback speed; the control bar reflects changes via the video's ratechange event.
const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
function stepSpeed(video: HTMLVideoElement, dir: number): void {
  const cur = video.playbackRate || 1;
  let i = SPEEDS.findIndex((s) => Math.abs(s - cur) < 0.01);
  if (i === -1) i = SPEEDS.indexOf(1);
  video.playbackRate = SPEEDS[(i + dir + SPEEDS.length) % SPEEDS.length];
}

/** Stop and release the current media session: the hls.js instance (and its worker), the control chrome's
 *  timers, the subtitle blob URLs and any in-flight subtitle fetches, the keyboard handler, and the
 *  <video> itself. Shared by play() (so re-opening or switching source never leaks the previous session)
 *  and close(). Does NOT change the overlay's visibility; the caller owns that. */
function teardownMedia(host: HTMLElement | null): void {
  if (keyHandler) {
    document.removeEventListener("keydown", keyHandler);
    keyHandler = null;
  }
  controller?.dispose();
  controller = null;
  subAbort?.abort();
  subAbort = null;
  for (const u of subtitleBlobs) URL.revokeObjectURL(u);
  subtitleBlobs = [];
  if (hls) {
    hls.destroy();
    hls = null;
  }
  // Removing a <video> from the DOM does not pause it in Chrome; stop and unload it explicitly so it does
  // not keep decoding (and firing timeupdate -> recordProgress) in the background after teardown.
  const prev = host?.querySelector<HTMLVideoElement>("video");
  if (prev) {
    prev.pause();
    prev.removeAttribute("src");
    prev.load();
  }
}

/** Open the player overlay and play `url`. `title` is shown as thin chrome over the transport. */
export async function play(
  url: string,
  title: string,
  item?: CWItem,
  subtitles?: Promise<SubtitleTrack[]>,
): Promise<void> {
  const host = el(PLAYER_HOST_ID);
  if (!host) return;
  // Start a new session: this invalidates any previous play() still awaiting its hls.js import, and tears
  // the old session down so switching source (or re-opening) never leaks the prior hls worker, listeners,
  // or a still-decoding <video>.
  const myToken = ++playToken;
  teardownMedia(host);
  subAbort = new AbortController();
  host.classList.remove("hidden");
  host.setAttribute("aria-hidden", "false");
  host.innerHTML = "";

  // The <video> is the media surface; the custom control chrome (playerControls) is layered over it.
  const video = document.createElement("video");
  video.className = "player-video";
  video.id = "player-video";
  video.autoplay = true;
  video.playsInline = true;
  video.crossOrigin = "anonymous";
  host.appendChild(video);
  controller = mountControls(host, video, { title, skipStep: getSettings().skipStep });

  if (item) wireProgress(video, item);
  wireKeyboard(video);
  // Surface a clear message when the element fails to load or decode (an expired debrid link, a 404, an
  // unsupported codec). The hls.js path has its own fatal-error handler; this covers the direct/debrid
  // and native-HLS paths, which would otherwise just show a black player. Teardown clears the source via
  // load(), which fires "emptied"/"abort" rather than "error", so this does not fire on close.
  video.addEventListener("error", () =>
    showError(host, "This source could not be played. It may be offline or an unsupported format. Try another source."),
  );
  // Non-blocking: playback starts immediately; subtitle <track>s are added (and the CC menu rebuilt) when
  // the list resolves. Gated on the session token so a list that resolves after the player was closed or
  // a new source started does not attach tracks to (or fetch for) a dead session.
  if (subtitles) {
    void subtitles
      .then((subs) => {
        if (myToken !== playToken) return;
        return addSubtitleTracks(video, subs);
      })
      .then(() => {
        if (myToken === playToken) controller?.refreshSubtitles();
      })
      .catch(() => undefined);
  }

  // Direct sources (mp4 / mkv / debrid links): hand the url straight to the element.
  if (!isHls(url)) {
    controller.setHls(null);
    video.src = url;
    void video.play().catch(() => {
      /* autoplay can be blocked; the visible controls let the user start it */
    });
    return;
  }

  // HLS. Prefer hls.js wherever it is supported, because it powers the custom Quality / Audio-track /
  // Subtitle menus (the native engine hides those behind its own UI). The exception is Safari / iOS, where
  // Apple's native HLS is more reliable - notably for fMP4 - so there we defer to native (it does its own
  // adaptive bitrate + track handling, and our chrome still drives play/seek/volume/speed/fullscreen).
  const ua = navigator.userAgent;
  const preferNative =
    (/iP(ad|hone|od)/.test(ua) || /^((?!chrome|android|crios|fxios).)*safari/i.test(ua)) &&
    !!video.canPlayType("application/vnd.apple.mpegurl");
  if (!preferNative) {
    const mod = await import("hls.js");
    // The user may have closed the player or picked another source while hls.js was loading. Bail before
    // touching `controller`/`hls`, both of which the newer session (or close()) has already reset.
    if (myToken !== playToken) return;
    const HlsCtor = mod.default;
    if (HlsCtor.isSupported()) {
      hls = new HlsCtor({ enableWorker: true, lowLatencyMode: false });
      hls.loadSource(url);
      hls.attachMedia(video);
      controller.setHls(hls); // wire the Quality + Audio-track menus from the hls levels
      hls.on(HlsCtor.Events.MEDIA_ATTACHED, () => {
        void video.play().catch(() => undefined);
      });
      hls.on(HlsCtor.Events.ERROR, (_evt: unknown, data: ErrorData) => {
        if (!data.fatal) return;
        // Fatal media/network errors: try hls.js's documented recovery once, else surface a message.
        switch (data.type) {
          case mod.ErrorTypes.NETWORK_ERROR:
            hls?.startLoad();
            break;
          case mod.ErrorTypes.MEDIA_ERROR:
            hls?.recoverMediaError();
            break;
          default:
            showError(host, "This stream could not be played. Try another source.");
            break;
        }
      });
      return;
    }
  }

  // Native HLS (Safari / iOS, or hls.js unsupported): hand the playlist straight to the element.
  controller.setHls(null);
  video.src = url;
  void video.play().catch(() => undefined);
}

/** Record Continue Watching progress for `item` while it plays, and resume from the saved position.
 *  Throttled to once every 5s; passing 95% drops it from Continue Watching (treated as finished). */
function wireProgress(video: HTMLVideoElement, item: CWItem): void {
  video.addEventListener(
    "loadedmetadata",
    () => {
      const pos = cwPosition(item.resumeId ?? item.id);
      if (pos > 5 && (!isFinite(video.duration) || pos < video.duration - 10)) video.currentTime = pos;
    },
    { once: true },
  );
  let last = 0;
  video.addEventListener("timeupdate", () => {
    const now = Date.now();
    if (now - last < 5000) return;
    last = now;
    recordProgress(item, video.currentTime, video.duration);
  });
  // Playback ran to the end: force a final record at full duration so the title crosses the 95%
  // "finished" threshold and drops out of Continue Watching. The 5s-throttled timeupdate above can
  // miss the last seconds, which would otherwise leave a fully-watched title stuck in the rail.
  video.addEventListener("ended", () => recordProgress(item, video.duration, video.duration));
}

/** Global keyboard shortcuts while the player overlay is open (the native <video> controls only respond
 *  when the element is focused): Space play/pause, Left/Right seek by the Skip-step setting, Up/Down volume,
 *  [ / ] playback speed, M mute, F fullscreen.
 *  Removed on close so keys don't leak to the surfaces underneath. */
function wireKeyboard(video: HTMLVideoElement): void {
  if (keyHandler) document.removeEventListener("keydown", keyHandler);
  keyHandler = (e: KeyboardEvent) => {
    let handled = true;
    switch (e.code) {
      case "Space":
        if (video.paused) void video.play().catch(() => undefined);
        else video.pause();
        break;
      case "ArrowLeft":
        video.currentTime = Math.max(0, video.currentTime - getSettings().skipStep);
        break;
      case "ArrowRight":
        video.currentTime = Math.min(video.duration || Infinity, video.currentTime + getSettings().skipStep);
        break;
      case "ArrowUp":
        video.volume = Math.min(1, video.volume + 0.1);
        break;
      case "ArrowDown":
        video.volume = Math.max(0, video.volume - 0.1);
        break;
      case "BracketRight":
        stepSpeed(video, 1);
        break;
      case "BracketLeft":
        stepSpeed(video, -1);
        break;
      case "KeyM":
        video.muted = !video.muted;
        break;
      case "KeyF":
        if (document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
        else void video.requestFullscreen().catch(() => undefined);
        break;
      case "KeyP":
        if (document.pictureInPictureElement) void document.exitPictureInPicture().catch(() => undefined);
        else if (document.pictureInPictureEnabled) void video.requestPictureInPicture().catch(() => undefined);
        break;
      default:
        handled = false;
    }
    if (handled) e.preventDefault();
  };
  document.addEventListener("keydown", keyHandler);
}

/** Add subtitle <track>s to the video; the player's CC menu then exposes them to pick one. */
async function addSubtitleTracks(video: HTMLVideoElement, subs: SubtitleTrack[]): Promise<void> {
  // Convert all in parallel so one slow source does not hold up the rest (sequential awaits could take
  // up to ~12s x N before the user's language appears). Promise.all preserves the original order.
  const resolved = await Promise.all(subs.map(async (sub) => ({ sub, url: await toVttUrl(sub) })));
  for (const { sub, url } of resolved) {
    if (!url) continue;
    const track = document.createElement("track");
    track.kind = "subtitles";
    track.srclang = sub.lang;
    track.label = sub.lang.toUpperCase();
    track.src = url;
    video.appendChild(track);
  }
}

/** Fetch a subtitle file, convert SRT to WebVTT if needed, and return a blob: URL for a <track>. */
async function toVttUrl(sub: SubtitleTrack): Promise<string | null> {
  const abortCtrl = new AbortController();
  const timer = setTimeout(() => abortCtrl.abort(), 12_000);
  // Also abort if the player session ends while this fetch is in flight, so it can't push a stale blob URL.
  subAbort?.signal.addEventListener("abort", () => abortCtrl.abort(), { once: true });
  try {
    const res = await fetch(sub.url, { signal: abortCtrl.signal });
    if (!res.ok) return null;
    const text = await res.text();
    const isVtt = /\.vtt(\?|$)/i.test(sub.url) || /^﻿?\s*WEBVTT/.test(text);
    const blobUrl = URL.createObjectURL(new Blob([isVtt ? text : srtToVtt(text)], { type: "text/vtt" }));
    subtitleBlobs.push(blobUrl);
    return blobUrl;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** Minimal SRT to WebVTT: prepend the WEBVTT header and switch cue-time commas to dots. */
function srtToVtt(srt: string): string {
  const body = srt
    .replace(/\r+/g, "")
    .replace(/^﻿/, "")
    .replace(/(\d{2}:\d{2}:\d{2}),(\d{3})/g, "$1.$2");
  return "WEBVTT\n\n" + body;
}

/** Render an inline error inside the player overlay (keeps the Back button reachable). */
function showError(host: HTMLElement, message: string): void {
  const existing = host.querySelector(".player-error");
  if (existing) {
    existing.textContent = message;
    return;
  }
  const note = document.createElement("p");
  note.className = "player-error";
  note.textContent = message;
  host.appendChild(note);
}

/** Tear down playback: destroy the hls.js instance (if any), stop the element, hide the overlay. */
export function close(): void {
  playToken++; // invalidate any play() still awaiting its hls.js import
  const host = el(PLAYER_HOST_ID);
  teardownMedia(host);
  if (document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
  if (host) {
    host.innerHTML = "";
    host.classList.add("hidden");
    host.setAttribute("aria-hidden", "true");
  }
}

/** Whether the player overlay is currently open. */
export function isPlayerOpen(): boolean {
  return el(PLAYER_HOST_ID)?.classList.contains("hidden") === false;
}
