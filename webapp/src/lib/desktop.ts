import type { Stream } from "./types";

// The VortX desktop shell bridge. The desktop app (Tauri) loads this same web client and adds the two
// things a browser cannot have: the VortX streaming server running in-process (so TORRENT sources play)
// and the native mpv player. In a plain browser nothing here is active: `isDesktop()` is false, torrents
// stay unplayable and every source keeps using the in-page player.
//
// SECURITY: mpv plays only the exact embedded-server torrent route, `http://127.0.0.1:<port>/<hash>/<idx>`.
// Direct/debrid HTTPS keeps the webview player and its platform TLS verifier. The Rust `mpv_play` command
// re-checks the same route as a backstop.

type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;
type Listen = <T>(event: string, handler: (event: { payload: T }) => void) => Promise<() => void>;

interface TauriGlobal {
  core?: { invoke?: Invoke };
  event?: { listen?: Listen };
}

function tauriGlobal(): TauriGlobal | undefined {
  return (globalThis as { __TAURI__?: TauriGlobal }).__TAURI__;
}

function tauriInvoke(): Invoke | null {
  const invoke = tauriGlobal()?.core?.invoke;
  return typeof invoke === "function" ? invoke : null;
}

/** True inside the VortX desktop shell. */
export function isDesktop(): boolean {
  return tauriInvoke() !== null;
}

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("not running in the VortX desktop app");
  return invoke<T>(command, args);
}

// ---- Embedded streaming server --------------------------------------------------------------------

const LOOPBACK_BASE = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})$/;
let serverBase: string | null = null;

/** Whether torrent playback is available now. Synchronous so stream filtering can use it. */
export function torrentsAvailable(): boolean {
  return serverBase !== null;
}

/** Ask the shell for the embedded server's loopback base URL; torrents unlock once it is known. */
export async function primeTorrentServer(): Promise<boolean> {
  if (!isDesktop()) return false;
  try {
    const base = await call<string>("server_base_url");
    const port = LOOPBACK_BASE.exec(base)?.[1];
    serverBase = port && Number(port) > 0 && Number(port) < 65536 ? base : null;
  } catch {
    serverBase = null;
  }
  return serverBase !== null;
}

// Public TCP/TLS trackers that work without UDP, the same list the Apple app injects, so a swarm can
// form when an add-on hands out only dead udp:// trackers.
const DEFAULT_TRACKERS: readonly string[] = [
  "tracker:https://tracker.alaskantf.com:443/announce",
  "tracker:https://tracker.bt4g.com:443/announce",
  "tracker:https://tracker.moeblog.cn:443/announce",
  "tracker:https://tracker.pmman.tech:443/announce",
  "tracker:https://tracker.zhuqiy.com:443/announce",
  "tracker:http://open.tracker.cl:1337/announce",
  "tracker:http://tracker.opentrackr.org:1337/announce",
  "tracker:http://tracker.files.fm:6969/announce",
];

/** The stream's own sources, DHT, the HTTP twin of every udp tracker, then the defaults, de-duped. */
export function trackerSources(hash: string, streamSources: readonly string[] | undefined): string[] {
  const own = [...(streamSources ?? [])];
  const twins = own
    .filter((entry) => entry.startsWith("tracker:udp://"))
    .map((entry) => entry.slice("tracker:udp://".length).split("/")[0])
    .filter((hostPort): hostPort is string => !!hostPort)
    .map((hostPort) => `tracker:http://${hostPort}/announce`);
  return Array.from(new Set([...own, `dht:${hash}`, ...twins, ...DEFAULT_TRACKERS]));
}

const INFO_HASH = /^[0-9a-f]{40}$/;
const MAX_FILE_INDEX = 0xffff_ffff;

/** The embedded server's file URL for a torrent stream, or null when it cannot be played here. */
export function torrentUrl(stream: Stream): string | null {
  if (stream.url || !stream.infoHash || serverBase === null) return null;
  const hash = stream.infoHash.toLowerCase();
  const index = stream.fileIdx ?? 0;
  if (!INFO_HASH.test(hash) || !Number.isInteger(index) || index < 0 || index > MAX_FILE_INDEX) return null;
  return `${serverBase}/${hash}/${index}`;
}

/** Start peer discovery with the injected trackers before playback. Best-effort: the file endpoint
 *  still finds peers without it, only more slowly. */
