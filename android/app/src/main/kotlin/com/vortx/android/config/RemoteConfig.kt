package com.vortx.android.config

import android.content.Context
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * VortX RemoteConfig (Android): tune / kill / upgrade shipped app behavior from a backend JSON with NO app
 * update. The full port of Apple `app/SourcesShared/RemoteConfig.swift`, matched on the endpoint, the JSON
 * schema field names, the HMAC signing, and the tri-state feature semantics.
 *
 * DESIGN CONTRACT (why this is safe on hot paths and safe when the backend is gone):
 *
 *   1. EVERY accessor has a HARDCODED baked default equal to the current shipping value. Deleting this
 *      service, or a remote field being null, is behaviorally identical to today. [RemoteConfigDefaults]
 *      holds one named constant per dial; accessors read the (already-resolved) value or that default.
 *
 *   2. Reads are SYNCHRONOUS and LOCK-FREE. Callers read on hot-ish paths (collections hub build, trickplay
 *      capture, detail open), so a read must never take a lock or hop a coroutine. [snapshot] is a `@Volatile`
 *      immutable [Snapshot] that is only ever REPLACED, never mutated: a reader sees either the old or the new
 *      fully-formed value, never torn state. It starts baked so a read before [bootstrap] is shipping-correct.
 *
 *   3. Clamp ONCE, at swap time. [validate] turns raw decoded JSON into a [Snapshot] whose every non-feature
 *      value is already range-clamped and defaults-filled, exactly as Apple's `validate` does. An ABSENT field
 *      falls back to the baked default; an OUT-OF-RANGE field is CLAMPED TO THE NEAREST EDGE of its range.
 *
 *   4. Feature tri-state (Apple's `isFeatureOn(_:default:)`). [Snapshot.features] holds ONLY the boolean keys
 *      the remote config actually carried, so a PRESENT `false` acts as a fleet KILL-SWITCH (it wins over the
 *      call site's default) while an ABSENT key falls through to the baked default the call site passes. The
 *      "set vs absent" two-probe Apple's player router uses (`isFeatureOn(k, true) == isFeatureOn(k, false)`
 *      iff the key is present) works here too, and [isFeatureSet] / [Snapshot.featureValue] expose it directly.
 *
 *   5. FAIL-SOFT everywhere. Any fetch / decode / disk error keeps the last-good snapshot (or baked defaults);
 *      nothing throws out of [bootstrap] / [refresh]. A remote `master.remoteConfigEnabled == false` discards a
 *      fetched config back to baked and is NOT persisted (removing the field restores it). A corrupt cache is
 *      treated as absent => baked.
 *
 * ETAG / 304 CACHING (mirrors Apple's `If-None-Match` path): the last-good raw JSON body and its `ETag` are
 * persisted. Each refresh sends `If-None-Match: <etag>`; a `304 Not Modified` is a genuine no-op that keeps the
 * cached snapshot without re-decoding, and a `200` swaps the snapshot and re-persists the body + new ETag.
 *
 * SIGNING: the config GET is signed with the SAME HMAC helper ([VortXEdgeAuth.sign]) every other gated
 * `*.vortx.tv` worker uses; `config.vortx.tv` is one of that helper's gated hosts. With no secret provisioned
 * the signature is a safe no-op the worker's observe mode allows, so an unprovisioned build fetches the same.
 */
object RemoteConfig {
    private const val CONFIG_URL = "https://config.vortx.tv/v1/config.json"
    private const val FETCH_TIMEOUT_MS = 8_000
    private const val PREFS_FILE = "vortx_remote_config"

    /** Last-good raw JSON body (so a 304 keeps the snapshot and a bootstrap re-validates without a network). */
    private const val KEY_RAW = "vortx.remoteConfig.raw"

    /** The ETag of the last-good body, replayed as `If-None-Match` so an unchanged config 304s. */
    private const val KEY_ETAG = "vortx.remoteConfig.etag"

    @Volatile
    private var snapshot: Snapshot = Snapshot.baked()

    /** The current snapshot (baked until [bootstrap] loads a cached / fetched config). Read lock-free. */
    fun current(): Snapshot = snapshot

    /** Convenience: tri-state [Snapshot.isFeatureOn] against the current snapshot. */
    fun isFeatureOn(key: String, default: Boolean): Boolean = snapshot.isFeatureOn(key, default)

    /** Whether the current snapshot carries an explicit remote value for [key] (present true OR present false). */
    fun isFeatureSet(key: String): Boolean = snapshot.isFeatureSet(key)

    /**
     * (1) Synchronously load the last-good cached JSON and build the snapshot (else all-baked).
     * (2) Kick a single background refresh on [scope]. Never throws; safe to call once at process start.
     */
    fun bootstrap(context: Context, scope: CoroutineScope) {
        val appContext = context.applicationContext
        loadCachedSnapshot(appContext)?.let { snapshot = it }
        scope.launch { runCatching { refresh(appContext) } }
    }

    /**
     * GET the config with `If-None-Match: <etag>`. 304 => keep last-good. 200 => decode -> validate/clamp -> if
     * `master.remoteConfigEnabled == false` discard to baked (NOT persisted), else swap snapshot + persist the
     * body + new ETag. ANY error keeps the last-good snapshot.
     */
    private suspend fun refresh(context: Context) = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val etag = loadEtag(context)
            connection = (URL(CONFIG_URL).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = FETCH_TIMEOUT_MS
                readTimeout = FETCH_TIMEOUT_MS
                // Manage revalidation ourselves via If-None-Match; do not let the URL cache shadow it.
                useCaches = false
                setRequestProperty("accept", "application/json")
                if (!etag.isNullOrEmpty()) setRequestProperty("If-None-Match", etag)
            }
            VortXEdgeAuth.sign(connection)
            when (connection.responseCode) {
                HttpURLConnection.HTTP_NOT_MODIFIED -> return@withContext   // 304: still fresh, keep last-good
                HttpURLConnection.HTTP_OK -> Unit
                else -> return@withContext                                  // any other status: keep last-good
            }
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val root = JSONObject(text)
            // master.remoteConfigEnabled == false is the whole-system kill switch: discard to baked and do NOT
            // persist, so deleting the field restores the last-good behavior on the next fetch.
            if (masterDisabled(root)) {
                snapshot = Snapshot.baked()
                return@withContext
            }
            snapshot = validate(root)
            persist(context, rawJson = text, etag = connection.getHeaderField("ETag"))
        } catch (_: Exception) {
            // Timeout / offline / decode failure: keep last-good. Never throw.
        } finally {
            connection?.disconnect()
        }
    }

    // MARK: - Validation + clamping (the ONE place ranges are enforced; mirrors Apple `validate`).

    /**
     * Turn a decoded config object into a fully clamped, defaults-filled [Snapshot]. Every out-of-range or
     * non-conforming value falls back to its baked default (absent) or the nearest range edge (out of range).
     */
    private fun validate(root: JSONObject): Snapshot {
        val features = parseFeatures(root.optJSONObject("features"))

        // --- Trickplay params. ---
        val trickplay = root.optJSONObject("trickplay")
        val capture = clampInt(optInt(trickplay, "captureIntervalSecs"), RemoteConfigDefaults.CAPTURE_INTERVAL_SECS, 2, 60)
        val minFrames = clampInt(optInt(trickplay, "minFrames"), RemoteConfigDefaults.TRICKPLAY_MIN_FRAMES, 1, 10)
        val maxFrames = clampInt(optInt(trickplay, "maxFrames"), RemoteConfigDefaults.TRICKPLAY_MAX_FRAMES, 30, 600)
        val maxTiles = clampInt(optInt(trickplay, "maxTiles"), RemoteConfigDefaults.TRICKPLAY_MAX_TILES, 30, 400)

        // --- Endpoints: https + host ends ".vortx.tv" or baked default. ---
        val endpoints = root.optJSONObject("endpoints")
        val trickplayUrl = validatedEndpoint(optString(endpoints, "trickplay"), RemoteConfigDefaults.ENDPOINT_TRICKPLAY)
        val catalogsUrl = validatedEndpoint(optString(endpoints, "catalogs"), RemoteConfigDefaults.ENDPOINT_CATALOGS)
        val subtitlesUrl = validatedEndpoint(optString(endpoints, "subtitles"), RemoteConfigDefaults.ENDPOINT_SUBTITLES)
        val sourcesUrl = validatedEndpoint(optString(endpoints, "sources"), RemoteConfigDefaults.ENDPOINT_SOURCES)

        // --- Community-subtitle tunables. ---
        val subtitle = root.optJSONObject("subtitle")
        val subDownloadMs = clampInt(optInt(subtitle, "downloadTimeoutMs"), RemoteConfigDefaults.SUBTITLE_DOWNLOAD_TIMEOUT_MS, 3000, 30000)
        val subUploadMax = clampInt(optInt(subtitle, "uploadMaxBytes"), RemoteConfigDefaults.SUBTITLE_UPLOAD_MAX_BYTES, 65536, 2_097_152)
        val subOffsetBucket = clampInt(optInt(subtitle, "offsetBucketMs"), RemoteConfigDefaults.SUBTITLE_OFFSET_BUCKET_MS, 50, 2000)
        val langMinSeen = clampInt(optInt(root.optJSONObject("langIndex"), "minSeen"), RemoteConfigDefaults.LANG_INDEX_MIN_SEEN, 1, 50)

        // --- Singularity upload/rate tunables. Each range is one-directional; batchSize is PINNED (see the
        //     Apple note: lowering it raises both request count and total D1 work, so it is not a remote dial). ---
        val sourceIndex = root.optJSONObject("sourceIndex")
        val siDelayMs = clampInt(optInt(sourceIndex, "interBatchDelayMs"), RemoteConfigDefaults.SI_INTER_BATCH_DELAY_MS, 1100, 30000)
        val siBatchSize = RemoteConfigDefaults.SI_BATCH_SIZE   // pinned, not a remote dial
        val siPerTitle = clampInt(optInt(sourceIndex, "maxDescriptorsPerTitle"), RemoteConfigDefaults.SI_MAX_DESCRIPTORS_PER_TITLE, 16, 2000)
        val siResumeWaitMs = clampInt(optInt(sourceIndex, "resumeHoardMaxWaitMs"), RemoteConfigDefaults.SI_RESUME_HOARD_MAX_WAIT_MS, 250, 20000)
        val siResumePollMs = clampInt(optInt(sourceIndex, "resumeHoardPollIntervalMs"), RemoteConfigDefaults.SI_RESUME_HOARD_POLL_INTERVAL_MS, 250, 2000)
        // The DERIVED attempt count gets its own clamp against the constant cap: two in-range values can still
        // multiply into more polling than either looks like, so trim their product.
        val siResumeAttempts = minOf(
            RemoteConfigDefaults.SI_RESUME_HOARD_ATTEMPT_CAP,
            maxOf(1, siResumeWaitMs / maxOf(1, siResumePollMs)),
        )
        val siTimeoutSecs = clampInt(optInt(sourceIndex, "requestTimeoutSecs"), RemoteConfigDefaults.SI_REQUEST_TIMEOUT_SECS, 3, 8)

        // --- On-disk Streaming Cache. ---
        val player = root.optJSONObject("player")
        val diskCacheMetaMiB = clampInt(optInt(player, "diskCacheMetadataCapMiB"), RemoteConfigDefaults.DISK_CACHE_METADATA_CAP_MIB, 48, 256)
        val diskCacheReadSecs = clampInt(optInt(player, "diskCacheReadaheadSecs"), RemoteConfigDefaults.DISK_CACHE_READAHEAD_SECS, 60, 3600)

        // --- Refresh cadence. ---
        val refreshHours = clampInt(optInt(root, "refreshIntervalHours"), RemoteConfigDefaults.REFRESH_INTERVAL_HOURS, 1, 24)

        return Snapshot(
            features = features,
            captureIntervalSecs = capture,
            trickplayMinFrames = minFrames,
            trickplayMaxFrames = maxFrames,
            trickplayMaxTiles = maxTiles,
            trickplayEndpoint = trickplayUrl,
            catalogsEndpoint = catalogsUrl,
            subtitlesEndpoint = subtitlesUrl,
            sourcesEndpoint = sourcesUrl,
            subtitleDownloadTimeoutMs = subDownloadMs,
            subtitleUploadMaxBytes = subUploadMax,
            subtitleOffsetBucketMs = subOffsetBucket,
            langIndexMinSeen = langMinSeen,
            sourceIndexInterBatchDelayMs = siDelayMs,
            sourceIndexBatchSize = siBatchSize,
            sourceIndexMaxDescriptorsPerTitle = siPerTitle,
            sourceIndexResumeHoardMaxWaitMs = siResumeWaitMs,
            sourceIndexResumeHoardPollIntervalMs = siResumePollMs,
            sourceIndexResumeHoardAttemptCap = RemoteConfigDefaults.SI_RESUME_HOARD_ATTEMPT_CAP,
            sourceIndexResumeHoardAttempts = siResumeAttempts,
            sourceIndexRequestTimeoutSecs = siTimeoutSecs,
            diskCacheMetadataCapMiB = diskCacheMetaMiB,
            diskCacheReadaheadSecs = diskCacheReadSecs,
            refreshIntervalHours = refreshHours,
        )
    }

    /**
     * Decode the whole `features` object into a tri-state map: ONLY present, boolean-valued keys are stored.
     * A null / missing / non-boolean value is absent, so the read falls to the call site's baked default. This
     * decodes EVERY feature key Apple carries (and any future one) without a hand-maintained key list, while
     * keeping Apple's "present false = fleet kill-switch, absent = baked default" semantics exactly.
     */
    private fun parseFeatures(features: JSONObject?): Map<String, Boolean> {
        if (features == null) return emptyMap()
        val out = HashMap<String, Boolean>()
        val keys = features.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (!features.isNull(key) && features.opt(key) is Boolean) {
                out[key] = features.optBoolean(key)
            }
        }
        return out
    }

    /** master.remoteConfigEnabled == false => the whole-system kill switch. Absent field => enabled (false here). */
    private fun masterDisabled(root: JSONObject): Boolean {
        val master = root.optJSONObject("master") ?: return false
        return master.has("remoteConfigEnabled") && !master.optBoolean("remoteConfigEnabled", true)
    }

    /**
     * Clamp an optional Int into [lo, hi], falling back to [fallback] when null. ABSENT -> [fallback] (the baked
     * default). PRESENT BUT OUT OF RANGE -> the nearest edge [lo] or [hi], not the fallback. [fallback] is a
     * shipping constant, assumed already in range.
     */
    private fun clampInt(value: Int?, fallback: Int, lo: Int, hi: Int): Int =
        if (value == null) fallback else value.coerceIn(lo, hi)

    /**
     * Accept [raw] only if it parses as an https URL whose host is `vortx.tv` or ends with `.vortx.tv`;
     * otherwise the baked default. Guards against a hijacked / malformed endpoint (highest blast radius).
     */
    private fun validatedEndpoint(raw: String?, fallback: String): String {
        if (raw.isNullOrEmpty()) return fallback
        val url = runCatching { URL(raw) }.getOrNull() ?: return fallback
        val scheme = url.protocol?.lowercase()
        val host = url.host?.lowercase()
        if (scheme != "https" || host.isNullOrEmpty()) return fallback
        return if (host == "vortx.tv" || host.endsWith(".vortx.tv")) raw else fallback
    }

    /** JSON helpers that treat a missing / null / wrong-typed field as absent (null), matching the clamp contract. */
    private fun optInt(obj: JSONObject?, key: String): Int? =
        if (obj != null && obj.has(key) && !obj.isNull(key)) {
            val v = obj.opt(key)
            when (v) {
                is Int -> v
                is Number -> v.toInt()
                else -> null
            }
        } else null

    private fun optString(obj: JSONObject?, key: String): String? =
        if (obj != null && obj.has(key) && !obj.isNull(key)) obj.optString(key).ifEmpty { null } else null

    // MARK: - Persistence (SharedPreferences: last-good raw JSON body + its ETag).

    private fun persist(context: Context, rawJson: String, etag: String?) {
        prefs(context).edit().apply {
            putString(KEY_RAW, rawJson)
            if (!etag.isNullOrEmpty()) putString(KEY_ETAG, etag)
        }.apply()
    }

    private fun loadEtag(context: Context): String? = prefs(context).getString(KEY_ETAG, null)

    /**
     * Rebuild a [Snapshot] from the last-good cached body, or null when absent / corrupt / disabled. A corrupt
     * cache (unparseable JSON) or a cached kill-switch config is treated as absent => the caller stays baked.
     */
    private fun loadCachedSnapshot(context: Context): Snapshot? {
        val raw = prefs(context).getString(KEY_RAW, null) ?: return null
        val root = runCatching { JSONObject(raw) }.getOrNull() ?: return null
        if (masterDisabled(root)) return null
        return runCatching { validate(root) }.getOrNull()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /**
     * The immutable, already-resolved snapshot every reader consults. Constructed only by [validate] / [baked],
     * never mutated. The feature map holds ONLY present remote keys (tri-state); every other value is clamped.
     */
    class Snapshot internal constructor(
        private val features: Map<String, Boolean>,
        val captureIntervalSecs: Int,
        val trickplayMinFrames: Int,
        val trickplayMaxFrames: Int,
        val trickplayMaxTiles: Int,
        val trickplayEndpoint: String,
        val catalogsEndpoint: String,
        val subtitlesEndpoint: String,
        val sourcesEndpoint: String,
        val subtitleDownloadTimeoutMs: Int,
        val subtitleUploadMaxBytes: Int,
        val subtitleOffsetBucketMs: Int,
        val langIndexMinSeen: Int,
        val sourceIndexInterBatchDelayMs: Int,
        val sourceIndexBatchSize: Int,
        val sourceIndexMaxDescriptorsPerTitle: Int,
        val sourceIndexResumeHoardMaxWaitMs: Int,
        val sourceIndexResumeHoardPollIntervalMs: Int,
        val sourceIndexResumeHoardAttemptCap: Int,
        val sourceIndexResumeHoardAttempts: Int,
        val sourceIndexRequestTimeoutSecs: Int,
        val diskCacheMetadataCapMiB: Int,
        val diskCacheReadaheadSecs: Int,
        val refreshIntervalHours: Int,
    ) {
        /** Tri-state feature read: a PRESENT remote true/false wins; an ABSENT key => the call site's [default]. */
        fun isFeatureOn(key: String, default: Boolean): Boolean = features[key] ?: default

        /** Whether [key] carries an explicit remote value (present true OR present false), i.e. the "set" probe. */
        fun isFeatureSet(key: String): Boolean = features.containsKey(key)

        /** The explicit remote value for [key], or null when the key is absent (no baked substitution). */
        fun featureValue(key: String): Boolean? = features[key]

        /** Trickplay frame bounds (baked min 1, max 600). */
        val trickplayFrameBounds: Pair<Int, Int> get() = trickplayMinFrames to trickplayMaxFrames

        /** `demuxer-max-bytes` (BYTES) applied when the on-disk Streaming Cache is armed (baked 128 MiB). */
        val diskCacheMetadataCapBytes: Int get() = diskCacheMetadataCapMiB * 1024 * 1024

        /** Community-subtitle per-download budget in milliseconds (baked 12000). */
        val subtitleDownloadTimeout: Int get() = subtitleDownloadTimeoutMs

        /** A validated endpoint URL by key ("trickplay" / "catalogs" / "subtitles" / "sources"), else null. */
        fun endpoint(key: String): String? = when (key) {
            "trickplay" -> trickplayEndpoint
            "catalogs" -> catalogsEndpoint
            "subtitles" -> subtitlesEndpoint
            "sources" -> sourcesEndpoint
            else -> null
        }

        companion object {
            /** The all-baked snapshot: byte-identical to shipping. Built when no cache exists / config disabled. */
            fun baked(): Snapshot = Snapshot(
                features = emptyMap(),
                captureIntervalSecs = RemoteConfigDefaults.CAPTURE_INTERVAL_SECS,
                trickplayMinFrames = RemoteConfigDefaults.TRICKPLAY_MIN_FRAMES,
                trickplayMaxFrames = RemoteConfigDefaults.TRICKPLAY_MAX_FRAMES,
                trickplayMaxTiles = RemoteConfigDefaults.TRICKPLAY_MAX_TILES,
                trickplayEndpoint = RemoteConfigDefaults.ENDPOINT_TRICKPLAY,
                catalogsEndpoint = RemoteConfigDefaults.ENDPOINT_CATALOGS,
                subtitlesEndpoint = RemoteConfigDefaults.ENDPOINT_SUBTITLES,
                sourcesEndpoint = RemoteConfigDefaults.ENDPOINT_SOURCES,
                subtitleDownloadTimeoutMs = RemoteConfigDefaults.SUBTITLE_DOWNLOAD_TIMEOUT_MS,
                subtitleUploadMaxBytes = RemoteConfigDefaults.SUBTITLE_UPLOAD_MAX_BYTES,
                subtitleOffsetBucketMs = RemoteConfigDefaults.SUBTITLE_OFFSET_BUCKET_MS,
                langIndexMinSeen = RemoteConfigDefaults.LANG_INDEX_MIN_SEEN,
                sourceIndexInterBatchDelayMs = RemoteConfigDefaults.SI_INTER_BATCH_DELAY_MS,
                sourceIndexBatchSize = RemoteConfigDefaults.SI_BATCH_SIZE,
                sourceIndexMaxDescriptorsPerTitle = RemoteConfigDefaults.SI_MAX_DESCRIPTORS_PER_TITLE,
                sourceIndexResumeHoardMaxWaitMs = RemoteConfigDefaults.SI_RESUME_HOARD_MAX_WAIT_MS,
                sourceIndexResumeHoardPollIntervalMs = RemoteConfigDefaults.SI_RESUME_HOARD_POLL_INTERVAL_MS,
                sourceIndexResumeHoardAttemptCap = RemoteConfigDefaults.SI_RESUME_HOARD_ATTEMPT_CAP,
                sourceIndexResumeHoardAttempts = RemoteConfigDefaults.SI_RESUME_HOARD_ATTEMPTS,
                sourceIndexRequestTimeoutSecs = RemoteConfigDefaults.SI_REQUEST_TIMEOUT_SECS,
                diskCacheMetadataCapMiB = RemoteConfigDefaults.DISK_CACHE_METADATA_CAP_MIB,
                diskCacheReadaheadSecs = RemoteConfigDefaults.DISK_CACHE_READAHEAD_SECS,
                refreshIntervalHours = RemoteConfigDefaults.REFRESH_INTERVAL_HOURS,
            )
        }
    }
}

