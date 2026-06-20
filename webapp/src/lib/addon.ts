import type {
  Addon,
  AddonCatalogDef,
  AddonManifest,
  AddonResource,
  CatalogResponse,
  MetaItem,
  MetaResponse,
  Stream,
  StreamResponse,
} from "./types";

// The Stremio add-on protocol client. This is the web equivalent of the embedded stremio-core engine:
// instead of dispatching JSON actions to a Rust runtime (the desktop/iOS path), we resolve add-on
// resource URLs and fetch them directly over HTTPS from the browser. The protocol is documented at
// https://github.com/Stremio/stremio-addon-sdk - a resource URL is
// `{addon-dir}/{resource}/{type}/{id}.json` with optional `/{extra}` query-ish path segments.
//
// Cinemeta (the official catalog/meta add-on) and any installed stream add-on with a public HTTPS
// transport work without a server. Torrent infoHash streams are returned but flagged not-playable by
// the ranking layer, because the web client has no streaming server to turn them into HTTP.

/** Cinemeta - Stremio's official catalogs + metadata add-on. The default catalog/meta source. */
export const CINEMETA_URL = "https://v3-cinemeta.strem.io/manifest.json";

/** Reasonable starter stream add-ons that expose direct/HTTPS sources without a streaming server. */
export const DEFAULT_STREAM_ADDONS: string[] = [
  // Public OpenSubtitles-backed sample stream add-on is intentionally omitted; the user installs
  // their own debrid/direct stream add-ons. Cinemeta also exposes YouTube trailer streams.
];

const REQUEST_TIMEOUT_MS = 12_000;

/** Strip a trailing `/manifest.json` (and any trailing slash) to get the add-on resource directory. */
function addonBaseDir(transportUrl: string): string {
  return transportUrl.replace(/\/manifest\.json$/i, "").replace(/\/$/, "");
}

/** A bounded fetch + JSON parse. Throws on non-2xx or timeout so callers can fall back per add-on. */
async function fetchJson<T>(url: string): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: controller.signal, headers: { Accept: "application/json" } });
    if (!res.ok) {
      throw new Error(`Add-on request failed (${res.status}) for ${url}`);
    }
    return (await res.json()) as T;
  } finally {
    clearTimeout(timer);
  }
}

/** Encode an id for a path segment without turning the protocol's `:`-joined ids into `%3A` soup. */
function encodeId(id: string): string {
  return encodeURIComponent(id).replace(/%3A/gi, ":");
}

// ---- Manifest / installation -------------------------------------------------------------------

/** Load an add-on's manifest from its transport URL, returning the installable Addon record. */
export async function loadAddon(transportUrl: string): Promise<Addon> {
  const manifest = await fetchJson<AddonManifest>(transportUrl);
  if (!manifest || typeof manifest.id !== "string") {
    throw new Error(`Not a valid add-on manifest: ${transportUrl}`);
  }
  return { transportUrl, manifest };
}

/** The resource names an add-on declares it supports (handles both string and object forms). */
function resourceNames(manifest: AddonManifest): string[] {
  return (manifest.resources ?? []).map((r) => (typeof r === "string" ? r : (r as AddonResource).name));
}

/** Whether the add-on can serve `resource` for `type` (and, optionally, an id with a known prefix). */
export function supportsResource(addon: Addon, resource: string, type?: string, id?: string): boolean {
  const { manifest } = addon;
  const declared = (manifest.resources ?? []).find((r) =>
    typeof r === "string" ? r === resource : (r as AddonResource).name === resource,
  );
  if (!declared) return false;

  // Object-form resources can narrow the types and id prefixes they answer for.
  if (typeof declared !== "string") {
    const obj = declared as AddonResource;
    if (type && obj.types && obj.types.length && !obj.types.includes(type)) return false;
    if (id && obj.idPrefixes && obj.idPrefixes.length && !obj.idPrefixes.some((p) => id.startsWith(p))) {
      return false;
    }
    return true;
  }

  // String-form resources fall back to the manifest-level types / idPrefixes.
  if (type && manifest.types && manifest.types.length && !manifest.types.includes(type)) return false;
  if (id && manifest.idPrefixes && manifest.idPrefixes.length && !manifest.idPrefixes.some((p) => id.startsWith(p))) {
    return false;
  }
  return true;
}

// ---- Catalogs ----------------------------------------------------------------------------------

/** The catalog definitions an add-on exposes, paired with the add-on (for fetching + labels). */
export interface CatalogRef {
  addon: Addon;
  def: AddonCatalogDef;
}

