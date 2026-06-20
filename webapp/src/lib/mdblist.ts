// MDBList cross-provider ratings (IMDb / Rotten Tomatoes / TMDB) for the detail page, shown only when the
// user has set an MDBList key in Settings. Ported from the Apple MDBListClient. api.mdblist.com permits
// browser CORS, so the web client calls it directly with the user's key (no proxy). Fails soft (returns
// null) so a missing / invalid key or a network hiccup never breaks the page.

export interface Ratings {
  imdb?: number; // native 0-10
  rottenTomatoes?: number; // 0-100
  tmdb?: number; // 0-100
}

const HOST = "https://api.mdblist.com";

/** Ratings for an IMDb id (tt...). `type` is the Stremio type; MDBList keys series under "show". */
export async function fetchRatings(imdbID: string, type: string, key: string): Promise<Ratings | null> {
  if (!key || !imdbID.startsWith("tt")) return null;
  const mediaType = type === "series" ? "show" : "movie";
  const url = `${HOST}/imdb/${mediaType}/${encodeURIComponent(imdbID)}?apikey=${encodeURIComponent(key)}`;
  try {
    const resp = await fetch(url);
    if (!resp.ok) return null;
    const root = (await resp.json()) as { ratings?: { source?: string; value?: number | null }[] };
    const bySource: Record<string, number> = {};
    for (const e of root.ratings ?? []) {
      if (typeof e?.source === "string" && typeof e.value === "number") bySource[e.source] = e.value;
    }
    const out: Ratings = {};
    if (typeof bySource.imdb === "number") out.imdb = bySource.imdb;
    if (typeof bySource.tomatoes === "number") out.rottenTomatoes = Math.round(bySource.tomatoes);
    if (typeof bySource.tmdb === "number") out.tmdb = Math.round(bySource.tmdb);
    return out.imdb != null || out.rottenTomatoes != null || out.tmdb != null ? out : null;
  } catch {
    return null;
  }
}

/** "IMDb 8.8  ·  RT 87%  ·  TMDB 83%" from whatever providers are present. */
export function ratingsText(r: Ratings): string {
  const parts: string[] = [];
  if (r.imdb != null) parts.push(`IMDb ${r.imdb.toFixed(1)}`);
  if (r.rottenTomatoes != null) parts.push(`RT ${r.rottenTomatoes}%`);
  if (r.tmdb != null) parts.push(`TMDB ${r.tmdb}%`);
  return parts.join("  ·  ");
}