/**
 * Baked defaults == the shipping values, so an absent / unreachable / garbage config is behaviorally identical
 * to today. Feature-flag defaults are passed by each call site to [RemoteConfig.isFeatureOn]; non-feature
 * values are clamped in [RemoteConfig] `validate`. The constants mirror Apple `RemoteConfigDefaults`.
 */
object RemoteConfigDefaults {
    // --- Feature-flag baked defaults (call sites pass these to isFeatureOn; every one baked ON == shipping). ---
    const val FEATURE_COLLECTIONS_HUB = true      // CollectionsHubModel gate
    const val FEATURE_COMMUNITY_TRICKPLAY = true  // CommunityTrickplay.isEnabled fleet gate
    const val FEATURE_TRAILERS = true             // ambient/hero autoplay-trailers fleet gate
    const val FEATURE_SPOILER_BLUR = true         // spoiler veil fleet default (user setting still wins)
    const val FEATURE_DISK_CACHE = true           // disk-cache arming gate (force-OFF only)
    const val FEATURE_COMMUNITY_SUBTITLES = true  // pooled-subtitle read + upload master gate (wave-5)
    const val FEATURE_SUBTITLE_SYNC = true        // learned-offset read + contribute (wave-5)
    const val FEATURE_SUBTITLE_UPLOAD = true       // pooled-subtitle upload (wave-5)
    const val FEATURE_LANGUAGE_INDEX = true       // audio/sub language availability read + contribute (wave-5)
    const val FEATURE_LANGUAGE_INDEX_CONTRIBUTE = true // language-index contribute (wave-5)
    const val FEATURE_LOCALIZED_METADATA = true   // localized metadata (wave-5)
    const val FEATURE_SOURCE_INDEX = true         // Singularity community source-index hoard + serve (wave-5)

