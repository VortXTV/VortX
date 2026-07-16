package com.vortx.android.skip

import android.content.Context
import android.util.Log
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.json.JSONObject
import java.io.File

/// Layer 2: crowd-sourced skip timestamps merging our own keyless skip.vortx.tv worker (primary, VortX
/// edge-signed) with TheIntroDB (theintrodb.org), SkipDB (skipdb.tv), the user's optional custom mirror,
/// and AniSkip (anime). Looked up by the IMDB id the app already has from Cinemeta (+ season/episode for
/// series, nothing for movies); reads are anonymous. Results, and misses, cache to disk so an episode costs
/// one request per provider, not one per play. Kotlin port of the Apple `SkipTimestampService`.
///
/// [init] wires the disk cache + config (idempotent). The player calls it before [candidates]; the store is
/// consulted through nullable guards, so an un-inited call still works (network only, no caching).
object SkipTimestampService {

    private const val TAG = "skiptimes"

    @Volatile private var store: SkipTimestampStore? = null

    /// Idempotent init: wire the disk cache (a JSON file in the app cache dir, mirroring Apple's caches-dir
    /// `skip-timestamps.json`) + the provider config. Safe to call from every entry point.
    fun init(context: Context) {
        if (store == null) {
            synchronized(this) {
                if (store == null) {
                    store = SkipTimestampStore(File(context.applicationContext.cacheDir, "skip-timestamps.json"))
                }
            }
        }
        SkipConfig.init(context)
    }

    /// The store, for [SkipDBClient.invalidateCache] to purge the VortX entry after a submit.
    internal fun storeOrNull(): SkipTimestampStore? = store

    /// All skip candidates for a title, merging skip.vortx.tv (primary, keyless) with the chosen crowd
    /// source(s), the user's optional custom provider, and AniSkip. The VortX worker already aggregates
    /// SkipDB plus capture-on-miss server-side, so it leads; the others stay as fallback. [metaId] is the
    /// Stremio meta id (a `tt…` id from the player's resolved media ref, or a `kitsu:`/`mal:` anime id):
    /// each provider self-guards, so a `tt` id no-ops AniSkip and an anime id no-ops the imdb-keyed legs,
    /// exactly as the single Apple `imdbId` parameter does. Mirrors Apple `SkipTimestampService.candidates`.
    suspend fun candidates(
        metaId: String,
        season: Int?,
        episode: Int?,
        durationSeconds: Double,
    ): List<SegmentCandidate> = coroutineScope {
        val vortx = async { vortxSkip(metaId, season, episode, durationSeconds) }
        val custom = async { customSkip(metaId, season, episode, durationSeconds) }
        val aniskip = async { AniSkipService.candidates(metaId, episode, durationSeconds) }
        val crowd = when (SkipConfig.provider) {
            "skipdb" -> async { skipDB(metaId, season, episode, durationSeconds) }
            "both" -> async {
                val introdb = async { theIntroDB(metaId, season, episode, durationSeconds) }
                val skipdb = async { skipDB(metaId, season, episode, durationSeconds) }
                introdb.await() + skipdb.await()
            }
            else -> async { theIntroDB(metaId, season, episode, durationSeconds) } // "theintrodb"
        }
        vortx.await() + crowd.await() + custom.await() + aniskip.await()
    }

    /// Cache key for the VortX worker, bucketed by runtime like the other providers. Mirrors Apple
    /// `SkipTimestampService.vortxCacheKey`.
    fun vortxCacheKey(imdbId: String, season: Int?, episode: Int?, durationSeconds: Double): String {
        val durationBucket = (durationSeconds / 10).toInt() * 10
        return "vortx:$imdbId:${season ?: 0}:${episode ?: 0}:$durationBucket"
    }

    fun supports(metaId: String): Boolean = queryPair(metaId) != null || AniSkipService.supports(metaId)

    // MARK: - Providers