async function prepareTorrent(stream: Stream, hash: string): Promise<void> {
  try {
    await fetch(`${serverBase}/${hash}/create`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        torrent: { infoHash: hash },
        peerSearch: { sources: trackerSources(hash, stream.sources), min: 40, max: 150 },
      }),
    });
  } catch {
    // Discovery still starts from the file request.
  }
}

// ---- Native mpv sessions ----------------------------------------------------------------------------

/** mpv state reported by the shell (`mpv_status`). */
export interface MpvStatus {
  state: "playing" | "idle" | "failed";
  reason?: string;
}

// Play and stop share one ordered lane. The generation increments when a request is MADE, so a newer
// request revokes an older one's right to finish after any of its awaited native commands completes.
let requestedGeneration = 0;
let pendingGeneration: number | null = null;
let activeGeneration: number | null = null;
let lane: Promise<void> = Promise.resolve();

function queue(operation: () => Promise<void>): Promise<void> {
  const pending = lane.then(operation, operation);
  lane = pending.catch(() => undefined);
  return pending;
}

/** Whether a native mpv session is the current player. */
export function nativePlaybackActive(): boolean {
  return activeGeneration !== null && activeGeneration === requestedGeneration;
}

/** Whether the overlay/source owns a native request, including preparation or an in-flight start.
 *  Teardown must revoke pending requests too; transport controls still require active playback. */
export function nativePlaybackOwned(): boolean {
  return nativePlaybackActive() || pendingGeneration !== null && pendingGeneration === requestedGeneration;
}

/** Play a torrent stream in native mpv, optionally resuming at `startSeconds`. Resolves true once mpv owns
 *  playback, false when this request was superseded or the source cannot be played natively. */
export function playTorrent(stream: Stream, startSeconds = 0): Promise<boolean> {
  const generation = ++requestedGeneration;
  pendingGeneration = generation;
  let started = false;
  return queue(async () => {
    await stopNative();
    activeGeneration = null;
    const url = torrentUrl(stream);
    if (!url || generation !== requestedGeneration) return;
    const hash = stream.infoHash!.toLowerCase();
    await prepareTorrent(stream, hash);
    if (generation !== requestedGeneration) return;
    const start = Number.isFinite(startSeconds) && startSeconds > 0 ? startSeconds : null;
    await call("mpv_play", { url, start });
    if (generation !== requestedGeneration) {
      await stopNative();
      return;
    }
    activeGeneration = generation;
    started = true;
  }).finally(() => {
    if (pendingGeneration === generation) pendingGeneration = null;
  }).then(() => started);
}

/** Stop native playback in the same ordered lane as play requests. */
export function stopTorrent(): Promise<void> {
  ++requestedGeneration;
  pendingGeneration = null;
  return queue(async () => {
    await stopNative();
    activeGeneration = null;
  });
}

async function stopNative(): Promise<void> {
  try {
    await call("mpv_stop");
  } catch {
    // Nothing was playing.
  }
}

/** Pause or resume the native session; a no-op when mpv is not the current player. */
export async function setNativePaused(paused: boolean): Promise<void> {
  if (!nativePlaybackActive()) return;
  try {
    await call("mpv_set_paused", { paused });
  } catch {
    // Transport controls stay best-effort.
  }
}

/** Seek the native session by `seconds` (negative rewinds). */
export async function seekNative(seconds: number): Promise<void> {
  if (!nativePlaybackActive() || !Number.isFinite(seconds)) return;
  try {
    await call("mpv_seek_relative", { seconds });
  } catch {
    // Transport controls stay best-effort.
  }
}

/** Position reports from the shell's mpv reporter, every few seconds while a native session plays. */
export interface NativeProgress {
  positionMs: number;
  durationMs: number;
}

/** Subscribe to native playback progress; resolves to an unsubscribe function. */
export async function onNativeProgress(handler: (progress: NativeProgress) => void): Promise<() => void> {
  const listen = tauriGlobal()?.event?.listen;
  if (typeof listen !== "function") return () => undefined;
  return listen<NativeProgress>("vortx://player-progress", (event) => handler(event.payload));
}

/** The shell's view of mpv, for the overlay's state line. */
export function nativeStatus(): Promise<MpvStatus> {
  return call<MpvStatus>("mpv_status");
}