    // --- Trickplay capture params (Apple RemoteConfigDefaults.captureIntervalSecs / trickplay*). ---
    const val CAPTURE_INTERVAL_SECS = 10
    const val TRICKPLAY_MIN_FRAMES = 1
    const val TRICKPLAY_MAX_FRAMES = 600
    const val TRICKPLAY_MAX_TILES = 80

    // --- Endpoints (https + *.vortx.tv). ---
    const val ENDPOINT_TRICKPLAY = "https://trickplay.vortx.tv"
    const val ENDPOINT_CATALOGS = "https://catalogs.vortx.tv/3"
    const val ENDPOINT_SUBTITLES = "https://subtitles.vortx.tv"
    const val ENDPOINT_SOURCES = "https://sources.vortx.tv"

    // --- Community-subtitle tunables (baked == the client-side shipping defaults). ---
    const val SUBTITLE_DOWNLOAD_TIMEOUT_MS = 12000
    const val SUBTITLE_UPLOAD_MAX_BYTES = 1_048_576   // 1 MiB text cap (mirrors the worker's cap)
    const val SUBTITLE_OFFSET_BUCKET_MS = 250         // offset quantization (worker also buckets to 250 ms)
    const val LANG_INDEX_MIN_SEEN = 1                 // min pool seenCount before an availability read is trusted

