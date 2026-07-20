package com.vortx.android.ratings

import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.roundToInt

/// VortX's own ratings service (https://ratings.vortx.tv): cross-provider ratings with NO user key
/// required. IMDb is keyless (sourced from Cinemeta); Rotten Tomatoes / Metacritic / TMDB come from a
/// single VortX-owned MDBList key held server-side, so no user ever needs their own. Fails soft (returns
/// null) and maps into the SAME [MdbListRatings] model so the detail ratings row renders unchanged. On by
/// default. Kotlin port of the Apple `VortXRatingsClient`.
///
/// `ratings.vortx.tv` is one of [VortXEdgeAuth]'s gated hosts, so every request is edge-signed (the same
/// HMAC contract the rest of the app's gated hosts use). A power user could point at a custom base or
/// disable it entirely on Apple via `UserDefaults`; Android has no such settings surface yet, so the
/// shipping build is always-on against the default base (the common path), with [configure] available for
/// a future Streams-settings screen to wire.
object VortXRatingsClient {

    private const val DEFAULT_BASE = "https://ratings.vortx.tv"
    private const val TIMEOUT_MS = 15_000

    @Volatile private var base: String = DEFAULT_BASE
    @Volatile private var enabled: Boolean = true

    /// Optional override for a later settings screen (Apple's `baseKey` / `enabledKey`). [customBase] is
    /// validated as http(s) and trailing-slash trimmed; a null/blank/invalid base falls back to the VortX
    /// service. Mirrors Apple `VortXRatingsClient.base` / `isEnabled`.
    fun configure(customBase: String?, isEnabled: Boolean) {
        enabled = isEnabled
        var s = (customBase ?: "").trim()
        while (s.endsWith("/")) s = s.dropLast(1)
        base = if (s.startsWith("http://") || s.startsWith("https://")) s else DEFAULT_BASE
        if (base.isEmpty()) base = DEFAULT_BASE
    }

    /// Ratings for an IMDb id, no key needed. [type] is the stremio type ("movie"/"series"). Returns null
    /// when disabled, the id is not an imdb id, or anything goes wrong (fail-soft). Mirrors Apple
    /// `VortXRatingsClient.ratings(imdbID:type:)`.
    suspend fun ratings(imdbId: String, type: String): MdbListRatings? {
        if (!enabled || !imdbId.startsWith("tt")) return null
        val mediaType = if (type == "series") "series" else "movie"
        val root = getSigned("$base/v1/ratings/$mediaType/$imdbId") ?: return null
        // IMDb on its native 0-10 scale; RT / Metacritic / TMDB as 0-100, matching the MdbListRatings model.
        val r = MdbListRatings(
            imdb = numeric(root, "imdb"),
            rottenTomatoes = numeric(root, "rt")?.roundToInt(),
            metacritic = numeric(root, "metacritic")?.roundToInt(),
            tmdb = numeric(root, "tmdb")?.roundToInt(),
        )
        return if (r.hasAny) r else null
    }

    /// GET [urlString] off the gated ratings host, edge-signed, decode a JSON object. Runs on
    /// [Dispatchers.IO]; a non-200 or any transport error resolves to null so every caller stays fail-soft.
    private suspend fun getSigned(urlString: String): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
            }
            // Stamp X-VX-* for the gated ratings.vortx.tv host (no-op for a custom base on a non-gated host).
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

    /// A numeric JSON field as a Double, or null when absent / non-numeric. Mirrors Apple `numeric(_:)`,
    /// which reads only Double / Int / NSNumber: a JSON STRING value is deliberately NOT coerced (a
    /// string-numeric is ignored on Apple), so this checks for [Number] only.
    private fun numeric(root: JSONObject, key: String): Double? {
        if (!root.has(key) || root.isNull(key)) return null
        return (root.opt(key) as? Number)?.toDouble()
    }
}