    /// Layer 2 (primary): our self-hosted, keyless skip.vortx.tv worker (edge-signed). Keyed by
    /// `imdb:tt#:S:E` for an episode or `imdb:tt#` for a film. Fail-soft: any non-200, timeout, or parse
    /// error yields []. Mirrors Apple `vortxSkip`.
    private suspend fun vortxSkip(imdbId: String, season: Int?, episode: Int?, durationSeconds: Double): List<SegmentCandidate> {
        if (!IMDB_REGEX.matches(imdbId)) return emptyList()
        val key = vortxCacheKey(imdbId, season, episode, durationSeconds)
        store?.entry(key)?.let { cached ->
            Log.i(TAG, "cache hit $key: ${cached.spans.size} spans")
            return candidatesFrom(cached.spans, durationSeconds, confidence = 0.95)
        }

        val lookup = if (season != null && episode != null) "imdb:$imdbId:$season:$episode" else "imdb:$imdbId"
        // skip.vortx.tv is a gated host, so SkipHttp signs it. The `key` query is not part of the signed
        // message (VortXEdgeAuth signs METHOD + path + ts only), so its values need no special encoding.
        val url = "https://skip.vortx.tv/skip?key=$lookup"
        val res = SkipHttp.request("GET", url)
        if (res.status != 200) {
            Log.i(TAG, "$key: VortX skip non-200 (${res.status})")
            return emptyList()
        }
        val spans = parseVortXSkip(res.body) ?: return emptyList()
        Log.i(TAG, "$key: ${spans.size} spans from VortX")
        // A miss returns {"segments": {}} 200; store it so a missing title costs one ask per day.
        store?.store(SkipTimestampStore.Entry(System.currentTimeMillis(), spans, null), key)
        return candidatesFrom(spans, durationSeconds, confidence = 0.95)
    }

    /// Layer 2a: TheIntroDB crowd spans (any media, keyed by imdb/tmdb/tvdb id). Mirrors Apple `theIntroDB`.
    private suspend fun theIntroDB(metaId: String, season: Int?, episode: Int?, durationSeconds: Double): List<SegmentCandidate> {
        val idParam = queryPair(metaId) ?: return emptyList()
        val durationBucket = (durationSeconds / 10).toInt() * 10
        val key = "$metaId:${season ?: 0}:${episode ?: 0}:$durationBucket"
        store?.entry(key)?.let { cached ->
            Log.i(TAG, "cache hit $key: ${cached.spans.size} spans")
            return candidatesFrom(cached.spans, durationSeconds)
        }

        val sb = StringBuilder("https://api.theintrodb.org/v3/media?${idParam.first}=${idParam.second}")
        if (season != null && episode != null) sb.append("&season=$season&episode=$episode")
        if (durationSeconds > 0) sb.append("&duration_ms=${(durationSeconds * 1000).toInt()}")
        val res = SkipHttp.request("GET", sb.toString())
        if (res.status == 404) { // known-missing: cache so we retry daily, not per play
            Log.i(TAG, "$key: not in the database")
            store?.store(SkipTimestampStore.Entry.miss(), key)
            return emptyList()
        }
        if (res.status != 200) { // rate-limit / server error: retry next play
            Log.i(TAG, "$key: HTTP ${res.status}")
            return emptyList()
        }
        val spans = parseTheIntroDB(res.body) ?: return emptyList()
        Log.i(TAG, "$key: ${spans.size} spans fetched")
        store?.store(SkipTimestampStore.Entry(System.currentTimeMillis(), spans, null), key)
        return candidatesFrom(spans, durationSeconds)
    }

    /// Layer 2b: SkipDB crowd spans (any media, keyed by IMDB id only). Mirrors Apple `skipDB`.
    private suspend fun skipDB(imdbId: String, season: Int?, episode: Int?, durationSeconds: Double): List<SegmentCandidate> =
        skipDBCompatible(
            base = "https://api.skipdb.tv", apiKey = SkipConfig.skipDBKey(),
            cachePrefix = "skipdb", label = "SkipDB",
            imdbId = imdbId, season = season, episode = episode, durationSeconds = durationSeconds,
        )

