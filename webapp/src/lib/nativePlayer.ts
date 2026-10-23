import { el, escapeHtml } from "./dom";
import { captureProgressAdmission, cwPosition, recordProgress } from "./store";
import {
  nativeStatus,
  onNativeProgress,
  playTorrent,
  seekNative,
  setNativePaused,
  stopTorrent,
  type NativeProgress,
} from "./desktop";
import type { Stream } from "./types";

// The desktop shell's native player chrome. mpv draws the video; this overlay (the same #player host the
// in-page player uses) carries Back, pause/resume, seek and a status line, and records Continue Watching
// progress from the shell's position reports with the same rules as the in-page player.

interface NativeItem {
  id: string;
  type: string;
  name: string;
  poster?: string;
  resumeId?: string;
}

export interface NativePlayOptions {
  item?: NativeItem;
  onNextEpisode?: () => void;
}

const SEEK_STEP_SECONDS = 10;
const STATUS_POLL_MS = 2000;
/** Passing this fraction counts as finished, matching the in-page player's Continue Watching rule. */
const FINISHED_FRACTION = 0.95;

let session = 0;
let paused = false;
let unlisten: (() => void) | null = null;
let statusTimer: ReturnType<typeof setInterval> | null = null;
let keyHandler: ((event: KeyboardEvent) => void) | null = null;

function render(host: HTMLElement, title: string): void {
  host.innerHTML = `
    <button class="player-close" data-native-action="close">Back</button>
    <div class="player-title">${escapeHtml(title)}</div>
    <div class="native-transport">
      <button data-native-action="back10" aria-label="Back ${SEEK_STEP_SECONDS} seconds">-${SEEK_STEP_SECONDS}s</button>
      <button data-native-action="pause" aria-label="Pause">Pause</button>
      <button data-native-action="fwd10" aria-label="Forward ${SEEK_STEP_SECONDS} seconds">+${SEEK_STEP_SECONDS}s</button>
    </div>
    <p class="player-error" data-native-status></p>`;
}

function setStatus(host: HTMLElement, text: string): void {
  const node = host.querySelector<HTMLElement>("[data-native-status]");
  if (node) node.textContent = text;
}

function teardown(): void {
  unlisten?.();
  unlisten = null;
  if (statusTimer !== null) clearInterval(statusTimer);
  statusTimer = null;
  if (keyHandler) document.removeEventListener("keydown", keyHandler);
  keyHandler = null;
  paused = false;
}

/** End the native session without touching the overlay, for the in-page player taking over the same host.
 *  Synchronous so the caller stays inside the click's user-activation window. */
export function releaseNative(): void {
  ++session;
  teardown();
  void stopTorrent();
}

/** Close the native session and hide the overlay. */
export async function closeNative(): Promise<void> {
  ++session;
  teardown();
  await stopTorrent();
  const host = el("player");
  if (!host) return;
  host.innerHTML = "";
  host.classList.add("hidden");
  host.setAttribute("aria-hidden", "true");
}

async function togglePause(host: HTMLElement): Promise<void> {
  paused = !paused;
  await setNativePaused(paused);
  const button = host.querySelector<HTMLButtonElement>('[data-native-action="pause"]');
  if (button) {
    button.textContent = paused ? "Play" : "Pause";
    button.setAttribute("aria-label", paused ? "Play" : "Pause");
  }
}

function wireControls(host: HTMLElement, mine: number): void {
  host.onclick = (event) => {
    if (mine !== session) return;
    const action = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-native-action]")?.dataset
      .nativeAction;
    if (action === "close") void closeNative();
    else if (action === "pause") void togglePause(host);
    else if (action === "back10") void seekNative(-SEEK_STEP_SECONDS);
    else if (action === "fwd10") void seekNative(SEEK_STEP_SECONDS);
  };
  keyHandler = (event: KeyboardEvent) => {
    if (mine !== session) return;
    if (event.key === "Escape") void closeNative();
    else if (event.key === " ") void togglePause(host);
    else if (event.key === "ArrowLeft") void seekNative(-SEEK_STEP_SECONDS);
    else if (event.key === "ArrowRight") void seekNative(SEEK_STEP_SECONDS);
    else return;
    event.preventDefault();
  };
  document.addEventListener("keydown", keyHandler);
}

/** Play a torrent stream in native mpv inside the desktop shell. */
export async function playNative(stream: Stream, title: string, options: NativePlayOptions = {}): Promise<void> {
  teardown();
  const mine = ++session;
  const host = el("player");
  if (!host) return;
  render(host, title);
  host.classList.remove("hidden");
  host.setAttribute("aria-hidden", "false");
  setStatus(host, "Starting…");
  wireControls(host, mine);

  const item = options.item;
  const admitted = captureProgressAdmission();
  const resume = item ? cwPosition(item.resumeId ?? item.id) : 0;
  let started = false;
  try {
    started = await playTorrent(stream, resume > 5 ? resume : 0);
  } catch {
    started = false;
  }
  if (mine !== session) return;
  if (!started) {
    setStatus(host, "This source could not be played. It may have no peers right now.");
    return;
  }
  setStatus(host, "");

  let last: NativeProgress | null = null;
  const stopListening = await onNativeProgress((progress) => {
    if (mine !== session || progress.durationMs <= 0) return;
    last = progress;
    if (item) recordProgress(item, progress.positionMs / 1000, progress.durationMs / 1000, admitted);
  });
  if (mine !== session) {
    stopListening();
    return;
  }
  unlisten = stopListening;

  statusTimer = setInterval(() => {
    void nativeStatus()
      .then((status) => {
        if (mine !== session || status.state === "playing") return;
        const progress = last as NativeProgress | null;
        const finished =
          !!progress && progress.durationMs > 0 && progress.positionMs / progress.durationMs >= FINISHED_FRACTION;
        if (status.state === "failed") {
          setStatus(host, "Playback stopped unexpectedly.");
          teardown();
          return;
        }
        if (item && finished && progress) {
          recordProgress(item, progress.durationMs / 1000, progress.durationMs / 1000, admitted);
        }
        void closeNative().then(() => {
          if (finished) options.onNextEpisode?.();
        });
      })
      .catch(() => undefined);
  }, STATUS_POLL_MS);
}
