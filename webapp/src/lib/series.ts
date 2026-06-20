import type { MetaItem, Video } from "./types";

// Series helpers, a direct port of the season/episode handling in desktop/src/engine.ts (which itself
// mirrors DetailView.swift's CoreSeasonedEpisodes). A series shows a season selector + episode list;
// a movie shows streams directly.

/** A series shows the season selector + episode list; a movie shows streams directly. */
export function isSeries(type: string, meta: MetaItem | undefined): boolean {
  return type === "series" && !!meta?.videos && meta.videos.length > 0;
}

/** Videos sorted season-then-episode-then-id, the canonical episode order. */
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

/** The distinct season numbers present, ascending (0 = Specials). */
export function seasonsOf(videos: Video[]): number[] {
  return Array.from(new Set(videos.map((v) => v.season ?? 0))).sort((a, b) => a - b);
}

/** Episodes in one season, in episode order. */
export function episodesForSeason(videos: Video[], season: number): Video[] {
  return sortedVideos(videos.filter((v) => (v.season ?? 0) === season));
}

/** The season to land on: first non-special season, else the first season present. */
export function defaultSeason(seasons: number[]): number {
  return seasons.find((s) => s > 0) ?? seasons[0] ?? 1;
}