    /// Layer 2c: the user's optional custom SkipDB-compatible provider. Reuses the SkipDB read path,
    /// parameterized by base URL + key, cached under a distinct `customskip:<host>:...` prefix. NOT VortX
    /// edge-signed: third-party host. Mirrors Apple `customSkip`.
    private suspend fun customSkip(imdbId: String, season: Int?, episode: Int?, durationSeconds: Double): List<SegmentCandidate> {
        val base = CustomSkipProvider.baseURL() ?: return emptyList()
        val host = CustomSkipProvider.host() ?: return emptyList()
        return skipDBCompatible(
            base = base, apiKey = SkipConfig.customSkipKey(),
            cachePrefix = "customskip:$host", label = "custom skip provider",
            imdbId = imdbId, season = season, episode = episode, durationSeconds = durationSeconds,
        )
    }

    /// Shared read path for any SkipDB-compatible `<base>/api/segments` endpoint. Keyed by IMDB id only.
    /// Mirrors Apple `skipDBCompatible`.
    private suspend fun skipDBCompatible(
        base: String, apiKey: String?, cachePrefix: String, label: String,
        imdbId: String, season: Int?, episode: Int?, durationSeconds: Double,
    ): List<SegmentCandidate> {
        if (!IMDB_REGEX.matches(imdbId)) return emptyList()
        val durationBucket = (durationSeconds / 10).toInt() * 10
        val key = "$cachePrefix:$imdbId:${season ?: 0}:${episode ?: 0}:$durationBucket"
        store?.entry(key)?.let { cached ->
            Log.i(TAG, "cache hit $key: ${cached.spans.size} spans")
            return candidatesFrom(cached.spans, durationSeconds)
        }

        val sb = StringBuilder("$base/api/segments?imdb_id=$imdbId")
        if (season != null && episode != null) sb.append("&season=$season&episode=$episode")
        if (durationSeconds > 0) sb.append("&duration=${durationSeconds.toInt()}")
        val headers = if (apiKey != null) mapOf("Authorization" to "Bearer $apiKey") else emptyMap()
        // No VortX signing here: skipdb.tv and the custom mirror are third-party hosts (SkipHttp's sign() is
        // a no-op for them anyway).
        val res = SkipHttp.request("GET", sb.toString(), headers = headers)
        if (res.status == 404) {
            Log.i(TAG, "$key: not in $label")
            store?.store(SkipTimestampStore.Entry.miss(), key)
            return emptyList()
        }
        if (res.status != 200) {
            Log.i(TAG, "$key: $label HTTP ${res.status}")
            return emptyList()
        }
        val parsed = parseSkipDB(res.body) ?: return emptyList()
        Log.i(TAG, "$key: ${parsed.first.size} spans from $label")
        store?.store(SkipTimestampStore.Entry(System.currentTimeMillis(), parsed.first, parsed.second), key)
        return candidatesFrom(parsed.first, durationSeconds)
    }

    // MARK: - Id mapping

    /// Maps a Stremio meta id to the API's id parameter `(name, value)`. IMDB ("tt123…"), or namespaced
    /// "tmdb:123" / "tvdb:123". Mirrors Apple `queryItem(for:)`.
    private fun queryPair(metaId: String): Pair<String, String>? {
        if (IMDB_REGEX.matches(metaId)) return "imdb_id" to metaId
        if (metaId.startsWith("tmdb:")) metaId.removePrefix("tmdb:").toIntOrNull()?.let { return "tmdb_id" to it.toString() }
        if (metaId.startsWith("tvdb:")) metaId.removePrefix("tvdb:").toIntOrNull()?.let { return "tvdb_id" to it.toString() }
        return null
    }

