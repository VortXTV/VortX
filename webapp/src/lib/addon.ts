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

/** Fetch one catalog page's meta items (empty array on failure so one bad add-on never breaks Home). */
export async function fetchCatalog(ref: CatalogRef, skip = 0): Promise<MetaItem[]> {
  const url = catalogUrl(ref, skip > 0 ? { skip } : undefined);
  try {
    const data = await fetchJson<CatalogResponse>(url);
    return data.metas ?? [];
  } catch {
    return [];
  }
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

/** Search across the installed add-ons for `query`, merged and de-duped by id. */
export async function search(addons: Addon[], query: string, types: string[]): Promise<MetaItem[]> {
  const refs = types
    .map((type) => searchableCatalog(addons, type))
    .filter((r): r is CatalogRef => r !== undefined);
  const pages = await Promise.all(
    refs.map(async (ref) => {
      try {
        const data = await fetchJson<CatalogResponse>(catalogUrl(ref, { search: query }));
        return data.metas ?? [];
      } catch {
        return [];
      }
    }),
  );
  const seen = new Set<string>();
  const merged: MetaItem[] = [];
  for (const meta of pages.flat()) {
    if (seen.has(meta.id)) continue;
    seen.add(meta.id);
    merged.push(meta);
  }
  return merged;
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
