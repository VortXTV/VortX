// Full-trailer resolution for the web client, wired to the VortX trailer backend.
//
// The detail / hero "Trailer" control plays the FULL trailer (not the 10s ambient hero clip) by resolving
// it through the app's own trailer service:
//
//   https://trailer.vortx.tv/yt/lang/<imdbOrTmdbId>?lang=<userLang>&type=<movie|tv>
//
// The worker selects the right language YouTube trailer (TMDB /videos, user-lang -> en -> any) and 302s to
// a direct googlevideo mp4. That mp4 is progressive (NOT HLS), so it plays natively in an HTML5 <video> and
// must NOT be routed through hls.js. This keeps the web trailer consistent with the native apps, which use
// the same /yt resolver -> native player path.
//
// Everything here is FAIL-SOFT: when the backend has no trailer (404) or errors, the caller hides the
// Trailer affordance and falls back to the YouTube iframe embed (if the meta carries a YouTube id) rather
// than ever showing a broken player.

const TRAILER_BACKEND = "https://trailer.vortx.tv";

/** The 2-letter subtag of a BCP-47-ish tag ("en-US" -> "en", "pt_BR" -> "pt"), or "" when empty. */
function langSubtag(lang: string): string {
  return (lang || "").toLowerCase().split(/[-_]/)[0].slice(0, 2);
}

/** The user's chosen trailer language: their playback (audio) language preference if set, else the browser
 *  UI language, else English. The web client has no separate "app language" knob, so the chosen audio
 *  language is the closest twin of the native app's trailer-language preference; en is the final fallback. */
export function userTrailerLang(audioLang: string | undefined): string {
  const chosen = langSubtag(audioLang ?? "");
  if (chosen) return chosen;
  const nav =
    typeof navigator !== "undefined" ? langSubtag(navigator.language || (navigator.languages && navigator.languages[0]) || "") : "";
  return nav || "en";
}

/** Map a Stremio meta type to the backend's movie|tv type hint (series -> tv). */
function trailerType(metaType: string): "movie" | "tv" {
  const t = (metaType || "").toLowerCase();
  return t === "series" || t === "tv" ? "tv" : "movie";
}

/** Build the backend full-trailer URL for a title. `id` is the meta id as-is: a Cinemeta IMDb tt id, or a
 *  tmdb:movie:ID / tmdb:tv:ID / bare tmdb id - the worker accepts all of these. */
export function backendTrailerUrl(id: string, metaType: string, lang: string): string {
  const type = trailerType(metaType);
  return `${TRAILER_BACKEND}/yt/lang/${encodeURIComponent(id)}?lang=${encodeURIComponent(lang)}&type=${type}`;
}

/** Probe the backend for a full trailer, returning a playable mp4 URL or null (fail-soft).
 *
 *  The worker 302-redirects a resolved trailer to a direct googlevideo mp4, and 404s when it has none. We
 *  fetch with `redirect: "manual"` so:
 *    - a 302 surfaces as an opaque-redirect response (type "opaqueredirect") WITHOUT us having to read the
 *      cross-origin googlevideo body (which carries no CORS headers) - we then hand the backend URL itself
 *      to the <video>, and the browser follows the 302 natively during playback;
 *    - a 404 (no trailer) surfaces as a normal response we can read (the worker allows our origin), so we
 *      return null and the caller hides / falls back.
 *  Any network error also returns null.
 *
 *  EDGE-GATE / SIGNING (deliberate): this probe (and the <video> load that follows) is UNSIGNED. The web
 *  surface is intentionally bare-bones and carries NO edge-signing code and NO shared secret - a secret
 *  shipped in a browser bundle is trivially extractable, so signing here would be theatre, not a gate, and
 *  would contradict the "web = origin-gated only, no signing" decision that the native apps' edge hardening
 *  is built around. The trailer worker gates /yt + /yt/lang via verifyClient, but ships ENFORCE_CLIENT_SIG=0
 *  (OBSERVE): it logs the unsigned web caller and still serves, so the trailer plays today. If enforce is
 *  ever flipped on, verifyClient returns 403 to this unsigned request; that lands in the `!res.ok -> null`
 *  branch below and the caller degrades honestly to the YouTube iframe embed rather than a broken player.
 *  So enforce would DISABLE the native-mp4 web trailer (falling back to the iframe), never break it. If the
 *  web mp4 trailer must survive an enforced gate, the correct move is the query-sig tier (append
 *  ?vts=<unix>&vsig=<hmac over "GET\n<path>\n<vts>"> to backendTrailerUrl) fed by a per-session token minted
 *  server-side - NOT a bundled secret - which is a larger change than this fix and out of scope here. */
export async function resolveBackendTrailer(
  id: string,
  metaType: string,
  lang: string,
  signal?: AbortSignal,
): Promise<string | null> {
  if (!id) return null;
  const url = backendTrailerUrl(id, metaType, lang);
  try {
    const res = await fetch(url, { method: "GET", redirect: "manual", signal });
    // A 302 to googlevideo -> opaqueredirect (status 0). Some engines expose the 3xx directly; accept both.
    if (res.type === "opaqueredirect" || (res.status >= 300 && res.status < 400)) return url;
    // A readable 2xx (unlikely for this route, but honour it) also means a trailer exists.
    if (res.ok) return url;
    // 403 == the edge gate is ENFORCING and this (deliberately unsigned) web request was rejected. That is
    // an expected degradation, not an error: the caller falls back to the YouTube iframe. See the signing
    // note above. 404 no_trailer / bad_id / any other status -> also fail soft to null.
    return null;
  } catch {
    return null; // aborted or network error -> fail soft
  }
}
