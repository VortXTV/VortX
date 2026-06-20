import { invoke } from "@tauri-apps/api/core";

// Thin wrapper over the Tauri commands wired in src-tauri/lib.rs. The frontend drives the embedded
// stremio-core engine by dispatching `{ field, action }` envelopes and reading model fields back as
// JSON, the same transport the iOS/Apple TV apps use, minus the C ABI. Re-renders are triggered by
// the `core-event` event (listened to in main.ts), so this module stays render-agnostic.

// ---- Engine-shaped types (subset of the stremio-core-web JSON the model serializes) ------------

export interface Loadable<T> {
  type: string; // "Ready" | "Loading" | "Err"
  content?: T;
}

export interface ResourceRequest {
  base?: string; // addon transport URL, the per-addon grouping key
  path?: { resource?: string; type?: string; id?: string };
}

export interface MetaItem {
  id: string;
  type: string;
  name: string;
  poster?: string;
  background?: string;
  logo?: string;
  description?: string;
  releaseInfo?: string;
  runtime?: string;
  links?: { name: string; category: string }[];
  videos?: Video[];
  trailerStreams?: Stream[];
}

export interface Video {
  id: string;
  title?: string;
  released?: string;
  overview?: string;
  thumbnail?: string;
  season?: number;
  episode?: number;
}

// StreamSource is `#[serde(untagged)]` + flattened, so url / ytId / infoHash / externalUrl sit at
// the top level. Direct/debrid streams carry `url`; TORRENT streams carry `infoHash` (+ optional
// `fileIdx` selecting the file in a multi-file torrent, and `sources` = the add-on's tracker list),
// which the embedded streaming server turns into a playable HTTP endpoint (see server.ts).
export interface Stream {
  url?: string;
  ytId?: string;
  infoHash?: string;
  fileIdx?: number;
  sources?: string[];
  externalUrl?: string;
  name?: string;
  description?: string;
  behaviorHints?: { bingeGroup?: string; filename?: string };
}

export interface MetaEntry {
  request?: ResourceRequest;
  content?: Loadable<MetaItem>;
}

export interface StreamGroupResponse {
  request?: ResourceRequest;
  content?: Loadable<Stream[]>;
}

export interface MetaDetails {
  metaItems?: MetaEntry[];
  streams?: StreamGroupResponse[];
}

// ctx, we only need the addon manifests so a stream group's `request.base` can resolve to the
// add-on's display name (the same map CoreBridge.addonNamesByBase builds on Apple).
export interface Ctx {
  profile?: { addons?: { transportUrl?: string; manifest?: { name?: string } }[] };
}

export interface Board {
  catalogs?: CatalogPage[][];
}
export interface CatalogPage {
  request?: ResourceRequest;
  content?: Loadable<MetaItem[]>;
}

// ---- Commands ----------------------------------------------------------------------------------

export async function dispatch(field: string, action: unknown): Promise<void> {
  await invoke("engine_dispatch", { actionJson: JSON.stringify({ field, action }) });
}

export async function getState<T>(field: string): Promise<T | null> {
  const json = await invoke<string>("engine_get_state", { fieldJson: JSON.stringify(field) });
  try {
    return JSON.parse(json) as T;
  } catch {
    return null;
  }
}

// ---- Engine selectors --------------------------------------------------------------------------

/** First fully-loaded meta across the queried add-ons (mirrors CoreMetaDetails.meta). */
export function readyMeta(md: MetaDetails | null): MetaItem | undefined {
  return md?.metaItems
    ?.map((m) => (m.content?.type === "Ready" ? m.content.content : undefined))
    .find(Boolean);
}

// ---- Series helpers (mirror DetailView.swift's CoreSeasonedEpisodes season/episode handling) ----

/** A series shows the season selector + episode list; a movie shows streams directly. */
export function isSeries(type: string, meta: MetaItem | undefined): boolean {
  return type === "series" && !!meta?.videos && meta.videos.length > 0;
}

/** Videos sorted season-then-episode-then-id, the canonical episode order (sortedEpisodes in tvOS). */
export function sortedVideos(videos: Video[]): Video[] {
  return [...videos].sort((a, b) => {
    const sa = a.season ?? 0;
    const sb = b.season ?? 0;
    if (sa !== sb) return sa - sb;
    const ea = a.episode ?? 0;
    const eb = b.episode ?? 0;
    if (ea !== eb) return ea - eb;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}

/** The distinct season numbers present, ascending (0 = Specials), like recomputeSeasons(). */
export function seasonsOf(videos: Video[]): number[] {
  return Array.from(new Set(videos.map((v) => v.season ?? 0))).sort((a, b) => a - b);
}

/** Episodes in one season, in episode order (recomputeEpisodes()). */
export function episodesForSeason(videos: Video[], season: number): Video[] {
  return sortedVideos(videos.filter((v) => (v.season ?? 0) === season));
}

/** The season to land on: first non-special season, else the first season present (tvOS default). */
export function defaultSeason(seasons: number[]): number {
  return seasons.find((s) => s > 0) ?? seasons[0] ?? 1;
}

/** Map of addon transportUrl base -> display name, from ctx (mirrors addonNamesByBase). */
export function addonNamesByBase(ctx: Ctx | null): Record<string, string> {
  const map: Record<string, string> = {};
  for (const addon of ctx?.profile?.addons ?? []) {
    if (addon.transportUrl) map[addon.transportUrl] = addon.manifest?.name ?? "Add-on";
  }
  return map;
}

/** (loaded, total) stream add-ons for this title, so the UI can show "Finding sources… X/Y". */
export function streamLoadProgress(md: MetaDetails | null): { loaded: number; total: number } {
  const streams = md?.streams ?? [];
  let loaded = 0;
  for (const group of streams) {
    if (group.content?.type === "Ready" || group.content?.type === "Err") loaded += 1;
  }
  return { loaded, total: streams.length };
}
