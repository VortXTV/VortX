package com.vortx.android.catalog

import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/// Shared keyless-edge access for the detail-page catalog clients ([SimilarClient], [WatchProvidersClient]).
///
/// Every request goes through VortX's KEYLESS catalog edge (`catalogs.vortx.tv/3`), a cached, app-gated
/// TMDB proxy that injects OUR TMDB key server-side, so users with no key still get related titles and
/// watch-provider data. This mirrors the keyless branch of the Apple `TMDBClient.get()` choke point (the
/// same seam `com.vortx.android.person.TMDBPersonClient` rides), signed via [VortXEdgeAuth] so the gate can
/// attribute the call to a real VortX build. FAIL-SOFT by contract: every call resolves to null on a
/// non-200 or any transport error, so a flaky edge never blanks a rail.
internal object CatalogTmdbEdge {

    /// The keyless catalog edge base, path-compatible with TMDB's `/3` namespace (a request to
    /// `/movie/{id}/recommendations` hits `catalogs.vortx.tv/3/movie/{id}/recommendations`). This is the
    /// baked default Apple's `RemoteConfig.catalogsEndpoint` also ships.
    const val EDGE_BASE = "https://catalogs.vortx.tv/3"

    /// The TMDB image CDN. Marks are requested at a small width (w92) for the provider logos and a card
    /// width (w342) for the related-title posters, the same sizes the Apple clients use.
    const val IMAGE_BASE = "https://image.tmdb.org/t/p"

    private const val TIMEOUT_MS = 20_000

    /// GET [path] off the keyless edge and decode a JSON object. Signs the request via [VortXEdgeAuth]
    /// (stamped after the method + URL are set, before the connection opens, per the signer's contract).
    /// Runs on [Dispatchers.IO]; a non-200 or any transport error resolves to null so every caller stays
    /// fail-soft. [path] is a leading-slash TMDB path (`/movie/123/recommendations`), appended to `/3`.
    suspend fun getJson(path: String): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val url = URL(EDGE_BASE + path)
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
            }
            VortXEdgeAuth.sign(connection)
            if (connection.responseCode != 200) return@withContext null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            runCatching { JSONObject(text) }.getOrNull()
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }
}

/// Like `optString` but null (not "") for a missing or JSON-null value, matching the codebase's existing
/// `optStringOrNull` helpers so optional fields stay absent. Top-level (not a member extension) so the
/// catalog clients can import it directly.
internal fun JSONObject.optStringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return optString(key).ifBlank { null }
}
