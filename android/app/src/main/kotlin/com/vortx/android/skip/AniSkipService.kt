package com.vortx.android.skip

import android.util.Log
import org.json.JSONObject

/// Layer 2b: AniSkip (api.aniskip.com), the anime-specialized opening/ending/recap timestamp database the
/// desktop anime players use. Keyed by MAL id + episode, which TheIntroDB is not, so it fills the gap for
/// the `kitsu:` / `mal:` ids anime add-ons hand out. Fail-soft throughout: an unmapped id, a 404, or a
/// network error just yields [], and [SegmentResolver] clamps whatever comes back. Kotlin port of the Apple
/// `AniSkipService` in `SkipTimestampService.swift`.
object AniSkipService {

    private const val TAG = "skiptimes"

    /// Cheap sync check (no network) used by the player's skip gate: AniSkip can handle the anime id
    /// schemes. The actual MAL resolution + fetch happen in [candidates], which fails soft if they miss.
    /// Mirrors Apple `AniSkipService.supports`.
    fun supports(metaId: String): Boolean =
        listOf("kitsu:", "mal:", "anilist:", "anidb:").any { metaId.startsWith(it) }

    suspend fun candidates(metaId: String, episode: Int?, durationSeconds: Double): List<SegmentCandidate> {
        if (durationSeconds <= 0 || episode == null || episode <= 0) return emptyList()
        val mal = malId(metaId) ?: return emptyList()
        val url = "https://api.aniskip.com/v2/skip-times/$mal/$episode" +
            "?types%5B%5D=op&types%5B%5D=ed&types%5B%5D=recap&episodeLength=${durationSeconds.toInt()}"
        val res = SkipHttp.request("GET", url)
        if (res.status != 200) return emptyList()
        val obj = runCatching { JSONObject(res.body) }.getOrNull() ?: run {
            Log.i(TAG, "aniskip mal $mal ep $episode: decode failed")
            return emptyList()
        }
        // AniSkip omits `found` / `results` on a not-found episode ({"found": false}); a genuinely absent
        // key reads soft (found=false, results=[]), matching Apple's `decodeIfPresent ?? false / ?? []`.
        if (!obj.optBoolean("found", false)) return emptyList()
        val results = obj.optJSONArray("results") ?: return emptyList()
        val out = mutableListOf<SegmentCandidate>()
        for (i in 0 until results.length()) {
            val r = results.optJSONObject(i) ?: continue
            val kind = when (r.optString("skipType")) {
                "op" -> SkipSegment.Kind.INTRO
                "ed" -> SkipSegment.Kind.CREDITS
                "recap" -> SkipSegment.Kind.RECAP
                else -> continue
            }
            val interval = r.optJSONObject("interval") ?: continue
            val start = interval.optDouble("startTime", Double.NaN)
            val end = interval.optDouble("endTime", Double.NaN)
            if (start.isNaN() || end.isNaN()) continue
            out.add(SegmentCandidate(kind, start, end, SegmentCandidate.Source.CROWD_API, 0.92))
        }
        return out
    }

    /// Resolve a MAL id from a Stremio anime id. `mal:` is direct; `kitsu:` resolves through the Kitsu
    /// mappings API. `anilist:` / `anidb:` are not mapped yet (they need a relations index), so they fail
    /// soft to null. Mirrors Apple `AniSkipService.malId`.
    private suspend fun malId(metaId: String): Int? {
        if (metaId.startsWith("mal:")) {
            return metaId.removePrefix("mal:").split(":").firstOrNull()?.toIntOrNull()
        }
        // Take the id token right after the prefix, NOT the last: an episode-qualified id like
        // "kitsu:123:1:2" must resolve from anime id 123, not the trailing episode number.
        if (metaId.startsWith("kitsu:")) {
            val kitsu = metaId.removePrefix("kitsu:").split(":").firstOrNull()
            if (kitsu != null && kitsu.toIntOrNull() != null) return kitsuToMal(kitsu)
        }
        return null
    }

    private suspend fun kitsuToMal(kitsuId: String): Int? {
        val url = "https://kitsu.io/api/edge/anime/$kitsuId/mappings"
        val res = SkipHttp.request("GET", url, headers = mapOf("Accept" to "application/vnd.api+json"))
        if (res.status != 200) return null
        val obj = runCatching { JSONObject(res.body) }.getOrNull() ?: return null
        val rows = obj.optJSONArray("data") ?: return null
        for (i in 0 until rows.length()) {
            val row = rows.optJSONObject(i) ?: continue
            val attrs = row.optJSONObject("attributes") ?: continue
            if (attrs.optString("externalSite") == "myanimelist/anime") {
                val ext = attrs.optString("externalId").toIntOrNull()
                if (ext != null) return ext
            }
        }
        return null
    }
}