    // --- Singularity source-pool upload/rate tunables (baked == SourceIndexClient shipping literals). ---
    const val SI_INTER_BATCH_DELAY_MS = 1100
    const val SI_BATCH_SIZE = 16                      // PINNED, not a remote dial (== worker MAX_SOURCES_PER_CONTRIBUTE)
    const val SI_MAX_DESCRIPTORS_PER_TITLE = 2000
    const val SI_RESUME_HOARD_MAX_WAIT_MS = 5000
    const val SI_RESUME_HOARD_POLL_INTERVAL_MS = 250
    const val SI_RESUME_HOARD_ATTEMPT_CAP = 60       // constant ceiling that trims the wait/poll product
    // The count the app polls with the baked pair: 5000 / 250 = 20, well under the cap.
    val SI_RESUME_HOARD_ATTEMPTS =
        minOf(SI_RESUME_HOARD_ATTEMPT_CAP, maxOf(1, SI_RESUME_HOARD_MAX_WAIT_MS / SI_RESUME_HOARD_POLL_INTERVAL_MS))
    const val SI_REQUEST_TIMEOUT_SECS = 8

    // --- On-disk Streaming Cache knobs (baked == shipping-safe literals). ---
    const val DISK_CACHE_METADATA_CAP_MIB = 128
    const val DISK_CACHE_READAHEAD_SECS = 900

    // --- Refresh cadence. ---
    const val REFRESH_INTERVAL_HOURS = 6
}
