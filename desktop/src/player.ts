import { invoke } from "@tauri-apps/api/core";

import { icon } from "./icons";

// The desktop player sink. The detail page resolves a playable URL through the UNCHANGED
// prepareTorrent -> resolveUrl pipeline (detail.ts + server.ts + engine.ts) and hands it here; only
// this (url) => play step changed from the original webview `<video>` injection.
//
// NATIVE PATH: mpv (libmpv) via the Rust `mpv_play` command (see src-tauri/src/player.rs) is
// currently restricted to the exact numeric 127.0.0.1 streaming route. The staged cross-platform
// mpv runtime has not yet passed the certificate/backend artifact audit required for remote HTTPS.
//
// REMOTE/FALLBACK PATH: the OS webview `<video controls autoplay>` keeps its platform TLS verifier.
// It handles baseline H.264/AAC; broader remote codecs remain unavailable until the bundled mpv
// runtime is independently attested.
//
// TORRENT GATE: this module never resolves URLs itself. A torrent only reaches `play()` as an already
// resolved `http://127.0.0.1:11470/<hash>/<idx>` URL, which resolveUrl produces ONLY after the
// embedded server is listening. The Rust `mpv_play` re-checks that gate as a backstop.

const MPV_HOST_ID = "player";
const LOOPBACK_TORRENT_URL =
  /^http:\/\/127\.0\.0\.1:11470\/([0-9a-f]{40})\/([0-9]+)$/i;
const MAX_U32 = 0xffff_ffffn;

/** mpv player state from the Rust backend (`mpv_status`), shape mirrors player.rs's PlayerState. */
export interface MpvStatus {
  state: "playing" | "idle" | "failed";
  reason?: string;
}

type PlaybackTarget =
  | { kind: "loopback"; url: string }
  | { kind: "remote"; url: string };

interface PlaybackSession {
  generation: number;
  kind: "native" | "webview";
}

// Play and close share one ordered lane. Incrementing the generation when a request is made (rather
// than when it starts running) immediately revokes an older request's right to install a fallback
// after one of its awaited native commands completes.
let requestedGeneration = 0;
let operationTail: Promise<void> = Promise.resolve();
let activeSession: PlaybackSession | null = null;

function el(id: string): HTMLElement | null {
  return document.getElementById(id);
}

function classifyPlaybackUrl(value: string): PlaybackTarget | null {
  if (typeof value !== "string" || !value || value !== value.trim()) return null;

  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return null;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;

  const hostname = parsed.hostname.toLowerCase();
  if (hostname === "127.0.0.1") {
    const match = LOOPBACK_TORRENT_URL.exec(value);
    if (!match || BigInt(match[2]) > MAX_U32) return null;
    return { kind: "loopback", url: parsed.href };
  }

  // Other literal/standard loopback forms are local too, but none belong to the VortX server route.
  if (
    hostname === "0.0.0.0" ||
    hostname === "::1" ||
    hostname === "[::]" ||
    hostname === "[::1]" ||
    hostname === "localhost" ||
    hostname === "localhost." ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".localhost.") ||
    /^\[::(?:ffff:)?7f[0-9a-f]{2}:[0-9a-f]{1,4}\]$/.test(hostname) ||
    /^127(?:\.\d{1,3}){3}$/.test(hostname)
  ) {
    return null;
  }

  return { kind: "remote", url: parsed.href };
}

function queueOperation(operation: () => Promise<void>): Promise<void> {
  const pending = operationTail.then(operation, operation);
  operationTail = pending.catch(() => undefined);
  return pending;
}

function ownsGeneration(generation: number): boolean {
  return requestedGeneration === generation;
}

function ownsSession(generation: number, kind: PlaybackSession["kind"]): boolean {
  return (
    ownsGeneration(generation) &&
    activeSession?.generation === generation &&
    activeSession.kind === kind
  );
}

async function stopNativePlayback(): Promise<boolean> {
  try {
    await invoke("mpv_stop");
    return true;
  } catch (err) {
    // eslint-disable-next-line no-console -- a failed stop must be visible before fallback is withheld.
    console.warn("Could not stop native playback:", err);
    return false;
  }
}

function clearHost(host: HTMLElement | null): void {
  if (!host) return;
  host.querySelector("video")?.pause();
  host.innerHTML = "";
  host.classList.add("hidden");
}

async function embeddedServerIsListening(): Promise<boolean> {
  try {
    // This authenticated Tauri command, not content-controlled webview state, is the required
    // authority for local fallback.
    return (await invoke<unknown>("server_is_listening")) === true;
  } catch {
    return false;
  }
}

