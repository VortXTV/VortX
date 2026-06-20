import { invoke } from "@tauri-apps/api/core";

// The desktop player sink. The detail page resolves a playable URL through the UNCHANGED
// prepareTorrent -> resolveUrl pipeline (detail.ts + server.ts + engine.ts) and hands it here; only
// this (url) => play step changed from the original webview `<video>` injection.
//
// PRIMARY PATH: mpv (libmpv) via the Rust `mpv_play` command (see src-tauri/src/player.rs). mpv is
// the same player the Apple apps use, so desktop gets the same broad-codec, DV-AWARE TONEMAPPING
// playback. Webview `<video>` could not reliably do HEVC/Dolby Vision; mpv (vo=gpu-next + libplacebo)
// reads the DV RPU and tonemaps for the display. NOTE: this is DV-aware tonemapping, NOT true DV
// passthrough to a DV-capable panel.
//
// FALLBACK PATH: a webview `<video controls autoplay>` for plain H.264/AAC. Used only when mpv is
// unavailable (binary not staged AND not on PATH, GPU init failure, etc.). The OS WebView handles
// baseline H.264/AAC fine; it is the unreliable codecs that motivated mpv.
//
// TORRENT GATE: this module never resolves URLs itself. A torrent only reaches `play()` as an already
// resolved `http://127.0.0.1:11470/<hash>/<idx>` URL, which resolveUrl produces ONLY after the
// embedded server is listening. The Rust `mpv_play` re-checks that gate as a backstop.

const MPV_HOST_ID = "player";

/** mpv player state from the Rust backend (`mpv_status`), shape mirrors player.rs's PlayerState. */
export interface MpvStatus {
  state: "playing" | "idle" | "failed";
  reason?: string;
}

// Whether the active playback is using the webview `<video>` fallback (so closePlayer knows to pause
// the element vs. stop mpv). Reset on every open/close.
let usingFallback = false;

function el(id: string): HTMLElement | null {
  return document.getElementById(id);
}

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string,
  );
}

/**
 * Play a resolved URL. Tries mpv first; on any failure (no mpv binary, IPC failure) it falls back to
 * the webview `<video>` element so plain H.264/AAC still plays. The host overlay always shows a Back
 * button; with mpv the video renders in mpv's embedded/own window, so the overlay is a thin chrome.
 */
export async function play(url: string): Promise<void> {
  const host = el(MPV_HOST_ID);
  if (!host) return;
  host.classList.remove("hidden");

  try {
    await invoke("mpv_play", { url });
    usingFallback = false;
    // mpv owns the video surface; the overlay just carries the Back control over/beside it.
    host.innerHTML = `<button class="back" data-action="close-player">‹ Back</button>`;
    return;
  } catch (err) {
    // mpv unavailable or failed to start: fall back to the webview player for baseline codecs.
    // eslint-disable-next-line no-console -- desktop diagnostic; surfaced once on the fallback path.
    console.warn("mpv playback failed, falling back to webview <video>:", err);
    playInWebview(host, url);
  }
}

/** The documented fallback: inject a webview `<video>` for plain H.264/AAC when mpv is unavailable. */
function playInWebview(host: HTMLElement, url: string): void {
  usingFallback = true;
  host.innerHTML = `
    <button class="back" data-action="close-player">‹ Back</button>
    <video class="video" controls autoplay src="${escapeHtml(url)}"></video>`;
  // Show a message instead of a black screen if the fallback element can't load/decode the source (dead
  // link, unsupported codec). Teardown clears the host via innerHTML, which detaches the element without
  // firing "error", so this does not misfire on close. Parity with the web player's error feedback.
  host.querySelector("video")?.addEventListener("error", () => {
    let note = host.querySelector<HTMLElement>(".player-error");
    if (!note) {
      note = document.createElement("p");
      note.className = "player-error";
      host.appendChild(note);
    }
    note.textContent = "This source could not be played. It may be offline or an unsupported format.";
  });
}

/** Tear down playback: stop mpv (if it was used) or pause the fallback `<video>`, then hide chrome. */
export async function close(): Promise<void> {
  const host = el(MPV_HOST_ID);
  if (host) {
    host.querySelector("video")?.pause();
    host.innerHTML = "";
    host.classList.add("hidden");
  }
  if (!usingFallback) {
    try {
      await invoke("mpv_stop");
    } catch {
      // Best-effort teardown; a failed stop still hides the UI. The app-exit hook also kills mpv.
    }
  }
  usingFallback = false;
}

/** Pause / resume mpv (no-op for the fallback, whose `<video controls>` handles its own transport). */
export async function setPaused(paused: boolean): Promise<void> {
  if (usingFallback) return;
  await mpvCommand(["set_property", "pause", paused]);
}

/** Seek by `seconds` relative to the current position (negative rewinds). mpv path only. */
export async function seekRelative(seconds: number): Promise<void> {
  if (usingFallback) return;
  await mpvCommand(["seek", seconds, "relative"]);
}

/** The backend player state, for an error/empty UI when mpv failed to start. */
export async function status(): Promise<MpvStatus> {
  return invoke<MpvStatus>("mpv_status");
}

/**
 * Forward a raw mpv JSON IPC command (e.g. `["set_property","pause",true]`). Best-effort: a failure
 * (no player running) is swallowed so transport UI never throws. Exposed for future controls.
 */
async function mpvCommand(command: (string | number | boolean)[]): Promise<void> {
  try {
    await invoke("mpv_command", { command: { command } });
  } catch {
    // No player running or IPC hiccup; transport controls stay best-effort.
  }
}
