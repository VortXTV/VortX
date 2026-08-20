package com.vortx.android.ratings

import android.content.Context
import com.vortx.android.metadata.MetadataProviderKeys
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.math.roundToInt

/// Compact ratings from MDBList, used ONLY when the user has set their own MDBList key (Settings ›
/// Metadata keys, stored encrypted in [MetadataProviderKeys]). The Kotlin port of Apple
/// `app/SourcesShared/MDBListClient.ratings`, it fills the cross-provider scores (Rotten Tomatoes /
/// Metacritic) the keyless [VortXRatingsClient] did not return, so most users still need no key at all.
///
/// SECURITY: the api key is the only untrusted input and it NEVER lands in the URL path -- it rides as a
/// percent-encoded `apikey` QUERY value ([URLEncoder]), while the imdb id is validated (`tt` + digits) and
/// the media type is one of two literals, exactly like Apple's URLComponents construction. Fail-soft:
/// returns null when no key is set, the id is not a well-formed imdb id, or anything goes wrong, so the
/// detail ratings row simply keeps whatever the VortX service returned.
object MdbListClient {

    private const val HOST = "https://api.mdblist.com"
    private const val TIMEOUT_MS = 15_000

    /// Ratings for an IMDb id using the user's own MDBList key. [type] is the stremio type ("movie" /
    /// "series"); MDBList keys a series under "show". Null when no key is set, the id is not a well-formed
    /// imdb id, or on any transport / decode error. Mirrors Apple `MDBListClient.ratings`.
    suspend fun ratings(context: Context, imdbId: String, type: String): MdbListRatings? {
        if (!isImdbId(imdbId)) return null
        val key = MetadataProviderKeys(context).value(MetadataProviderKeys.Slot.MDBLIST)
        if (key.isEmpty()) return null
        val mediaType = if (type == "series") "show" else "movie"
        val encodedKey = URLEncoder.encode(key, "UTF-8")
        val root = getJson("$HOST/imdb/$mediaType/$imdbId?apikey=$encodedKey") ?: return null
        val entries = root.optJSONArray("ratings") ?: return null

        val bySource = HashMap<String, Double>()
        for (i in 0 until entries.length()) {
            val entry = entries.optJSONObject(i) ?: continue
            val source = entry.optString("source").takeIf { it.isNotEmpty() } ?: continue
            val value = numeric(entry, "value") ?: continue
            bySource[source] = value
        }
        // MDBList source keys: imdb / tomatoes / metacritic / tmdb (RT is "tomatoes", NOT "rt"), matching the
        // Apple client's `bySource["tomatoes"]` read. RT/MC/TMDB round to an Int like the VortX service does.
        val ratings = MdbListRatings(
            imdb = bySource["imdb"],
            rottenTomatoes = bySource["tomatoes"]?.roundToInt(),
            metacritic = bySource["metacritic"]?.roundToInt(),
            tmdb = bySource["tmdb"]?.roundToInt(),
        )
        return if (ratings.hasAny) ratings else null
    }

    /// True for a well-formed IMDb id ("tt" + one or more digits), so a value with an odd shape or
    /// query-breaking characters never reaches the composed URL. Mirrors Apple `MDBListClient.isImdbID`.
    private fun isImdbId(id: String): Boolean {
        if (!id.startsWith("tt")) return false
        val digits = id.drop(2)
        return digits.isNotEmpty() && digits.all { it in '0'..'9' }
    }

    /// A numeric JSON field (Int or Double) as a Double, or null when absent / non-numeric. MDBList sends
    /// ratings as JSON numbers; mirrors Apple `MDBListClient.numeric`.
    private fun numeric(obj: JSONObject, key: String): Double? {
        if (!obj.has(key) || obj.isNull(key)) return null
        return (obj.opt(key) as? Number)?.toDouble()
    }

    /// GET [urlString] and decode a JSON object. Runs on [Dispatchers.IO]; a non-200 or any transport error
    /// resolves to null so every caller stays fail-soft.
    private suspend fun getJson(urlString: String): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
                setRequestProperty("accept", "application/json")
            }
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