/** Every catalog across the installed add-ons, in install order (the Board renders one rail each). */
export function catalogRefs(addons: Addon[]): CatalogRef[] {
  const refs: CatalogRef[] = [];
  for (const addon of addons) {
    if (!resourceNames(addon.manifest).includes("catalog")) continue;
    for (const def of addon.manifest.catalogs ?? []) {
      // Catalogs that REQUIRE extra props (search, genre) can't be loaded as a plain rail; skip them
      // on the Board (search is handled separately).
      const required = (def.extra ?? []).filter((e) => e.isRequired).length + (def.extraRequired?.length ?? 0);
      if (required > 0) continue;
      refs.push({ addon, def });
    }
  }
  return refs;
}

/** Build the resource URL for a catalog page, with an optional `skip` for pagination. */
function catalogUrl(ref: CatalogRef, extra?: Record<string, string | number>): string {
  const base = addonBaseDir(ref.addon.transportUrl);
  const { type, id } = ref.def;
  const extras = extra
    ? "/" +
      Object.entries(extra)
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
        .join("&")
    : "";
  return `${base}/catalog/${encodeURIComponent(type)}/${encodeURIComponent(id)}${extras}.json`;
}

/** Keep only well-formed meta items (a non-null object with a string id). A misbehaving add-on can
 *  return null / non-object entries (or a non-array `metas`); without this they throw in id de-dup or
 *  blank a whole rail. Mirrors the boundary validation `fetchSubtitles` already does for tracks. */
function validMetas(list: unknown): MetaItem[] {
  if (!Array.isArray(list)) return [];
  return list.filter(
    (m): m is MetaItem => m !== null && typeof m === "object" && typeof (m as MetaItem).id === "string",
  );
}

/** Fetch one catalog page's meta items (empty array on failure so one bad add-on never breaks Home). */
export async function fetchCatalog(ref: CatalogRef, skip = 0): Promise<MetaItem[]> {
  const url = catalogUrl(ref, skip > 0 ? { skip } : undefined);
  try {
    const data = await fetchJson<CatalogResponse>(url);
    return validMetas(data.metas);
  } catch {
    return [];
  }
}

/** "More Like This": Cinemeta's public `top` catalog filtered by the title's first genre. Keyless and
 *  account-free (works for everyone), so it is a reliable similar-titles source for the detail page.
 *  Returns [] for unsupported types or on any error (fail-soft, like ratings). */
export async function fetchSimilar(meta: MetaItem): Promise<MetaItem[]> {
  const genre = meta.genres?.[0];
  if (!genre || (meta.type !== "movie" && meta.type !== "series")) return [];
  const base = CINEMETA_URL.replace(/\/manifest\.json$/, "");
  const url = `${base}/catalog/${meta.type}/top/genre=${encodeURIComponent(genre)}.json`;
  try {
    const data = await fetchJson<CatalogResponse>(url);
    return validMetas(data.metas)
      .filter((m) => m.id !== meta.id)
      .slice(0, 18);
  } catch {
    return [];
  }
}

/** "Top Picks for you": aggregate genre-similar titles from the user's recent seeds (watch history +
 *  library). Each seed's meta is fetched for its genres, then its similar list; the lists are interleaved
 *  by seed so the rail reflects multiple tastes (recency-first). Excludes ids the user has already seen.
 *  Keyless; returns [] when there are no usable seeds (cold start). */
export async function fetchTopPicks(
  addons: Addon[],
  seeds: MetaItem[],
  excludeIds: Set<string>,
): Promise<MetaItem[]> {
  const top = seeds.slice(0, 3);
  if (!top.length) return [];
  const metas = await Promise.all(top.map((s) => fetchMeta(addons, s.type, s.id)));
  const lists = await Promise.all(metas.map((m) => (m ? fetchSimilar(m) : Promise.resolve([]))));
  const seen = new Set(excludeIds);
  const out: MetaItem[] = [];
  const maxLen = lists.reduce((n, l) => Math.max(n, l.length), 0);
  for (let i = 0; i < maxLen && out.length < 18; i++) {
    for (const list of lists) {
      const m = list[i];
      if (m && !seen.has(m.id)) {
        seen.add(m.id);
        out.push(m);
        if (out.length >= 18) break;
      }
    }
  }
  return out;
}

// ---- Search ------------------------------------------------------------------------------------

/** The first add-on catalog that declares it supports the `search` extra prop for `type` (if any). */
function searchableCatalog(addons: Addon[], type: string): CatalogRef | undefined {
  for (const addon of addons) {
    if (!resourceNames(addon.manifest).includes("catalog")) continue;
    for (const def of addon.manifest.catalogs ?? []) {
      if (def.type !== type) continue;
      const supportsSearch =
        (def.extra ?? []).some((e) => e.name === "search") || (def.extraSupported ?? []).includes("search");
      if (supportsSearch) return { addon, def };
    }
  }
  return undefined;
}

