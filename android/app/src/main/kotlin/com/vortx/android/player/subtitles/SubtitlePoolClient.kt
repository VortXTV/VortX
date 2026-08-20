package com.vortx.android.player.subtitles

import android.content.Context
import com.vortx.android.config.RemoteConfig
import com.vortx.android.config.RemoteConfigDefaults
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder

/**
 * Client for VortX's community-subtitle pool at `subtitles.vortx.tv`. The Kotlin port of Apple
 * `app/SourcesShared/SubtitlePoolClient.swift`, matched to the SAME Cloudflare Worker an Apple- or web-signed
 * client hits: same routes, same query params, same wire shapes, same byte caps, same timeouts, same URL
 * grammar.
 *
 * The pool lets any signed-in VortX user READ subtitles other users contributed for the same title/episode,
 * (best-effort, in the background) UPLOAD embedded/add-on subtitle text so the next user benefits, and learn
 * and share a per-rip SYNC OFFSET. This is the FOUNDATION client: pure, self-contained, callable. A later
 * integration pass wires it into the player's subtitle list and the offset slider (the same split Apple uses).
 *
 * FAIL-SOFT CONTRACT (every method): any network / decode / signing / size error returns the empty / null /
 * no-op result. Nothing throws to a caller. A disabled feature (`features.communitySubtitles` off, etc.) is a
 * hard no-op that never touches the network.
 *
 * GATING (VortX-only pool): the owner gates this pool to real VortX builds, like trickplay and trailers, so
 * EVERY request to `subtitles.vortx.tv` is HMAC-signed with [VortXEdgeAuth.sign] (the GET reads and the
 * sub-text download as well as the POSTs). Reads carry no ACCOUNT key (still "keyless" that way) but do carry
 * the `X-VX-*` signature so that when the worker flips to enforce mode only VortX clients read the pool. The
 * SERVE-side moat token (`X-VX-Moat`) is stamped when the [moatTokenProvider] hook yields one; Android has no
 * VortX-account moat minting yet, so the hook is null and the header is simply omitted (fail-soft: the worker
 * returns an empty list in enforce mode, and serves in observe mode). This mirrors [com.vortx.android.singularity.SourceIndexClient]'s
 * honest Android adaptation of the same Apple lifecycle: Android lacks the give-to-get consent and moat
 * surfaces the Apple client has, so those gates degrade to the feature flag plus the login flag the caller
 * threads in.
 */
object SubtitlePoolClient {

    private const val BAKED_HOST = "subtitles.vortx.tv"
    private val subtitleFormats = setOf("srt", "vtt", "ass")

    /**
     * The GET /subs index ceiling. The Worker returns at most 50 rows; allowing 426 bytes per row, 49
     * separators, the outer object, and the largest offset object totals about 21 KiB. The fixed 64 KiB cap
     * stays well above that and is independent of RemoteConfig, matching Apple's `indexResponseMaxBytes`.
     */
    const val INDEX_RESPONSE_MAX_BYTES = 64 * 1024

    /** The Worker's fixed MAX_TEXT_BYTES. Intentionally not remotely raisable. Matches Apple. */
    const val SUBTITLE_BODY_MAX_BYTES = 1024 * 1024

    private const val MOAT_HEADER = "X-VX-Moat"
    private const val INDEX_TIMEOUT_MS = 8_000
    private const val POST_TIMEOUT_MS = 8_000

    /**
     * Reserved hook for the future signed-off VortX-account moat lane. When wired it mints the short-lived
     * `X-VX-Moat` token for a signed-in device; null today (Android has no account-moat minting), so reads
     * degrade to the worker's observe-mode behaviour. Mirrors [com.vortx.android.singularity.SourceIndexClient.moatTokenProvider].
     */
    @Volatile
    var moatTokenProvider: (suspend (Boolean) -> String?)? = null

    // MARK: - Public model

    /** One subtitle offered by the pool. [url] is a fully-qualified downloadable link to the sub TEXT. */
    data class PooledSubtitle(
        val id: Int,
        val contentKey: String,
        val lang: String,
        val format: String, // "srt" | "vtt" | "ass"
        val origin: String, // e.g. "embedded" | "addon" | free-form worker tag
        val score: Int,
        val url: String,
    )

    /** The result of a pool read: the offered subtitles and the community-learned sync offset (ms), if any. */
    data class PooledResult(val subs: List<PooledSubtitle>, val offsetMs: Int?)

