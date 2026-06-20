import type Hls from "hls.js";
import type { ErrorData } from "hls.js";
import { el, escapeHtml } from "./dom";
import { cwPosition, recordProgress } from "./store";

/** The slim title context the player needs to record Continue Watching progress. */
interface CWItem {
  id: string;
  type: string;
  name: string;
  poster?: string;
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

/** Whether a url looks like an HLS playlist. */
function isHls(url: string): boolean {
  return HLS_EXT.test(url);
}

/** The chrome that wraps the <video>: a Back button, a centered title, and the video itself. */
function chrome(title: string): string {
  return `
    <button class="player-close" data-action="close-player" aria-label="Close player">‹ Back</button>
    <div class="player-title" aria-hidden="true">${escapeHtml(title)}</div>
    <video class="player-video" id="player-video" controls autoplay playsinline
           crossorigin="anonymous"></video>`;
}

/** Open the player overlay and play `url`. `title` is shown as thin chrome over the transport. */
export async function play(url: string, title: string, item?: CWItem): Promise<void> {
  const host = el(PLAYER_HOST_ID);
  if (!host) return;
  host.classList.remove("hidden");
  host.setAttribute("aria-hidden", "false");
  host.innerHTML = chrome(title);

  const video = el<HTMLVideoElement>("player-video");
  if (!video) return;
  if (item) wireProgress(video, item);
  wireKeyboard(video);

  // Native HLS (Safari / iOS) or any non-HLS url: hand the url straight to the element.
  if (!isHls(url) || video.canPlayType("application/vnd.apple.mpegurl")) {
    video.src = url;
    void video.play().catch(() => {
      /* autoplay can be blocked; the visible controls let the user start it */
    });
    return;
  }

  // HLS via Media Source Extensions: load hls.js on demand.
  const mod = await import("hls.js");
  const HlsCtor = mod.default;
  if (HlsCtor.isSupported()) {
    hls = new HlsCtor({ enableWorker: true, lowLatencyMode: false });
    hls.loadSource(url);
    hls.attachMedia(video);
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

  // No MSE and not native HLS: last-resort direct assignment (some browsers can still manage).
  video.src = url;
  void video.play().catch(() => undefined);
}

/** Record Continue Watching progress for `item` while it plays, and resume from the saved position.
 *  Throttled to once every 5s; passing 95% drops it from Continue Watching (treated as finished). */
function wireProgress(video: HTMLVideoElement, item: CWItem): void {
  video.addEventListener(
    "loadedmetadata",
    () => {
      const pos = cwPosition(item.id);
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
}

/** Global keyboard shortcuts while the player overlay is open (the native <video> controls only respond
 *  when the element is focused): Space play/pause, Left/Right seek 10s, Up/Down volume, M mute, F fullscreen.
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
        video.currentTime = Math.max(0, video.currentTime - 10);
        break;
      case "ArrowRight":
        video.currentTime = Math.min(video.duration || Infinity, video.currentTime + 10);
        break;
      case "ArrowUp":
        video.volume = Math.min(1, video.volume + 0.1);
        break;
      case "ArrowDown":
        video.volume = Math.max(0, video.volume - 0.1);
        break;
      case "KeyM":
        video.muted = !video.muted;
        break;
      case "KeyF":
        if (document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
        else void video.requestFullscreen().catch(() => undefined);
        break;
      default:
        handled = false;
    }
    if (handled) e.preventDefault();
  };
  document.addEventListener("keydown", keyHandler);
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
  const host = el(PLAYER_HOST_ID);
  if (keyHandler) {
    document.removeEventListener("keydown", keyHandler);
    keyHandler = null;
  }
  if (hls) {
    hls.destroy();
    hls = null;
  }
  if (host) {
    const video = host.querySelector<HTMLVideoElement>("video");
    if (video) {
      video.pause();
      video.removeAttribute("src");
      video.load();
    }
    host.innerHTML = "";
    host.classList.add("hidden");
    host.setAttribute("aria-hidden", "true");
  }
}

/** Whether the player overlay is currently open. */
export function isPlayerOpen(): boolean {
  return el(PLAYER_HOST_ID)?.classList.contains("hidden") === false;
}
