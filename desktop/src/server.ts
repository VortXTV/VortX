import { invoke } from "@tauri-apps/api/core";

import type { Stream } from "./engine";

// Client for the embedded streaming server (Stremio's server.js on http://127.0.0.1:11470, spawned +
// monitored by the Rust backend, see src-tauri/src/server.rs). Direct/debrid streams play straight
// from their `url`; TORRENT streams (infoHash, no url) are CREATED on the local server, which fetches
// pieces and exposes the selected file over HTTP for the player. This is the desktop port of the
// Apple app's StremioServer + TorrentTrackers + prepareTorrent (StremioServer.swift,
// TorrentTrackers.swift, iOSDetailView.prepareTorrentStream), same /create body, same trackers, same
// /<hash>/<fileIdx> file endpoint, fronted by the Rust commands instead of a native NodeServer.

// The Rust backend's server-state command shape (matches server::ServerState's serde tagging).
export interface ServerStatus {
  state: "running" | "failed" | "disabled";
  reason?: string;
}

// ---- Availability (cached base URL + liveness) -------------------------------------------------

let cachedBaseUrl: string | null = null;
let liveServer = false;

/** The embedded server base, fetched once from the Rust command and memoized. */
export async function baseUrl(): Promise<string> {
  if (cachedBaseUrl === null) {
    cachedBaseUrl = await invoke<string>("server_base_url");
  }
  return cachedBaseUrl;
}

/** The backend's view of the server (running / failed / disabled), for the empty state. */
export async function status(): Promise<ServerStatus> {
  return invoke<ServerStatus>("server_status");
}

/** Whether the server is accepting connections on loopback yet (it boots asynchronously). */
export async function isListening(): Promise<boolean> {
  return invoke<boolean>("server_is_listening");
}

/**
 * Whether torrent playback is available right now: the backend reports the server running AND it is
 * actually listening. Cached after the first `true` so the hot path (stream filtering) stays sync,
 * `primeAvailability()` warms it on startup and a few times after, mirroring the Apple app treating
 * the embedded server as present once it has booted.
 */
export function torrentsAvailable(): boolean {
  return liveServer;
}

/** Poll the backend until the server is listening (or we run out of tries), updating the cached flag. */
export async function primeAvailability(): Promise<boolean> {
  try {
    const s = await status();
    if (s.state !== "running") {
      liveServer = false;
      return false;
    }
    liveServer = await isListening();
  } catch {
    liveServer = false;
  }
  return liveServer;
}

// ---- Torrent trackers (port of TorrentTrackers.swift) ------------------------------------------

// Public TCP/TLS trackers that work without UDP. The HTTPS ones especially are what let the engine
// reach a swarm when an add-on hands out only dead udp:// trackers. Same list the Apple app injects.
const DEFAULT_TRACKERS: string[] = [
  "tracker:https://tracker.alaskantf.com:443/announce",
  "tracker:https://tracker.bt4g.com:443/announce",
  "tracker:https://tracker.moeblog.cn:443/announce",
  "tracker:https://tracker.pmman.tech:443/announce",
  "tracker:https://tracker.zhuqiy.com:443/announce",
  "tracker:http://open.tracker.cl:1337/announce",
  "tracker:http://tracker.opentrackr.org:1337/announce",
  "tracker:http://tracker.files.fm:6969/announce",
];

/**
 * The full peerSearch source list for a `/create`: the stream's own sources, DHT, the HTTP twin of
 * every udp tracker present, and the TCP/TLS defaults, de-duped, order preserved. Mirrors
 * TorrentTrackers.sources(forHash:streamSources:).
 */
function trackerSources(hash: string, streamSources: string[] | undefined): string[] {
  const sources: string[] = [...(streamSources ?? [])];
  sources.push(`dht:${hash}`);
  // The HTTP twin of every udp tracker: the major trackers answer the same announce over HTTP on the
  // same host:port, a UDP-free path to peers.
  const twins = (streamSources ?? [])
    .filter((entry) => entry.startsWith("tracker:udp://"))
    .map((entry) => {
      const body = entry.slice("tracker:udp://".length);
      const hostPort = body.split("/")[0];
      return hostPort ? `tracker:http://${hostPort}/announce` : null;
    })
    .filter((x): x is string => x !== null);
  sources.push(...twins, ...DEFAULT_TRACKERS);
  return Array.from(new Set(sources));
}

// ---- Stream classification + URL resolution ----------------------------------------------------

/** A torrent stream: no direct url, but an infoHash the server can fetch. */
export function isTorrent(stream: Stream): boolean {
  return !stream.url && !!stream.infoHash;
}

/**
 * The playable URL for a stream: its direct/debrid `url`, or, for a torrent, the embedded server's
 * `/<infohash>/<fileIdx>` file endpoint. Returns null when a torrent is requested but the server is
 * unavailable. Mirrors StremioServer.resolveURL(for:).
 */
export async function resolveUrl(stream: Stream): Promise<string | null> {
  if (stream.url && /^https?:\/\//i.test(stream.url)) return stream.url;
  if (!isTorrent(stream) || !torrentsAvailable()) return null;
  const hash = stream.infoHash!.toLowerCase();
  const base = await baseUrl();
  return `${base}/${hash}/${stream.fileIdx ?? 0}`;
}

/**
 * For a torrent, tell the server to create the torrent (start fetching peers) before playback, with
 * the TCP/TLS trackers injected so a swarm can form. No-op for direct/debrid streams. Fire-and-forget
 * (the file endpoint blocks until ready), best-effort, a failed prime just means slower start.
 * Direct port of iOSDetailView.prepareTorrentStream / StremioServer.prepare.
 */
export async function prepareTorrent(stream: Stream): Promise<void> {
  if (!isTorrent(stream) || !torrentsAvailable()) return;
  const hash = stream.infoHash!.toLowerCase();
  const base = await baseUrl();
  const body = {
    torrent: { infoHash: hash },
    peerSearch: { sources: trackerSources(hash, stream.sources), min: 40, max: 150 },
  };
  try {
    await fetch(`${base}/${hash}/create`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    // Best-effort: the file endpoint will still trigger discovery, just without the injected trackers.
  }
}
