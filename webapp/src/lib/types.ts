// Stremio add-on protocol types. These are the JSON shapes add-ons return over HTTPS, ported from the
// engine-facing types in desktop/src/engine.ts. On desktop the embedded stremio-core engine wrapped
// these behind a Tauri `invoke` transport; the web client has no engine, so it speaks the add-on
// protocol directly (see addon.ts) and these are the raw on-the-wire shapes.
//
// See https://github.com/Stremio/stremio-addon-sdk for the protocol reference.

/** A catalog / meta / library item: the poster-and-metadata object every surface renders. */
export interface MetaItem {
  id: string;
  type: string;
  name: string;
  poster?: string;
  posterShape?: "poster" | "landscape" | "square";
  background?: string;
  logo?: string;
  description?: string;
  releaseInfo?: string;
  imdbRating?: string;
  runtime?: string;
  genres?: string[];
  links?: MetaLink[];
  videos?: Video[];
  trailerStreams?: Stream[];
}

/** Typed cross-reference on a meta item (genre, director, imdb rating, trailer, ...). */
export interface MetaLink {
  name: string;
  category: string;
  url?: string;
}

/** One episode of a series (or a single video entry). */
export interface Video {
  id: string;
  title?: string;
  name?: string;
  released?: string;
  overview?: string;
  description?: string;
  thumbnail?: string;
  season?: number;
  episode?: number;
}

// StreamSource is flattened on the wire: url / ytId / infoHash / externalUrl sit at the top level.
// Direct/debrid streams carry `url` (an HTTP(S) link the browser can play). TORRENT streams carry
// `infoHash` and need a streaming server to become playable - the web client cannot play those (see
// the README): it has no embedded server, so torrent-only sources are surfaced as not-playable.
export interface Stream {
  url?: string;
  ytId?: string;
  infoHash?: string;
  fileIdx?: number;
  sources?: string[];
  externalUrl?: string;
  name?: string;
  title?: string;
  description?: string;
  behaviorHints?: StreamBehaviorHints;
}

export interface StreamBehaviorHints {
  bingeGroup?: string;
  filename?: string;
  notWebReady?: boolean;
}

/** A short manifest summary: name + the catalogs and resources an add-on exposes. */
export interface AddonManifest {
  id: string;
  name: string;
  version?: string;
  description?: string;
  logo?: string;
  resources?: Array<string | AddonResource>;
  types?: string[];
  catalogs?: AddonCatalogDef[];
  idPrefixes?: string[];
}

export interface AddonResource {
  name: string;
  types?: string[];
  idPrefixes?: string[];
}

export interface AddonCatalogDef {
  type: string;
  id: string;
  name?: string;
  extra?: AddonCatalogExtra[];
  extraSupported?: string[];
  extraRequired?: string[];
}

export interface AddonCatalogExtra {
  name: string;
  isRequired?: boolean;
  options?: string[];
  optionsLimit?: number;
}

/** A configured add-on: its manifest plus the transport URL we fetch resources from. */
export interface Addon {
  transportUrl: string; // the manifest.json URL; resources are resolved relative to its directory
  manifest: AddonManifest;
}

// ---- Add-on response envelopes -----------------------------------------------------------------

export interface CatalogResponse {
  metas?: MetaItem[];
}

export interface MetaResponse {
  meta?: MetaItem;
}

export interface StreamResponse {
  streams?: Stream[];
}