    /// null intro start = from 0; null credits end = to end of file. Mirrors Apple `candidates(from:...)`.
    private fun candidatesFrom(spans: List<StoredSpan>, duration: Double, confidence: Double = 0.9): List<SegmentCandidate> =
        spans.mapNotNull { span ->
            val kind = SkipSegment.Kind.fromRaw(span.kind) ?: return@mapNotNull null
            val start = span.startMs?.let { it / 1000.0 } ?: 0.0
            val end = span.endMs?.let { it / 1000.0 } ?: duration
            SegmentCandidate(kind, start, end, SegmentCandidate.Source.CROWD_API, confidence)
        }

    // MARK: - Response parsing (org.json equivalents of the Apple Decodable structs)

    /// TheIntroDB `/v3/media`: up to four arrays of `{start_ms, end_ms}`, either side nullable.
    private fun parseTheIntroDB(body: String): List<StoredSpan>? {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return null
        val out = mutableListOf<StoredSpan>()
        for (kind in listOf("intro", "recap", "credits", "preview")) {
            val arr = root.optJSONArray(kind) ?: continue
            for (i in 0 until arr.length()) {
                val s = arr.optJSONObject(i) ?: continue
                out.add(StoredSpan(kind, s.optIntOrNull("start_ms"), s.optIntOrNull("end_ms")))
            }
        }
        return out
    }

    /// SkipDB `/api/segments`: one object per type (or null / excluded). `outro` maps to "credits". Returns
    /// (spans, intro_length_estimate_ms). Include a span only when start_ms is present (Apple's guard).
    private fun parseSkipDB(body: String): Pair<List<StoredSpan>, Int?>? {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return null
        // `segments` is required in the SkipDB schema (Apple's `SkipDBResponse.segments` is non-optional);
        // a 200 without it is malformed, so return null (no cache) rather than caching a phantom miss.
        val segments = root.optJSONObject("segments") ?: return null
        val out = mutableListOf<StoredSpan>()
        addSpan(out, segments, wire = "intro", kind = "intro")
        addSpan(out, segments, wire = "recap", kind = "recap")
        addSpan(out, segments, wire = "outro", kind = "credits")
        addSpan(out, segments, wire = "preview", kind = "preview")
        return Pair(out, root.optIntOrNull("intro_length_estimate_ms"))
    }

    /// skip.vortx.tv `/skip`: `{ "segments": { "<type>": { "start_ms", "end_ms", ... }, ... } }`. Types are
    /// intro / recap / outro / preview / post_credit; `outro` maps to "credits" and `post_credit` is dropped.
    private fun parseVortXSkip(body: String): List<StoredSpan>? {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return null
        // A genuine miss returns `{"segments": {}}` (present, empty -> optJSONObject is a non-null empty
        // object, parsed to []), which the caller caches. A response with NO `segments` key is malformed
        // (Apple's `VortXSkipResponse.segments` is non-optional), so return null (no cache).
        val segments = root.optJSONObject("segments") ?: return null
        val out = mutableListOf<StoredSpan>()
        addSpan(out, segments, wire = "intro", kind = "intro")
        addSpan(out, segments, wire = "recap", kind = "recap")
        addSpan(out, segments, wire = "outro", kind = "credits")
        addSpan(out, segments, wire = "preview", kind = "preview")
        // post_credit intentionally dropped (no matching SkipSegment.Kind), matching Apple.
        return out
    }

    /// Append the [wire]-named segment under [kind] IFF present and it carries a start_ms (Apple's
    /// `guard let s = span, s.start_ms != nil`).
    private fun addSpan(out: MutableList<StoredSpan>, segments: JSONObject, wire: String, kind: String) {
        val span = segments.optJSONObject(wire) ?: return
        val startMs = span.optIntOrNull("start_ms") ?: return
        out.add(StoredSpan(kind, startMs, span.optIntOrNull("end_ms")))
    }

    private val IMDB_REGEX = Regex("^tt\\d{7,8}$")
}