/** The searchable catalog refs (one per type that exposes a search-capable catalog), for paged search.
 *  The view layer merges + de-dupes across these and pages each one independently (see views/search). */
export function searchableRefs(addons: Addon[], types: string[]): CatalogRef[] {
  return types
    .map((type) => searchableCatalog(addons, type))
    .filter((r): r is CatalogRef => r !== undefined);
}

/** Fetch one searchable catalog's page of results for `query`, with an optional `skip` for paging.
 *  Validated + empty on failure, so one bad add-on never breaks the merged results grid. */
export async function fetchSearchPage(ref: CatalogRef, query: string, skip = 0): Promise<MetaItem[]> {
  const extra: Record<string, string | number> = { search: query };
  if (skip > 0) extra.skip = skip;
  try {
    const data = await fetchJson<CatalogResponse>(catalogUrl(ref, extra));
    return validMetas(data.metas);
  } catch {
    return [];
  }
}

// ---- Meta --------------------------------------------------------------------------------------

/** Fetch a single title's full meta (description, videos/episodes, links) from the first add-on that
 *  serves `meta` for this id. Returns null when no add-on can resolve it. */
export async function fetchMeta(addons: Addon[], type: string, id: string): Promise<MetaItem | null> {
  const candidates = addons.filter((a) => supportsResource(a, "meta", type, id));
  for (const addon of candidates) {
    const base = addonBaseDir(addon.transportUrl);
    const url = `${base}/meta/${encodeURIComponent(type)}/${encodeId(id)}.json`;
    try {
      const data = await fetchJson<MetaResponse>(url);
      if (data.meta) return data.meta;
    } catch {
      // Try the next add-on that claims to serve this meta.
    }
  }
  return null;
}

// ---- Streams -----------------------------------------------------------------------------------

/** One add-on's stream response for a title/episode, kept grouped so the UI can label + filter. */
export interface StreamGroup {
  addonName: string;
  transportUrl: string;
  streams: Stream[];
}

/** Fetch streams for `id` from every add-on that serves `stream` for `type`, in parallel, grouped.
 *  Each group resolves independently so the Detail page can show progress and partial results. */
export async function fetchStreams(addons: Addon[], type: string, id: string): Promise<StreamGroup[]> {
  const candidates = addons.filter((a) => supportsResource(a, "stream", type, id));
  const groups = await Promise.all(
    candidates.map(async (addon): Promise<StreamGroup | null> => {
      const base = addonBaseDir(addon.transportUrl);
      const url = `${base}/stream/${encodeURIComponent(type)}/${encodeId(id)}.json`;
      try {
        const data = await fetchJson<StreamResponse>(url);
        const streams = data.streams ?? [];
        if (!streams.length) return null;
        return { addonName: addon.manifest.name, transportUrl: addon.transportUrl, streams };
      } catch {
        return null;
      }
    }),
  );
  return groups.filter((g): g is StreamGroup => g !== null);
}

// ---- Subtitles ---------------------------------------------------------------------------------

/** One subtitle option from a subtitles add-on (OpenSubtitles-style): a downloadable SRT/VTT + its lang. */
export interface SubtitleTrack {
  id: string;
  url: string;
  lang: string;
}

/** Fetch subtitle options for a title/episode from every add-on that serves `subtitles` for `type`,
 *  de-duped to one per language and capped (so the player adds a sane number of <track>s). Empty on
 *  failure. `id` is the title id for movies, or the episode video id (ttSeries:S:E) for series. */
export async function fetchSubtitles(addons: Addon[], type: string, id: string): Promise<SubtitleTrack[]> {
  const candidates = addons.filter((a) => supportsResource(a, "subtitles", type, id));
  const groups = await Promise.all(
    candidates.map(async (addon): Promise<SubtitleTrack[]> => {
      const base = addonBaseDir(addon.transportUrl);
      const url = `${base}/subtitles/${encodeURIComponent(type)}/${encodeId(id)}.json`;
      try {
        const data = await fetchJson<{ subtitles?: SubtitleTrack[] }>(url);
        return (data.subtitles ?? []).filter(
          (s) => s && typeof s.url === "string" && typeof s.lang === "string" && /^https?:\/\//i.test(s.url),
        );
      } catch {
        return [];
      }
    }),
  );
  const seen = new Set<string>();
  const out: SubtitleTrack[] = [];
  for (const s of groups.flat()) {
    const key = s.lang.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(s);
    if (out.length >= 8) break;
  }
  return out;
}
