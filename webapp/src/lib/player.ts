import type Hls from "hls.js";
import type { ErrorData } from "hls.js";
import { el } from "./dom";
import { cwPosition, recordProgress } from "./store";
import { getSettings } from "./settings";
import type { SubtitleTrack } from "./addon";
import { mountControls, type PlayerController, type SkipSegment } from "./playerControls";

/** The slim title context the player needs to record Continue Watching progress. */
interface CWItem {
  id: string;
  type: string;
  name: string;
  poster?: string;
  /** The actual played id (episode id for a series); the resume position is keyed by this, not `id`. */
  resumeId?: string;
}

/** Everything the player needs beyond the media url, so the Detail surface can drive full-app playback:
 *  Continue Watching, subtitles, an ordered source-fallback chain (auto-advance on a decode/silent-audio
 *  failure), the intro/outro skip segments, and a next-episode hook. All optional so `play(url, title)`
 *  still works for simple callers. */
export interface PlayOptions {
  item?: CWItem;
  subtitles?: Promise<SubtitleTrack[]>;
  /** Best-first alternative sources (from streamRanking.playbackFallbacks) to auto-advance to when the
   *  current source fails to decode or plays silently. Includes the current url as its first entry. */
  fallbacks?: string[];
  /** Intro / outro segments (seconds) that render a "Skip Intro" / "Skip Outro" button while inside them. */
  skipSegments?: SkipSegment[];
  /** Play the next episode; when present the player shows a "Next Episode" affordance (and auto-advances
   *  near the end for a series). Undefined for movies / the last episode. */
  onNextEpisode?: () => void;
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
// The one-shot unmute listeners wired on the PERSISTENT #player host (see wireMobileAudio). They self-remove
// via { once: true } only if the user interacts before teardown; otherwise teardownMedia must remove them so
// they don't accumulate (and hold a stale controller closure) across every play()/advanceSource().
let audioGesture: ((e: Event) => void) | null = null;
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
  // Remove the one-shot unmute listeners from the persistent host if the user never triggered them (their
  // { once: true } only fires on interaction); otherwise they'd stack up and pin the old session's controller.
  if (audioGesture && host) {
    host.removeEventListener("pointerdown", audioGesture, { capture: true });
    host.removeEventListener("keydown", audioGesture, { capture: true });
    audioGesture = null;
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

// The current session's ordered fallback urls + the index we're playing, so a decode/silent-audio failure
// can advance to the next source in place (see maybeAdvance). Reset on every play()/close().
let sessionFallbacks: string[] = [];
let sessionIndex = 0;
let sessionTitle = "";
let sessionOptions: PlayOptions = {};
// Per-source generation, bumped every time we mount a new source (play + each advanceSource). Error/silent
// handlers capture the generation of the source they were wired to and refuse to advance once it is stale,
// so a late fatal error queued against an already-superseded source can't chain-advance past the good source
// that replaced it (which would drop a source the user is now watching). playToken alone can't guard this:
// advanceSource stays within one session and deliberately does NOT bump it.
let sourceGen = 0;

/** Open the player overlay and play `url`. `title` is shown as thin chrome over the transport. `opts` adds
 *  Continue Watching, subtitles, a source-fallback chain (D6 auto-advance on undecodable audio), skip
 *  segments, and a next-episode hook (D7 full player chrome). */
export async function play(url: string, title: string, opts: PlayOptions = {}): Promise<void> {
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

  // Session state for the fallback chain: `url` is always the entry we start on. If a fallback list was
  // passed, find `url` in it so a later decode failure advances from the right place; otherwise the chain
  // is just this single url.
  sessionTitle = title;
  sessionOptions = opts;
  sessionFallbacks = opts.fallbacks && opts.fallbacks.length ? opts.fallbacks.slice() : [url];
  const startAt = sessionFallbacks.indexOf(url);
  sessionIndex = startAt >= 0 ? startAt : 0;

  await mountAndLoad(host, video(host), url, title, opts, myToken);
}

/** Build the <video> element for a fresh session and layer the control chrome on it. Separated from the
 *  load path so an auto-advance can rebuild media on the SAME <video> without re-creating the chrome. */
function video(host: HTMLElement): HTMLVideoElement {
  const v = document.createElement("video");
  v.className = "player-video";
  v.id = "player-video";
  v.autoplay = true;
  v.playsInline = true;
  // iOS Safari also reads the lowercase attribute; set both so inline playback (not the native fullscreen
  // takeover) is honored on every mobile engine - a prerequisite for our own chrome to be visible at all.
  v.setAttribute("playsinline", "");
  v.setAttribute("webkit-playsinline", "");
  // Do NOT force crossOrigin="anonymous" on the media element: it puts every media fetch in CORS mode, so a
  // debrid/CDN host (or a signed 302 redirect) that omits Access-Control-Allow-Origin FAILS to load - a
  // prime cause of "doesn't play on mobile" (mobile enforces this on redirected media more strictly). It was
  // newly added in the 6166c57 player rewrite; the pre-rewrite player worked without it. The Save-frame
  // snapshot loses the ability to read a CROSS-ORIGIN frame, but its handler already try/catches the
  // resulting tainted-canvas SecurityError, so it degrades cleanly - an acceptable trade for playback.
  host.appendChild(v);
  return v;
}

/** Attach source + chrome + all listeners for one source. Called by play() and by advanceSource(). */
async function mountAndLoad(
  host: HTMLElement,
  vid: HTMLVideoElement,
  url: string,
  title: string,
  opts: PlayOptions,
  myToken: number,
): Promise<void> {
  // This source's generation: an error/silent handler wired below may fire late (after we've already advanced
  // to a newer source); it must ignore its advance request once its generation is stale so it can't skip past
  // the source now playing. See sourceGen.
  const myGen = ++sourceGen;
  const hasNext = sessionIndex < sessionFallbacks.length - 1;
  controller = mountControls(host, vid, {
    title,
    skipStep: getSettings().skipStep,
    skipSegments: opts.skipSegments ?? [],
    hasNextEpisode: !!opts.onNextEpisode,
    onNextEpisode: opts.onNextEpisode,
    onTryNextSource: hasNext ? () => advanceSource(host, "manual") : undefined,
  });

  if (opts.item) wireProgress(vid, opts.item);
  wireKeyboard(vid);
  wireMobileAudio(vid);
  wireAudioFailure(host, vid, myGen);
  // Surface a clear message when the element fails to load or decode (an expired debrid link, a 404, an
  // unsupported codec). Prefer auto-advancing to the next source; only show the terminal message when the
  // chain is exhausted. The hls.js path has its own fatal-error handler.
  vid.addEventListener("error", () => {
    if (myGen !== sourceGen) return; // a newer source already replaced this one; ignore the stale error
    if (!advanceSource(host, "decode"))
      showError(host, "This source could not be played. It may be offline or an unsupported format. Try another source.");
  });
  // Subtitles: non-blocking, gated on the session token so a list that resolves after close / a new source
  // does not attach tracks to a dead session.
  if (opts.subtitles) {
    void opts.subtitles
      .then((subs) => {
        if (myToken !== playToken) return;
        return addSubtitleTracks(vid, subs);
      })
      .then(() => {
        if (myToken === playToken) controller?.refreshSubtitles();
      })
      .catch(() => undefined);
  }

  // Direct sources (mp4 / mkv / debrid links): hand the url straight to the element.
  if (!isHls(url)) {
    controller.setHls(null);
    vid.src = url;
    startPlayback(vid);
    return;
  }

  // HLS. Prefer hls.js wherever it is supported, because it powers the custom Quality / Audio-track /
  // Subtitle menus. Safari / iOS defer to native HLS (more reliable, notably for fMP4).
  const ua = navigator.userAgent;
  const preferNative =
    (/iP(ad|hone|od)/.test(ua) || /^((?!chrome|android|crios|fxios).)*safari/i.test(ua)) &&
    !!vid.canPlayType("application/vnd.apple.mpegurl");
  if (!preferNative) {
    const mod = await import("hls.js");
    if (myToken !== playToken) return; // closed / new source while hls.js was loading
    const HlsCtor = mod.default;
    if (HlsCtor.isSupported()) {
      hls = new HlsCtor({ enableWorker: true, lowLatencyMode: false });
      hls.loadSource(url);
      hls.attachMedia(vid);
      controller.setHls(hls); // wire the Quality + Audio-track menus from the hls levels
      hls.on(HlsCtor.Events.MEDIA_ATTACHED, () => startPlayback(vid));
      hls.on(HlsCtor.Events.ERROR, (_evt: unknown, data: ErrorData) => {
        if (!data.fatal) return;
        switch (data.type) {
          case mod.ErrorTypes.NETWORK_ERROR:
            hls?.startLoad();
            break;
          case mod.ErrorTypes.MEDIA_ERROR:
            hls?.recoverMediaError();
            break;
          default:
            if (myGen !== sourceGen) break; // superseded by a newer source; ignore this stale fatal error
            if (!advanceSource(host, "decode")) showError(host, "This stream could not be played. Try another source.");
            break;
        }
      });
      return;
    }
  }

  // Native HLS (Safari / iOS, or hls.js unsupported): hand the playlist straight to the element.
  controller.setHls(null);
  vid.src = url;
  startPlayback(vid);
}

/** Start playback, honoring browser autoplay policy. A muted <video> autoplays everywhere; an UNMUTED one
 *  is blocked on mobile without a prior user gesture. We attempt UNMUTED first (so audio just works when the
 *  gesture from tapping "Watch" still counts), and only on a rejected play() do we mute + retry so at least
 *  the video moves, then flag the chrome to show a one-tap "Tap to unmute" affordance. wireMobileAudio()
 *  restores the real volume on that tap. This is half (a) of D6: video-but-no-audio from a muted autoplay. */
function startPlayback(vid: HTMLVideoElement): void {
  const wasMuted = vid.muted;
  vid.play().catch(() => {
    // Autoplay with audio was blocked. Mute and retry so the picture starts; mark that we auto-muted so the
    // unmute affordance appears and a later user gesture can restore sound.
    if (wasMuted) return; // already muted by the user's saved preference; nothing to recover
    vid.muted = true;
    controller?.setAutoMuted(true);
    vid.play().catch(() => {
      /* even muted autoplay blocked; the visible Play button lets the user start it */
    });
  });
}

/** D6 (a): once the media is actually playing, unmute on the FIRST user interaction (pointer/key anywhere in
 *  the player) if we had to auto-mute for autoplay, restoring the remembered volume. iOS Safari + Android
 *  Chrome both count a tap on the overlay as the activating gesture, so audio comes back on the first touch. */
function wireMobileAudio(vid: HTMLVideoElement): void {
  const unmute = () => {
    if (!vid.muted) return;
    // Only auto-restore if WE muted for autoplay; never override an explicit user mute (setAutoMuted tracks
    // that in the controller, which owns the volume UI + persistence).
    if (controller?.consumeAutoMuted()) {
      vid.muted = false;
      if (vid.volume === 0) vid.volume = 1;
    }
  };
  // Capture-phase, one-shot: the first pointer or key anywhere in the player counts as the user gesture.
  // Bound to the PERSISTENT #player host, so teardownMedia removes them (via the stored audioGesture ref)
  // when the session ends without a prior interaction - otherwise they'd leak across sessions.
  const host = el(PLAYER_HOST_ID);
  audioGesture = unmute;
  host?.addEventListener("pointerdown", unmute, { capture: true, once: true });
  host?.addEventListener("keydown", unmute, { capture: true, once: true });
}

/** D6 (b): watch for a source that PLAYS but produces no decodable audio (the AC3/E-AC3/DTS/TrueHD case a
 *  browser can't decode: the picture moves but there is silence). When the element reports zero audio tracks
 *  shortly after playback starts, auto-advance to the next fallback source. The check is deferred a moment
 *  after `playing` so a still-initializing pipeline isn't misread as silent. */
function wireAudioFailure(host: HTMLElement, vid: HTMLVideoElement, gen: number): void {
  let checked = false;
  const check = () => {
    if (checked) return;
    checked = true;
    window.setTimeout(() => {
      // A newer source may have replaced this one while the 2.5s deferral was pending; don't judge (or
      // advance past) a source that is no longer playing.
      if (gen !== sourceGen) return;
      // audioTracks is supported in Safari + Chromium; when present and empty, the browser found no audio it
      // can render. Guard on readyState so we only judge a source that has genuinely loaded media.
      const at = (vid as unknown as { audioTracks?: { length: number } }).audioTracks;
      if (vid.readyState >= 2 && at && at.length === 0) {
        advanceSource(host, "silent");
      }
    }, 2500);
  };
  vid.addEventListener("playing", check, { once: true });
}

/** Advance to the next source in the fallback chain, rebuilding media on a fresh <video> in place. Returns
 *  false (and does nothing) when the chain is exhausted, so the caller can show its terminal error. `reason`
 *  drives an honest toast so the user understands WHY the source changed. */
function advanceSource(host: HTMLElement, reason: "decode" | "silent" | "manual"): boolean {
  if (sessionIndex >= sessionFallbacks.length - 1) return false;
  sessionIndex += 1;
  const nextUrl = sessionFallbacks[sessionIndex];
  const myToken = playToken; // same session; we're not bumping the token, just swapping the source

  // Preserve the resume position across the swap so the new source picks up where the old one failed.
  const old = host.querySelector<HTMLVideoElement>("video");
  const resumeAt = old && isFinite(old.currentTime) ? old.currentTime : 0;

  // Tear down just the media (chrome/hls/subs/listeners), keep the overlay open, then rebuild on a new video.
  teardownMedia(host);
  subAbort = new AbortController();
  host.innerHTML = "";
  const vid = video(host);
  if (resumeAt > 1) {
    vid.addEventListener(
      "loadedmetadata",
      () => {
        if (isFinite(vid.duration) && resumeAt < vid.duration - 5) vid.currentTime = resumeAt;
      },
      { once: true },
    );
  }
  void mountAndLoad(host, vid, nextUrl, sessionTitle, sessionOptions, myToken).then(() => {
    if (reason === "silent")
      controller?.toast("This source's audio can't be decoded in the browser. Switched to another source.");
    else if (reason === "decode") controller?.toast("That source failed to play. Switched to another source.");
    else controller?.toast("Switched to another source.");
  });
  return true;
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
  video.addEventListener("ended", () => {
    recordProgress(item, video.duration, video.duration);
    // Auto-play the next episode of a series (the app's binge behavior), if the Detail surface supplied one.
    sessionOptions.onNextEpisode?.();
  });
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
      case "KeyN":
        // Next episode (series only; a no-op for movies / the last episode).
        if (sessionOptions.onNextEpisode) sessionOptions.onNextEpisode();
        else handled = false;
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
  sessionFallbacks = [];
  sessionIndex = 0;
  sessionOptions = {};
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