/**
 * Play a validated URL. Exact loopback server URLs may use mpv, with an authenticated liveness gate
 * before local webview fallback. Remote HTTP(S) intentionally uses the platform-verified webview.
 */
export function play(url: string): Promise<void> {
  const generation = ++requestedGeneration;
  const target = classifyPlaybackUrl(url);
  return queueOperation(() => playRequest(target, generation));
}

async function playRequest(target: PlaybackTarget | null, generation: number): Promise<void> {
  // Every request takes over the single-player slot. Stop first even for invalid/stale requests so a
  // previous native child cannot survive behind later UI.
  const nativeStopped = await stopNativePlayback();
  const host = el(MPV_HOST_ID);
  activeSession = null;
  clearHost(host);

  if (!ownsGeneration(generation) || !host) return;
  if (!target) {
    // eslint-disable-next-line no-console -- invalid media input is rejected before reaching a sink.
    console.warn("Refusing to play an invalid or disallowed media URL.");
    return;
  }

  if (target.kind === "remote") {
    // Do not create a competing webview player when native teardown could not be confirmed.
    if (nativeStopped) playInWebview(host, target.url, generation);
    return;
  }

  try {
    await invoke("mpv_play", { url: target.url });
    if (!ownsGeneration(generation)) {
      await stopNativePlayback();
      return;
    }
    activeSession = { generation, kind: "native" };
    host.classList.remove("hidden");
    // mpv owns the video surface; the overlay just carries the Back control over/beside it.
    host.innerHTML = `<button class="back" data-action="close-player">${icon("back")}<span>Back</span></button>`;
    return;
  } catch (err) {
    // mpv may have spawned before failing. Confirm it is stopped before considering any fallback.
    const fallbackStopped = await stopNativePlayback();
    if (!ownsGeneration(generation) || !fallbackStopped) return;
    if (!(await embeddedServerIsListening()) || !ownsGeneration(generation)) return;

    // eslint-disable-next-line no-console -- desktop diagnostic; surfaced once on the fallback path.
    console.warn("mpv playback failed, falling back to webview <video>:", err);
    playInWebview(host, target.url, generation);
  }
}

/** The documented fallback: inject a webview `<video>` for plain H.264/AAC when mpv is unavailable. */
function playInWebview(host: HTMLElement, url: string, generation: number): void {
  if (!ownsGeneration(generation)) return;

  host.classList.remove("hidden");
  host.innerHTML = `
    <button class="back" data-action="close-player">${icon("back")}<span>Back</span></button>
    <video class="video" controls autoplay></video>`;
  const video = host.querySelector<HTMLVideoElement>("video");
  if (!video) return;

  activeSession = { generation, kind: "webview" };
  // Show a message instead of a black screen if the fallback element can't load/decode the source (dead
  // link, unsupported codec). Session ownership keeps a late error from an old detached video from
  // mutating the next player's host.
  video.addEventListener("error", () => {
    if (!ownsSession(generation, "webview") || host.querySelector("video") !== video) return;
    let note = host.querySelector<HTMLElement>(".player-error");
    if (!note) {
      note = document.createElement("p");
      note.className = "player-error";
      host.appendChild(note);
    }
    note.textContent = "This source could not be played. It may be offline or an unsupported format.";
  });
  video.src = url;
}

/** Tear down playback in the same serialized ownership lane as play requests. */
export function close(): Promise<void> {
  const generation = ++requestedGeneration;
  return queueOperation(() => closeRequest(generation));
}

async function closeRequest(_generation: number): Promise<void> {
  // Always issue native stop before pausing/clearing the fallback or hiding player chrome.
  await stopNativePlayback();
  const host = el(MPV_HOST_ID);
  activeSession = null;
  clearHost(host);
}

/** Pause / resume mpv (no-op for the fallback, whose `<video controls>` handles its own transport). */
export async function setPaused(paused: boolean): Promise<void> {
  const session = activeSession;
  if (session?.kind !== "native" || !ownsGeneration(session.generation)) return;
  try {
    await invoke("mpv_set_paused", { paused });
  } catch {
    // No player running or IPC hiccup; transport controls stay best-effort.
  }
}

/** Seek by `seconds` relative to the current position (negative rewinds). mpv path only. */
export async function seekRelative(seconds: number): Promise<void> {
  const session = activeSession;
  if (session?.kind !== "native" || !ownsGeneration(session.generation)) return;
  try {
    await invoke("mpv_seek_relative", { seconds });
  } catch {
    // No player running, invalid offset, or IPC hiccup; transport remains best-effort.
  }
}

/** The backend player state, for an error/empty UI when mpv failed to start. */
export async function status(): Promise<MpvStatus> {
  return invoke<MpvStatus>("mpv_status");
}
