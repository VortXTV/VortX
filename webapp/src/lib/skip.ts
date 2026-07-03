// Intro / outro skip segments from VortX's own keyless SkipDB worker (skip.vortx.tv), the same service the
// native apps read. On a title's playback the player shows a "Skip Intro" / "Skip Outro" button while inside
// a known segment. Read-only + keyless here; contribution stays in the apps' in-player editor.
//
// Read contract (mirrors SkipTimestampService in the Apple app): GET skip.vortx.tv/skip?key=<key> where the
// key is imdb:tt<digits> for a movie, or imdb:tt<digits>:<season>:<episode> for an episode. The worker
// answers with a small JSON of segments; we normalise to { kind, start, end } seconds. Fail-soft: any error
// (offline, 404, malformed) yields no segments, so the Skip button simply never appears.

import type { SkipSegment } from "./playerControls";

const SKIP_HOST = "https://skip.vortx.tv";
const SKIP_TIMEOUT_MS = 3500;

/** One segment as the worker returns it (tolerant of a few field spellings the dump / apps use). */
interface RawSkipSegment {
  type?: string; // "intro" | "outro" | "recap" | "credits" | ...
  category?: string;
  startTime?: number;
  endTime?: number;
  start?: number;
  end?: number;
}

interface SkipResponse {
  segments?: RawSkipSegment[];
}

/** Build the SkipDB read key for a title/episode. `id` is the display id (tt...) and season/episode are the
 *  numbers from the open Video (undefined for a movie). Returns null when we don't have an imdb id to key on
 *  (the worker is imdb-keyed), so a non-imdb catalog id simply gets no segments. */
export function skipKey(id: string, season?: number, episode?: number): string | null {
  const m = /^(tt\d+)/.exec(id);
  if (!m) return null;
  const base = `imdb:${m[1]}`;
  return season !== undefined && episode !== undefined ? `${base}:${season}:${episode}` : base;
}

/** Fetch intro / outro segments for a title/episode. Empty on any failure (fail-soft). */
export async function fetchSkipSegments(id: string, season?: number, episode?: number): Promise<SkipSegment[]> {
  const key = skipKey(id, season, episode);
  if (!key) return [];
  try {
    // Bound the request so a slow / hung worker can never gate the media start (the caller awaits this on the
    // hot path): a stalled skip.vortx.tv degrades to no segments after SKIP_TIMEOUT_MS rather than the
    // browser's long default network timeout.
    const res = await fetch(`${SKIP_HOST}/skip?key=${encodeURIComponent(key)}`, {
      signal: AbortSignal.timeout(SKIP_TIMEOUT_MS),
    });
    if (!res.ok) return [];
    const data = (await res.json()) as SkipResponse;
    return normalise(data.segments ?? []);
  } catch {
    return [];
  }
}

/** Normalise the worker's segments to the player's shape, keeping only well-formed intro / outro spans.
 *  Recap / credits map onto intro / outro respectively so they still surface a skip affordance. */
function normalise(raw: RawSkipSegment[]): SkipSegment[] {
  const out: SkipSegment[] = [];
  for (const s of raw) {
    const start = typeof s.startTime === "number" ? s.startTime : s.start;
    const end = typeof s.endTime === "number" ? s.endTime : s.end;
    if (typeof start !== "number" || typeof end !== "number" || end <= start) continue;
    const label = (s.type ?? s.category ?? "").toLowerCase();
    const kind: "intro" | "outro" = label.includes("outro") || label.includes("credit") ? "outro" : "intro";
    out.push({ kind, start, end });
  }
  return out;
}
