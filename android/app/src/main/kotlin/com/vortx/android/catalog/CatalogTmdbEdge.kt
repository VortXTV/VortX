package com.vortx.android.catalog

import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
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
    private const val BOUNDED_TIMEOUT_MS = 5_000

    /// GET [path] off the keyless edge and decode a JSON object. Signs the request via [VortXEdgeAuth]
    /// (stamped after the method + URL are set, before the connection opens, per the signer's contract).
    /// Runs on [Dispatchers.IO]; a non-200 or any transport error resolves to null so every caller stays
    /// fail-soft. [path] is a leading-slash TMDB path (`/movie/123/recommendations`), appended to `/3`.
    suspend fun getJson(path: String, maxBodyBytes: Int? = null): JSONObject? = withContext(Dispatchers.IO) {
        val timeout = if (maxBodyBytes == null) TIMEOUT_MS else BOUNDED_TIMEOUT_MS
        val deadline = System.nanoTime() + timeout * 1_000_000L
        var connection: HttpURLConnection? = null
        try {
            val url = URL(EDGE_BASE + path)
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = timeout
                readTimeout = timeout
                useCaches = false
                if (maxBodyBytes != null) instanceFollowRedirects = false
            }
            VortXEdgeAuth.sign(connection)
            if (connection.responseCode != 200) return@withContext null
            val text = if (maxBodyBytes == null) {
                connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            } else {
                connection.inputStream.use { boundedText(it, maxBodyBytes, deadline) } ?: return@withContext null
            }
            runCatching { JSONObject(text) }.getOrNull()
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private fun boundedText(input: InputStream, limit: Int, deadline: Long): String? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (System.nanoTime() - deadline < 0L) {
            val size = input.read(buffer)
            if (size < 0) return if (System.nanoTime() - deadline < 0L) out.toString(Charsets.UTF_8.name()) else null
            if (size > limit - out.size()) return null
            out.write(buffer, 0, size)
        }
        return null
    }
}

/// Like `optString` but null (not "") for a missing or JSON-null value, matching the codebase's existing
/// `optStringOrNull` helpers so optional fields stay absent. Top-level (not a member extension) so the
/// catalog clients can import it directly.
internal fun JSONObject.optStringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return optString(key).ifBlank { null }
}