    // MARK: - Read: GET /subs

    /**
     * Fetch pooled subtitles + the learned offset for [contentKey]. Signed GET, 8 s timeout. Returns an empty
     * result on any error, or when `features.communitySubtitles` is off, or when the caller is not signed in
     * (the pooled-subtitle READ is login-gated on the worker, matching Apple).
     *
     * @param contentKey  the `imdb:tt...[:s:e]` key from [SubtitleReleaseFingerprint.contentKey].
     * @param lang        optional ISO language filter; null = all languages.
     * @param fingerprint optional release fingerprint so the returned offset matches the playing rip.
     * @param isSignedIn  gates the SERVE-side moat: a signed-in device stamps `X-VX-Moat` (when the provider is
     *                    wired). Default false fails soft to an empty result until callers thread the flag.
     */
    suspend fun fetchPooled(
        contentKey: String,
        lang: String? = null,
        fingerprint: String? = null,
        isSignedIn: Boolean = false,
    ): PooledResult {
        if (!isValidContentKey(contentKey) || !featureCommunitySubtitles || !isSignedIn) {
            return PooledResult(emptyList(), null)
        }
        val moat = runCatching { moatTokenProvider?.invoke(isSignedIn) }.getOrNull()
        val url = indexUrl(contentKey, lang, fingerprint) ?: return PooledResult(emptyList(), null)
        val body = signedGet(url, moat, INDEX_RESPONSE_MAX_BYTES) ?: return PooledResult(emptyList(), null)
        return parseSubsResponse(body, contentKey)
    }

    // MARK: - Download the sub text: GET <pooled.url>

    /**
     * Download [pooled]'s sub text to a deterministic temp file (reused across the session) and return the
     * local file path, or null on any failure. The download REQUEST is signed too (the host is a gated VortX
     * host), so pool-hosted sub text stays VortX-only. Timeout comes from the RemoteConfig
     * `subtitle.downloadTimeoutMs` tunable (baked 12 s), matching Apple.
     */
    suspend fun download(context: Context, pooled: PooledSubtitle, isSignedIn: Boolean = false): String? {
        if (!isValidDownloadURL(pooled.url, pooled.contentKey, pooled.format) || !featureCommunitySubtitles) {
            return null
        }
        val cacheDir = context.applicationContext.cacheDir
        val name = "vortx-poolsub-${stableHash(pooled.url)}.${pooled.format}"
        val target = File(cacheDir, name)
        // Session-scoped reuse: if we already fetched this URL to a still-present file, hand it back.
        if (target.exists() && target.length() > 0) return target.absolutePath

        val moat = runCatching { moatTokenProvider?.invoke(isSignedIn) }.getOrNull()
        val timeout = RemoteConfig.current().subtitleDownloadTimeout
        val data = signedGetBytes(pooled.url, moat, SUBTITLE_BODY_MAX_BYTES, timeout) ?: return null
        if (data.isEmpty()) return null
        return runCatching {
            val tmp = File.createTempFile("vortx-poolsub-", ".${pooled.format}", cacheDir)
            tmp.writeBytes(data)
            if (tmp.renameTo(target)) target.absolutePath else tmp.absolutePath
        }.getOrNull()
    }

    // MARK: - Upload sub text: POST /subs (signed)

    /**
     * Best-effort upload of subtitle text to the pool so other users benefit. Signed POST. Gated on
     * `features.communitySubtitles` AND the `subtitleUpload` sub-flag. Size-guarded: text larger than the
     * `subtitle.uploadMaxBytes` tunable (baked 1 MiB, capped at the worker's 1 MiB) is skipped. The result is
     * ignored; failures are silent. Matches Apple.
     *
     * @param origin "embedded" (extracted from the file's own tracks) or "addon" (from a subtitles add-on).
     * @param format "srt" | "vtt" | "ass".
     */
    suspend fun upload(
        contentKey: String,
        lang: String,
        fingerprint: String?,
        origin: String,
        format: String,
        text: String,
    ) {
        if (!featureCommunitySubtitles || !featureSubtitleUpload) return
        if (!isValidContentKey(contentKey)) return
        val maxBytes = minOf(RemoteConfig.current().subtitleUploadMaxBytes, SUBTITLE_BODY_MAX_BYTES)
        val bytes = text.toByteArray(Charsets.UTF_8).size
        if (bytes <= 0 || bytes > maxBytes) return // skip empty or oversized text

        val body = JSONObject().apply {
            put("content_key", contentKey)
            put("lang", lang)
            put("origin", origin)
            put("format", format)
            put("text", text)
            if (!fingerprint.isNullOrEmpty()) put("fingerprint", fingerprint)
        }
        signedPost("subs", body)
    }

