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
let wiredHost: HTMLElement | null = null;

function render(host: HTMLElement, title: string, hasNextEpisode: boolean): void {
  host.innerHTML = `
    <button class="player-close" data-native-action="close" aria-label="Back" aria-keyshortcuts="Escape" title="Back (Escape)">Back</button>
    <div class="player-title">${escapeHtml(title)}</div>
    <div class="native-transport">
      <button data-native-action="back10" aria-label="Back ${SEEK_STEP_SECONDS} seconds" aria-keyshortcuts="ArrowLeft J" title="Back ${SEEK_STEP_SECONDS} seconds (Left Arrow/J)">-${SEEK_STEP_SECONDS}s</button>
      <button data-native-action="pause" aria-label="Pause" aria-keyshortcuts="Space K" title="Play/pause (Space/K)">Pause</button>
      <button data-native-action="fwd10" aria-label="Forward ${SEEK_STEP_SECONDS} seconds" aria-keyshortcuts="ArrowRight L" title="Forward ${SEEK_STEP_SECONDS} seconds (Right Arrow/L)">+${SEEK_STEP_SECONDS}s</button>
      ${hasNextEpisode ? `<button data-native-action="next" aria-label="Next episode" aria-keyshortcuts="N" title="Next episode (N)">Next episode</button>` : ""}
    </div>
    <p class="player-error" data-native-status></p>`;
}

function setStatus(host: HTMLElement, text: string): void {
  const node = host.querySelector<HTMLElement>("[data-native-status]");
  if (node) node.textContent = text;
}

function removeKeyHandler(): void {
  if (keyHandler) document.removeEventListener("keydown", keyHandler, true);
  keyHandler = null;
}

function teardown(): void {
  unlisten?.();
  unlisten = null;
  if (statusTimer !== null) clearInterval(statusTimer);
  statusTimer = null;
  removeKeyHandler();
  if (wiredHost) wiredHost.onclick = null;
  wiredHost = null;
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
    button.setAttribute("aria-label", `${paused ? "Play" : "Pause"} (Space/K)`);
  }
}

function isTypingTarget(target: EventTarget | null): boolean {
  return target instanceof HTMLElement &&
    (target.isContentEditable || (typeof target.matches === "function" && target.matches("textarea, select, input:not([type=range]), [role=textbox]")));
}

function isNativeControlTarget(target: EventTarget | null): boolean {
  return target instanceof HTMLElement && typeof target.matches === "function" &&
    target.matches("button, a, [role=button], input[type=range]");
}

function keyboardShortcutKey(event: KeyboardEvent): string {
  if (event.key === " ") return "Space";
  if (typeof event.key === "string" && event.key.length === 1) return event.key.toLowerCase();
  return event.code;
}

function wireControls(host: HTMLElement, mine: number, onNextEpisode?: () => void): void {
  wiredHost = host;
  host.onclick = (event) => {
    if (mine !== session) return;
    const action = (event.target as HTMLElement | null)?.closest<HTMLElement>("[data-native-action]")?.dataset
      .nativeAction;
    if (action === "close") void closeNative();
    else if (action === "pause") void togglePause(host);
    else if (action === "back10") void seekNative(-SEEK_STEP_SECONDS);
    else if (action === "fwd10") void seekNative(SEEK_STEP_SECONDS);
    else if (action === "next") onNextEpisode?.();
  };
  keyHandler = (event: KeyboardEvent) => {
    if (mine !== session || event.defaultPrevented || event.isComposing || event.altKey || event.ctrlKey ||
        event.metaKey || event.shiftKey) return;
    const shortcut = keyboardShortcutKey(event);
    const isEscape = shortcut === "Escape";
    if (isTypingTarget(event.target)) {
      // Keep a text field's Escape local; the app-level document listener would otherwise close the player.
      if (isEscape) event.stopImmediatePropagation();
      return;
    }
    if (!isEscape && isNativeControlTarget(event.target)) return;
    const discrete = new Set(["Space", "k", "KeyK", "n", "KeyN"]);
    if (event.repeat && discrete.has(shortcut)) return;
    let handled = true;
    switch (shortcut) {
      case "Escape":
        event.stopImmediatePropagation();
        void closeNative();
        break;
      case "Space":
      case "k":
      case "KeyK":
        void togglePause(host);
        break;
      case "ArrowLeft":
      case "j":
      case "KeyJ":
        void seekNative(-SEEK_STEP_SECONDS);
        break;
      case "ArrowRight":
      case "l":
      case "KeyL":
        void seekNative(SEEK_STEP_SECONDS);
        break;
      case "n":
      case "KeyN":
        if (onNextEpisode) onNextEpisode();
        else handled = false;
        break;
      default:
        handled = false;
    }
    if (handled) event.preventDefault();
  };
  // Capture prevents the app-level Escape listener from closing the player a second time. Returning early
  // for focused native controls still lets their own browser activation and keyboard behavior proceed.
  document.addEventListener("keydown", keyHandler, true);
}

/** Play a torrent stream in native mpv inside the desktop shell. */
export async function playNative(stream: Stream, title: string, options: NativePlayOptions = {}): Promise<void> {
  teardown();
  const mine = ++session;
  const host = el("player");
  if (!host) return;
  render(host, title, !!options.onNextEpisode);
  host.classList.remove("hidden");
  host.setAttribute("aria-hidden", "false");
  setStatus(host, "Starting…");
  wireControls(host, mine, options.onNextEpisode);

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
    // The overlay remains so Back still works, but a failed Windows/native start must not leave a
    // document-level shortcut handler claiming keys after the typed mpv command was rejected.
    removeKeyHandler();
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
