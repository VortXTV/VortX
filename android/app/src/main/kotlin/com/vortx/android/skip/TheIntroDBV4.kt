package com.vortx.android.skip

import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/** Public v4 request/response decisions; no Android services, transport, cache, or player state. */
internal object TheIntroDBV4 {
    data class Lookup(val url: String, val cacheKey: String)
    data class Span(val kind: String, val startMs: Int?, val endMs: Int?)

    sealed interface ReadResult {
        data class Media(val spans: List<Span>) : ReadResult
        object NotFound : ReadResult
        object EpisodeList : ReadResult
        object Versions : ReadResult
        object InvalidResponse : ReadResult
        data class HttpFailure(val status: Int) : ReadResult
    }

    fun supports(metaId: String): Boolean = identity(metaId) != null

    fun lookup(metaId: String, season: Int?, episode: Int?, durationSeconds: Double): Lookup? {
        val identity = identity(metaId) ?: return null
        val items = mutableListOf("${identity.first}=${identity.second}")
        val coordinates = when {
            season == null && episode == null -> "movie"
            season != null && episode != null -> {
                if (season !in 0..1000 || episode !in 0..10000) return null
                items += "season=$season"
                items += "episode=$episode"
                "tv:$season:$episode"
            }
            else -> return null
        }
        // The media ref carries catalogue coordinates, not a server display order. Do not invent mapping.
        val milliseconds = durationSeconds * 1000.0
        val durationMs = milliseconds.takeIf {
            durationSeconds.isFinite() && durationSeconds > 0 && it.isFinite() &&
                it >= 1.0 && it < Long.MAX_VALUE.toDouble()
        }?.toLong()
        if (durationMs != null) items += "duration_ms=$durationMs"
        val durationKey = durationMs?.toString() ?: "unknown"
        // All query values above are validated ASCII identifiers/numbers, requiring no URL escaping.
        return Lookup(
            url = "https://api.theintrodb.org/v4/media?${items.joinToString("&")}",
            cacheKey = "introdb:v4:${identity.first}=${identity.second}:$coordinates:$durationKey",
        )
    }

    fun read(status: Int, body: String): ReadResult {
        if (status == 404) return ReadResult.NotFound
        if (status != 200) return ReadResult.HttpFailure(status)
        if (body.indexOf('\u0000') >= 0) return ReadResult.InvalidResponse
        return try {
            val tokener = JSONTokener(body)
            val root = JSONObject(tokener)
            require(tokener.nextClean() == '\u0000') // Do not cache a valid envelope followed by another payload.
            require(integer(root.get("tvdb_id"), 100_000_000) >= 1)
            val type = root.get("type")
            require(type == "movie" || type == "tv")
            val kinds = listOf("intro", "recap", "credits", "preview")
            val episodes = root.has("episodes")
            val versions = root.has("versions")
            if (episodes || versions) {
                require(!(episodes && versions) && kinds.none(root::has))
                root.getJSONArray(if (episodes) "episodes" else "versions")
                if (episodes) ReadResult.EpisodeList else ReadResult.Versions
            } else {
                val spans = mutableListOf<Span>()
                for (kind in kinds) {
                    if (!root.has(kind)) continue
                    val array = root.getJSONArray(kind)
                    for (index in 0 until array.length()) {
                        val span = array.getJSONObject(index)
                        spans += Span(kind, nullableBound(span, "start_ms"), nullableBound(span, "end_ms"))
                    }
                }
                ReadResult.Media(spans)
            }
        } catch (_: JSONException) {
            ReadResult.InvalidResponse
        } catch (_: IllegalArgumentException) {
            ReadResult.InvalidResponse
        }
    }

    private fun identity(metaId: String): Pair<String, String>? {
        if (metaId.startsWith("tt")) {
            val digits = metaId.drop(2)
            if (digits.length !in 7..8 || digits.any { it !in '0'..'9' }) return null
            return "imdb_id" to metaId
        }
        for ((prefix, name, maximum) in listOf(Triple("tvdb:", "tvdb_id", 100_000_000), Triple("tmdb:", "tmdb_id", 10_000_000))) {
            if (!metaId.startsWith(prefix)) continue
            val suffix = metaId.removePrefix(prefix)
            if (suffix.isEmpty() || suffix.any { it !in '0'..'9' }) return null
            val id = suffix.toIntOrNull() ?: return null
            return if (id in 1..maximum) name to id.toString() else null
        }
        return null
    }

    private fun nullableBound(root: JSONObject, key: String): Int? {
        val value = root.get(key) // Required nullable field: missing must not become a whole-file span.
        return if (value == JSONObject.NULL) null else integer(value)
    }

    // Android's existing StoredSpan uses Int milliseconds. Reject overflow instead of narrowing it;
    // leave zero-length/reversed spans intact for the existing SegmentResolver sanity policy.
    private fun integer(value: Any, maximum: Int = Int.MAX_VALUE): Int {
        require(value is Number)
        val number = value.toDouble()
        require(number.isFinite() && number >= 0 && number <= maximum && number % 1.0 == 0.0)
        return number.toInt()
    }
}