    // MARK: - Post a learned offset: POST /offset (signed)

    /**
     * Best-effort submit of a learned sync offset (ms) for [contentKey] + [fingerprint]. Signed POST. Gated on
     * `features.subtitleSync`. The worker buckets `offset_ms` server-side; we send the raw value. Result
     * ignored. Matches Apple.
     */
    suspend fun postOffset(contentKey: String, lang: String, fingerprint: String?, offsetMs: Int) {
        if (!featureSubtitleSync) return
        if (!isValidContentKey(contentKey)) return
        val body = JSONObject().apply {
            put("content_key", contentKey)
            put("lang", lang)
            put("offset_ms", offsetMs)
            if (!fingerprint.isNullOrEmpty()) put("fingerprint", fingerprint)
        }
        signedPost("offset", body)
    }

    // MARK: - Feature gates

    private val featureCommunitySubtitles: Boolean
        get() = RemoteConfig.isFeatureOn("communitySubtitles", RemoteConfigDefaults.FEATURE_COMMUNITY_SUBTITLES)
    private val featureSubtitleSync: Boolean
        get() = RemoteConfig.isFeatureOn("subtitleSync", RemoteConfigDefaults.FEATURE_SUBTITLE_SYNC)
    private val featureSubtitleUpload: Boolean
        get() = RemoteConfig.isFeatureOn("subtitleUpload", RemoteConfigDefaults.FEATURE_SUBTITLE_UPLOAD)

    // MARK: - URL builders + validation (mirrors Apple exactly)

    private val baseUrl: String
        get() = RemoteConfig.current().endpoint("subtitles") ?: RemoteConfigDefaults.ENDPOINT_SUBTITLES

    /** Build the signed-safe GET /subs URL against the BAKED origin, or null when a component is malformed. */
    internal fun indexUrl(contentKey: String, lang: String?, fingerprint: String?): String? {
        if (!isValidContentKey(contentKey)) return null
        val query = StringBuilder("key=").append(enc(contentKey))
        if (!lang.isNullOrEmpty()) query.append("&lang=").append(enc(lang))
        if (!fingerprint.isNullOrEmpty()) query.append("&fp=").append(enc(fingerprint))
        return "https://$BAKED_HOST/subs?$query"
    }

    /**
     * The content-key grammar the worker accepts: 1..200 bytes of `[0-9A-Za-z:._-]`. Mirrors Apple's
     * `isValidContentKey` byte set exactly so a key rejected here is one the worker would reject too.
     */
    internal fun isValidContentKey(contentKey: String): Boolean {
        val bytes = contentKey.toByteArray(Charsets.UTF_8)
        if (bytes.size !in 1..200) return false
        return bytes.all { raw ->
            val b = raw.toInt() and 0xFF
            (b in 48..57) || (b in 65..90) || (b in 97..122) ||
                b == 58 || b == 46 || b == 95 || b == 45 // : . _ -
        }
    }

    /**
     * Accept only the worker's canonical public-object grammar under the baked pool origin:
     * `https://subtitles.vortx.tv/r2/subs/<contentKey>/<64-hex>.<format>` with no query. Mirrors Apple's
     * `isValidDownloadURL`.
     */
    internal fun isValidDownloadURL(rawUrl: String, contentKey: String, format: String): Boolean {
        if (!isValidContentKey(contentKey) || format !in subtitleFormats) return false
        val uri = runCatching { URI(rawUrl) }.getOrNull() ?: return false
        if (!uri.scheme.equals("https", ignoreCase = true)) return false
        if (!uri.host.equals(BAKED_HOST, ignoreCase = true)) return false
        if (uri.port != -1 || uri.rawQuery != null || uri.rawFragment != null || uri.rawUserInfo != null) return false
        val path = uri.rawPath ?: return false
        val prefix = "/r2/subs/$contentKey/"
        val suffix = ".$format"
        if (!path.startsWith(prefix) || !path.endsWith(suffix)) return false
        val hash = path.substring(prefix.length, path.length - suffix.length)
        return hash.length == 64 && hash.all { it in '0'..'9' || it in 'a'..'f' }
    }

    // MARK: - Networking primitives (all fail-soft, bounded, edge-auth signed)

