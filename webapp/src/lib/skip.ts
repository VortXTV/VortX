// Intro, recap, credits and preview segments from the same keyless service the native apps read.
// Contribution stays in the apps' in-player editor.
//
// Read contract (mirrors SkipTimestampService in the Apple app): GET skip.vortx.tv/skip?key=<key> where the
// key is imdb:tt<digits> for a movie, or imdb:tt<digits>:<season>:<episode> for an episode. The worker
// answers with a small JSON of segments; we normalise to { kind, start, end } seconds. Fail-soft: any error
// (offline, 404, malformed) yields no segments, so the Skip button simply never appears.

import type { SkipSegment } from "./playerControls";

const SKIP_HOST = "https://skip.vortx.tv";
const SKIP_TIMEOUT_MS = 3500;

interface SkipResponse {
  segments?: unknown;
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

/** Fetch known segments for a title/episode. Empty on any failure (fail-soft). */
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
    return normaliseSkipSegments(data.segments);
  } catch {
    return [];
  }
}

function skipKind(label: string): SkipSegment["kind"] | null {
  switch (label.trim().toLowerCase().replace(/[\s-]+/g, "_")) {
    case "intro": case "opening": case "op": return "intro";
    case "recap": case "previously": return "recap";
    case "outro": case "credits": case "ending": case "closing": case "ed": return "credits";
    case "preview": case "next_episode": return "preview";
    default: return null;
  }
}

export function skipLabel(kind: SkipSegment["kind"]): string {
  return { intro: "Skip Intro", recap: "Skip Recap", credits: "Skip Credits", preview: "Skip Preview" }[kind];
}

/** The live endpoint sends a keyed object in milliseconds; older providers send an array in seconds.
 *  Validate each entry independently so malformed or unknown segments cannot erase valid neighbours. */
export function normaliseSkipSegments(raw: unknown): SkipSegment[] {
  if (!raw || typeof raw !== "object") return [];
  const entries: Array<[string, unknown]> = Array.isArray(raw)
    ? raw.map((segment) => ["", segment]) : Object.entries(raw);
  const out: SkipSegment[] = [];
  for (const [key, segment] of entries) {
    if (!segment || typeof segment !== "object" || Array.isArray(segment)) continue;
    const s = segment as Record<string, unknown>;
    const start = typeof s.start_ms === "number" ? s.start_ms / 1000 : s.startTime ?? s.start;
    const end = typeof s.end_ms === "number" ? s.end_ms / 1000 : s.endTime ?? s.end;
    if (typeof start !== "number" || typeof end !== "number" || !Number.isFinite(start) ||
        !Number.isFinite(end) || start < 0 || end <= start) continue;
    const label = s.type ?? s.category ?? key;
    const kind = typeof label === "string" ? skipKind(label) : null;
    if (!kind) continue;
    out.push({ kind, start, end });
  }
  return out;
}