    private suspend fun signedGet(url: String, moat: String?, maxBytes: Int): String? {
        val bytes = signedGetBytes(url, moat, maxBytes, INDEX_TIMEOUT_MS) ?: return null
        return bytes.toString(Charsets.UTF_8)
    }

    /**
     * Bounded, redirect-refusing, edge-auth signed GET. Reads at most [maxBytes] and returns null if the body
     * runs over (a hostile Content-Length or a chunked overrun cannot bypass the cap). Never throws.
     */
    private suspend fun signedGetBytes(url: String, moat: String?, maxBytes: Int, timeoutMs: Int): ByteArray? =
        withContext(Dispatchers.IO) {
            var conn: HttpURLConnection? = null
            try {
                conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = timeoutMs
                    readTimeout = timeoutMs
                    useCaches = false
                    instanceFollowRedirects = false
                    setRequestProperty("accept", "application/json")
                }
                VortXEdgeAuth.sign(conn) // gated host: stamp X-VX-Ts / X-VX-Sig / X-VX-Kid
                if (moat != null) conn.setRequestProperty(MOAT_HEADER, moat)
                if (conn.responseCode !in 200..299) return@withContext null
                readBounded(conn, maxBytes)
            } catch (_: Throwable) {
                null
            } finally {
                conn?.disconnect()
            }
        }

    /** Read up to [maxBytes] from the connection's input stream; null if the body exceeds the cap. */
    private fun readBounded(conn: HttpURLConnection, maxBytes: Int): ByteArray? {
        conn.inputStream.use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > maxBytes) return null
                out.write(buffer, 0, read)
            }
            return out.toByteArray()
        }
    }

    /** Signed JSON POST to [path] under the RemoteConfig base. Best-effort: serialize, sign, send, ignore. */
    private suspend fun signedPost(path: String, body: JSONObject) {
        withContext(Dispatchers.IO) {
            var conn: HttpURLConnection? = null
            try {
                conn = (URL("$baseUrl/$path").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = POST_TIMEOUT_MS
                    readTimeout = POST_TIMEOUT_MS
                    useCaches = false
                    instanceFollowRedirects = false
                    doOutput = true
                    setRequestProperty("content-type", "application/json")
                }
                VortXEdgeAuth.sign(conn)
                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                conn.responseCode // fire-and-forget: any status just ends the request
            } catch (_: Throwable) {
                // fire-and-forget: any failure silently drops this one POST, never blocks playback
            } finally {
                conn?.disconnect()
            }
        }
    }

    // MARK: - Decode + helpers

    private fun parseSubsResponse(body: String, contentKey: String): PooledResult {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return PooledResult(emptyList(), null)
        val array = root.optJSONArray("subs")
        val subs = mutableListOf<PooledSubtitle>()
        if (array != null) {
            for (i in 0 until array.length()) {
                val raw = array.optJSONObject(i) ?: continue
                val url = raw.optString("url").takeIf { it.isNotBlank() } ?: continue
                val format = raw.optString("format").takeIf { it.isNotBlank() } ?: continue
                if (!isValidDownloadURL(url, contentKey, format)) continue
                val lang = raw.optString("lang").takeIf { it.isNotBlank() } ?: continue
                if (!raw.has("id") || raw.isNull("id")) continue
                subs.add(
                    PooledSubtitle(
                        id = raw.optInt("id"),
                        contentKey = contentKey,
                        lang = lang,
                        format = format,
                        origin = raw.optString("origin", ""),
                        score = raw.optInt("score", 0),
                        url = url,
                    ),
                )
            }
        }
        val offsetObj = root.optJSONObject("offset")
        val offsetMs = if (offsetObj != null && offsetObj.has("offset_ms") && !offsetObj.isNull("offset_ms")) {
            offsetObj.optInt("offset_ms")
        } else {
            null
        }
        return PooledResult(subs, offsetMs)
    }

    /** Percent-encode a query VALUE but keep the `:` separators of a content key readable (matches Apple). */
    private fun enc(value: String): String =
        URLEncoder.encode(value, "UTF-8").replace("+", "%20").replace("%3A", ":")

    /** Stable per-string FNV-1a hash for a deterministic temp filename (not a per-process-seeded hash). */
    private fun stableHash(input: String): String {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325 FNV offset basis
        val prime = 0x100000001b3L
        for (byte in input.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= prime
        }
        return "%016x".format(hash)
    }
}
