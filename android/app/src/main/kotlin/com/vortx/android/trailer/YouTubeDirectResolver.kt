package com.vortx.android.trailer

import android.media.MediaCodecList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext

/// Resolves a YouTube video id to directly-playable googlevideo URLs FROM THE USER'S OWN IP, with no server
/// remux and no JS engine. The Android port of the Apple `app/SourcesShared/YouTubeDirectResolver.swift`
/// (itself the native port of the trailer worker's no-nsig ladder): POST the public InnerTube `/player`
/// endpoint as a set of app clients that return PLAIN progressive/adaptive URLs (no `signatureCipher`, no
/// ciphered `n`), and only ever accept a format whose `url` is present directly.
///
/// DIVERGENCE FROM APPLE (deliberate, not an oversight):
///   * CLIENT LADDER. Apple walks IOS -> ANDROID -> TVHTML5. Android leads with `ANDROID_VR` (the Meta
///     Quest client), which currently returns the fullest adaptive set on residential IPs, then falls back
///     ANDROID -> IOS -> TVHTML5. Order is `clients`.
///   * PER-RESOLVE UA. Because the WINNING client varies on Android (Apple's IOS always answers first, so it
///     hoists a single UA constant), [Resolved] carries the UA of the client that MINTED the URLs. googlevideo
///     binds an issued URL to that client's UA, so the player + the loopback range-proxy MUST replay both legs
///     with THIS UA (the UA/URL lockstep). Never substitute a different client's UA.
///   * DEVICE DECODER CAPS. The adaptive VIDEO pick consults [MediaCodecList]: avc1 (H.264) is preferred up
///     to the device's hardware-decodable height (<=1080); vp9 is only taken when no usable avc1 leg exists.
///     On a box with no 1080 avc hardware and no vp9, this drops to 720 avc1 rather than 1080 vp9-software.
///   * WATCH-PAGE CONFIG. The InnerTube key + a `visitorData` token are scraped from the watch page (3h TTL)
///     and force-refreshed once when every rung answers LOGIN_REQUIRED, falling back to the long-lived web key.
///   * `n=` PENALTY. We do NO nsig descrambling, so a URL carrying an `n=` throttle param is DEPRIORITIZED
///     (a clean URL at the same height wins), never chosen for descrambling.
///
/// FAIL-SOFT: any network / decode / playability error is a miss for that client and the ladder moves on; a
/// fully-missed ladder returns null. Never throws. Structured-concurrency safe: each rung is bounded by a
/// per-client timeout and checks for cancellation, and every [HttpURLConnection] is disconnected in `finally`
/// so a cancelled resolve leaks no socket.
///
/// UPDATE-ON-BREAK: the client identity strings below are copied from yt-dlp's INNERTUBE_CLIENTS / the worker
/// CLIENTS table. YouTube rotates these; when trailers stop resolving, refresh them here (and in the worker).
object YouTubeDirectResolver {

    /// A successful resolve. [videoUrl] is either a muxed (audio included) progressive mp4 OR a video-only
    /// adaptive stream; [audioUrl] is non-null ONLY in the adaptive case (mount it as the audio leg). [userAgent]
    /// is the UA googlevideo bound these URLs to (the minting client's UA) and MUST be replayed on both legs.
    data class Resolved(
        val videoUrl: String,   // muxed (audio included) OR video-only adaptive
        val audioUrl: String?,  // non-null ONLY when videoUrl is video-only
        val height: Int,
        val isMuxed: Boolean,
        val userAgent: String,
    )

    /// Resolve [videoId] by walking the client ladder, returning on the first client that yields a usable
    /// format. [preferredAudioLanguages] (ISO-639-1 base codes, priority order) picks the AUDIO leg when a
    /// trailer ships MULTIPLE audio languages (the "trailer played in the wrong language" fix); it is
    /// LOAD-BEARING and must never be dropped. [maxHeight] caps the adaptive pick (default 1080, never uncap).
    /// Returns null on a fully-missed ladder. Never throws.
    suspend fun resolve(
        videoId: String,
        preferredAudioLanguages: List<String>,
        maxHeight: Int = 1080,
    ): Resolved? {
        val prefLangs = preferredAudioLanguages.ifEmpty { listOf("en") }
        val cacheKey = "$videoId|$maxHeight|${prefLangs.joinToString("-")}"
        cacheGet(cacheKey)?.let { return it }

        // Two passes at most: a normal pass, then ONE forced-refresh pass if every rung said LOGIN_REQUIRED
        // (a stale watch-page config is the usual cause). A non-login miss does not trigger the refresh.
        for (attempt in 0 until 2) {
            val config = watchConfig(videoId, forceRefresh = attempt > 0)
            var allLoginRequired = true
            for (client in clients) {
                coroutineContext.ensureActive()
                val streaming = withTimeoutOrNull(CLIENT_TIMEOUT_MS) {
                    fetchStreamingData(videoId, client, config)
                }
                when (streaming) {
                    is FetchResult.LoginRequired -> continue
                    is FetchResult.Miss, null -> { allLoginRequired = false; continue }
                    is FetchResult.Data -> {
                        allLoginRequired = false
                        val resolved = pick(streaming.streaming, maxHeight, prefLangs, client.ua)
                        if (resolved != null) {
                            cacheSet(cacheKey, resolved)
                            return resolved
                        }
                    }
                }
            }
            if (!allLoginRequired) break
        }
        return null
    }

    // MARK: - InnerTube client ladder

    /// The long-lived public "web" InnerTube key, shipped in YouTube's own web client. Used unauthenticated as
    /// the FALLBACK when the watch-page scrape fails (same constant as Apple / the worker).
    private const val FALLBACK_INNERTUBE_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    /// Per-client timeout (ms). Bounds a cold-miss ladder so a stalled edge cannot serialize into a long wait;
    /// a timeout is a miss. The connect/read timeouts on the socket match, so a blocked GET also unblocks here.
    private const val CLIENT_TIMEOUT_MS = 5_000L

    /// One InnerTube client identity. [context] is the exact `client` object sent in the request body; [ua] is
    /// the matching User-Agent (and the UA googlevideo binds the returned URLs to); [clientNameNum] is the
    /// numeric id for the `x-youtube-client-name` header.
    // TODO: remote config blob -- these identity strings should be fetchable from config.vortx.tv so a
    // rotation ships without an app update (hardcoded for v1, matching Apple's shipped constants).
    private data class Client(
        val name: String,
        val ua: String,
        val clientNameNum: Int,
        val clientVersion: String,
        val context: Map<String, Any>,
    )

    /// Ladder order: ANDROID_VR first (fullest adaptive set on residential IPs today), then ANDROID, then IOS,
    /// then the embedded-TV client as a last resort. Identity strings from yt-dlp INNERTUBE_CLIENTS.
    private val clients: List<Client> = listOf(
        Client(
            name = "ANDROID_VR",
            ua = "com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12L; Quest 3) gzip",
            clientNameNum = 28,
            clientVersion = "1.56.21",
            context = mapOf(
                "clientName" to "ANDROID_VR",
                "clientVersion" to "1.56.21",
                "deviceMake" to "Oculus",
                "deviceModel" to "Quest 3",
                "androidSdkVersion" to 32,
                "osName" to "Android",
                "osVersion" to "12L",
                "hl" to "en",
                "gl" to "US",
            ),
        ),
        Client(
            name = "ANDROID",
            ua = "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
            clientNameNum = 3,
            clientVersion = "21.02.35",
            context = mapOf(
                "clientName" to "ANDROID",
                "clientVersion" to "21.02.35",
                "androidSdkVersion" to 30,
                "osName" to "Android",
                "osVersion" to "11",
                "hl" to "en",
                "gl" to "US",
            ),
        ),
        Client(
            name = "IOS",
            ua = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            clientNameNum = 5,
            clientVersion = "21.02.3",
            context = mapOf(
                "clientName" to "IOS",
                "clientVersion" to "21.02.3",
                "deviceMake" to "Apple",
                "deviceModel" to "iPhone16,2",
                "osName" to "iPhone",
                "osVersion" to "18.3.2.22D82",
                "hl" to "en",
                "gl" to "US",
            ),
        ),
        Client(
            name = "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            ua = "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15",
            clientNameNum = 85,
            clientVersion = "2.0",
            context = mapOf(
                "clientName" to "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
                "clientVersion" to "2.0",
                "clientScreen" to "EMBED",
                "hl" to "en",
                "gl" to "US",
            ),
        ),
    )

    // MARK: - InnerTube /player call

    /// The outcome of one `/player` POST: the streamingData, a login gate (feeds the forced-refresh retry), or
    /// a plain miss.
    private sealed interface FetchResult {
        data class Data(val streaming: JSONObject) : FetchResult
        data object LoginRequired : FetchResult
        data object Miss : FetchResult
    }

    /// POST the InnerTube `/player` call for one client with the scraped [config]. Runs on [Dispatchers.IO];
    /// returns the streamingData on a playable answer, [FetchResult.LoginRequired] on that playability status,
    /// else [FetchResult.Miss]. Never throws; the socket has bounded timeouts and is always disconnected.
    private suspend fun fetchStreamingData(
        videoId: String,
        client: Client,
        config: WatchConfig,
    ): FetchResult = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val url = URL("https://www.youtube.com/youtubei/v1/player?key=${config.apiKey}&prettyPrint=false")
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = CLIENT_TIMEOUT_MS.toInt()
                readTimeout = CLIENT_TIMEOUT_MS.toInt()
                useCaches = false
                doOutput = true
                setRequestProperty("content-type", "application/json")
                setRequestProperty("user-agent", client.ua)
                setRequestProperty("x-youtube-client-name", client.clientNameNum.toString())
                setRequestProperty("x-youtube-client-version", client.clientVersion)
                setRequestProperty("origin", "https://www.youtube.com")
                config.visitorData?.let { setRequestProperty("x-goog-visitor-id", it) }
            }
            connection.outputStream.use { it.write(requestBody(videoId, client, config).toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode != 200) return@withContext FetchResult.Miss
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val obj = runCatching { JSONObject(text) }.getOrNull() ?: return@withContext FetchResult.Miss
            val status = obj.optJSONObject("playabilityStatus")?.optString("status")
            if (status == "LOGIN_REQUIRED") return@withContext FetchResult.LoginRequired
            if (status != "OK") return@withContext FetchResult.Miss
            val streaming = obj.optJSONObject("streamingData") ?: return@withContext FetchResult.Miss
            FetchResult.Data(streaming)
        } catch (_: IOException) {
            FetchResult.Miss
        } finally {
            connection?.disconnect()
        }
    }

    /// The InnerTube request body: videoId + the client context (with the scraped `visitorData` folded in),
    /// mirroring the real clients' shape (Apple's `body`).
    private fun requestBody(videoId: String, client: Client, config: WatchConfig): String {
        val clientObj = JSONObject(client.context)
        config.visitorData?.let { clientObj.put("visitorData", it) }
        val context = JSONObject()
            .put("client", clientObj)
            .put("user", JSONObject().put("lockedSafetyMode", false))
            .put("request", JSONObject().put("useSsl", true))
        return JSONObject()
            .put("videoId", videoId)
            .put("context", context)
            .put("contentCheckOk", true)
            .put("racyCheckOk", true)
            .put(
                "playbackContext",
                JSONObject().put(
                    "contentPlaybackContext",
                    JSONObject().put("html5Preference", "HTML5_PREF_WANTS"),
                ),
            )
            .toString()
    }

    // MARK: - Watch-page config (InnerTube key + visitorData)

    /// The scraped InnerTube key + optional `visitorData`. A missing scrape falls back to the long-lived web key.
    private data class WatchConfig(val apiKey: String, val visitorData: String?)

    private val configLock = Any()
    @Volatile private var cachedConfig: WatchConfig? = null
    @Volatile private var cachedConfigAt = 0L
    private const val CONFIG_TTL_MS = 3 * 60 * 60 * 1000L

    /// The watch-page config, memoized for [CONFIG_TTL_MS]. [forceRefresh] bypasses the cache (used once when
    /// every rung answered LOGIN_REQUIRED, the signature of a stale config). Always returns a usable config:
    /// the scrape on success, else the long-lived fallback key with no visitorData.
    private suspend fun watchConfig(videoId: String, forceRefresh: Boolean): WatchConfig {
        if (!forceRefresh) {
            synchronized(configLock) {
                val hit = cachedConfig
                if (hit != null && System.currentTimeMillis() - cachedConfigAt < CONFIG_TTL_MS) return hit
            }
        }
        val scraped = scrapeWatchConfig(videoId)
        val resolved = scraped ?: WatchConfig(FALLBACK_INNERTUBE_KEY, null)
        // Only cache a real scrape; a fallback stays uncached so the next resolve retries the scrape.
        if (scraped != null) {
            synchronized(configLock) {
                cachedConfig = scraped
                cachedConfigAt = System.currentTimeMillis()
            }
        }
        return resolved
    }

    /// GET the watch page and regex out `INNERTUBE_API_KEY` + `visitorData`. Fail-soft null on any error, a
    /// non-200, or a missing key. Bounded socket timeouts; connection always disconnected.
    private suspend fun scrapeWatchConfig(videoId: String): WatchConfig? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val url = URL("https://www.youtube.com/watch?v=$videoId&hl=en&has_verified=1")
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = CLIENT_TIMEOUT_MS.toInt()
                readTimeout = CLIENT_TIMEOUT_MS.toInt()
                useCaches = false
                instanceFollowRedirects = true
                setRequestProperty("user-agent", WATCH_PAGE_UA)
                setRequestProperty("accept-language", "en-US,en;q=0.9")
            }
            if (connection.responseCode != 200) return@withContext null
            val html = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val key = INNERTUBE_KEY_REGEX.find(html)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }
                ?: return@withContext null
            val visitor = VISITOR_DATA_REGEX.find(html)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }
            WatchConfig(key, visitor)
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private const val WATCH_PAGE_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    private val INNERTUBE_KEY_REGEX = Regex("\"INNERTUBE_API_KEY\":\"([^\"]+)\"")
    private val VISITOR_DATA_REGEX = Regex("\"visitorData\":\"([^\"]+)\"")

    // MARK: - Format picking

    /// A usable format carries a bare `url` (no cipher) at a googlevideo host. Mirrors Apple `plainURL`; the
    /// `n=` throttle param is NOT disqualifying here (it is penalized in the ranking), only a cipher is.
    private fun plainUrl(f: JSONObject): String? {
        if (f.has("signatureCipher") || f.has("cipher")) return null
        val raw = f.optString("url").takeIf { it.isNotEmpty() } ?: return null
        val host = runCatching { URL(raw).host }.getOrNull() ?: return null
        return if (host.contains("googlevideo")) raw else null
    }

    /// A googlevideo URL carrying an `n=` throttle param needs nsig descrambling we do not do, so it is
    /// deprioritized. True when the query has an `n` parameter.
    private fun hasNParam(rawUrl: String): Boolean {
        val query = runCatching { URL(rawUrl).query }.getOrNull() ?: return false
        return query.split('&').any { it == "n" || it.startsWith("n=") }
    }

    /// Apply the resolution policy to one client's streamingData honoring [preferredLanguages]. Muxed-first
    /// (itag 22 then 18) UNLESS a genuine multi-language trailer offers the preferred language adaptively, in
    /// which case the adaptive video+audio pair (which lets us pick that exact language) wins over the muxed
    /// default. Mirrors Apple `pick`. Returns null when nothing usable exists.
    private fun pick(
        streaming: JSONObject,
        maxHeight: Int,
        preferredLanguages: List<String>,
        userAgent: String,
    ): Resolved? {
        val adaptive = streaming.optJSONArray("adaptiveFormats").toList()
        val muxedFormats = streaming.optJSONArray("formats").toList()
        val audioChoice = pickAudio(adaptive, preferredLanguages)
        val audioLangs = distinctAudioLanguages(adaptive)

        val preferAdaptiveForLanguage = (audioChoice?.matchedPreferred == true) && audioLangs.size > 1

        if (!preferAdaptiveForLanguage) {
            pickMuxed(muxedFormats)?.let { muxed ->
                return Resolved(muxed.first, null, muxed.second, isMuxed = true, userAgent = userAgent)
            }
        }

        val videoLeg = pickAdaptiveVideo(adaptive, maxHeight)
        if (videoLeg != null && audioChoice != null) {
            return Resolved(videoLeg.first, audioChoice.url, videoLeg.second, isMuxed = false, userAgent = userAgent)
        }

        // Fallback: a muxed default we skipped above for a language override that then had no adaptive leg.
        pickMuxed(muxedFormats)?.let { muxed ->
            return Resolved(muxed.first, null, muxed.second, isMuxed = true, userAgent = userAgent)
        }
        return null
    }

    /// Best muxed progressive format: itag 22 (720p) then 18 (360p), plain url only. Mirrors Apple `pickMuxed`.
    private fun pickMuxed(formats: List<JSONObject>): Pair<String, Int>? {
        for (itag in intArrayOf(22, 18)) {
            val f = formats.firstOrNull { it.optInt("itag", -1) == itag } ?: continue
            val url = plainUrl(f) ?: continue
            return url to f.optInt("height", if (itag == 22) 720 else 360)
        }
        return null
    }

    /// Best adaptive VIDEO leg under [maxHeight]. avc1 (H.264 for hardware decode) preferred up to the device's
    /// hardware-decodable height; vp9 only when no usable avc1 leg exists. Within a codec, a clean URL (no `n=`)
    /// beats a throttled one, then higher height, then higher bitrate. Mirrors Apple `pickAdaptiveVideo` plus
    /// the Android decoder-cap + `n=` policy.
    private fun pickAdaptiveVideo(adaptive: List<JSONObject>, maxHeight: Int): Pair<String, Int>? {
        val caps = DeviceDecoders.caps()
        val avcCap = minOf(maxHeight, caps.avcMaxHeight)

        fun best(codec: (String) -> Boolean, heightCap: Int): Pair<String, Int>? {
            var bestUrl: String? = null
            var bestHeight = 0
            var bestClean = false
            var bestBitrate = 0
            for (f in adaptive) {
                val mime = f.optString("mimeType")
                if (!mime.startsWith("video/") || !codec(mime)) continue
                val h = f.optInt("height", 0)
                if (h <= 0 || h > heightCap) continue
                val url = plainUrl(f) ?: continue
                val clean = !hasNParam(url)
                val br = f.optInt("bitrate", 0)
                // Rank: height dominates, then a clean (no-nsig) URL, then bitrate.
                val better = when {
                    bestUrl == null -> true
                    h != bestHeight -> h > bestHeight
                    clean != bestClean -> clean
                    else -> br > bestBitrate
                }
                if (better) {
                    bestUrl = url; bestHeight = h; bestClean = clean; bestBitrate = br
                }
            }
            return bestUrl?.let { it to bestHeight }
        }

        val bestAvcCapped = best({ it.startsWith("video/mp4") && it.contains("avc1") }, avcCap)
        if (bestAvcCapped != null) return bestAvcCapped
        // No hardware-friendly avc: prefer vp9 only when the device can decode it, else fall to any avc
        // (software) before an unsupported vp9.
        val bestVp9 = best({ it.contains("vp9") || it.contains("vp09") }, maxHeight)
        if (caps.vp9Supported && bestVp9 != null) return bestVp9
        val bestAvcAny = best({ it.startsWith("video/mp4") && it.contains("avc1") }, maxHeight)
        return bestAvcAny ?: bestVp9
    }

    /// The chosen adaptive AUDIO leg + what it is (for the muxed-override decision).
    private data class AudioChoice(val url: String, val matchedPreferred: Boolean)

    /// Pick the audio/mp4 leg honoring [preferredLanguages] (priority order), then YouTube's default/original
    /// track, then highest bitrate overall (the single-audio path). A clean URL breaks ties over a throttled
    /// one. Only audio/mp4 formats with a plain url are considered. Mirrors Apple `pickAudio`.
    private fun pickAudio(adaptive: List<JSONObject>, preferredLanguages: List<String>): AudioChoice? {
        val candidates = adaptive.mapNotNull { f ->
            if (!f.optString("mimeType").startsWith("audio/mp4")) return@mapNotNull null
            val url = plainUrl(f) ?: return@mapNotNull null
            AudioCandidate(f, url)
        }
        if (candidates.isEmpty()) return null

        fun best(list: List<AudioCandidate>): AudioCandidate? =
            list.maxWithOrNull(
                compareBy<AudioCandidate>({ !hasNParam(it.url) }, { it.format.optInt("bitrate", 0) }),
            )

        // 1. Preferred-language match, in priority order.
        for (code in preferredLanguages) {
            if (code.isEmpty()) continue
            val want = code.lowercase()
            val matches = candidates.filter { audioLanguageCode(it.format) == want }
            best(matches)?.let { return AudioChoice(it.url, matchedPreferred = true) }
        }
        // 2. YouTube's default/original track.
        val defaults = candidates.filter { it.format.optJSONObject("audioTrack")?.optBoolean("audioIsDefault") == true }
        best(defaults)?.let { return AudioChoice(it.url, matchedPreferred = false) }
        // 3. Highest bitrate overall (single-audio video, or multi-audio with no default flag).
        return best(candidates)?.let { AudioChoice(it.url, matchedPreferred = false) }
    }

    private data class AudioCandidate(val format: JSONObject, val url: String)

    /// Base ISO-639-1 code of an audio format's `audioTrack` ("en.4"/"en-US.4"/"hi.3" -> "en"/"hi"), or null for
    /// a single-audio format. Mirrors Apple `audioLanguageCode`.
    private fun audioLanguageCode(f: JSONObject): String? {
        val id = f.optJSONObject("audioTrack")?.optString("id")?.takeIf { it.isNotEmpty() } ?: return null
        val head = id.split('.', '-').firstOrNull()?.takeIf { it.isNotEmpty() } ?: return null
        return head.lowercase()
    }

    /// Distinct audio-track languages in the adaptive set (base ISO codes), to detect a genuine multi-language
    /// trailer. Mirrors Apple `distinctAudioLanguages`.
    private fun distinctAudioLanguages(adaptive: List<JSONObject>): List<String> {
        val seen = LinkedHashSet<String>()
        for (f in adaptive) {
            if (!f.optString("mimeType").startsWith("audio/mp4")) continue
            if (plainUrl(f) == null) continue
            audioLanguageCode(f)?.let { seen.add(it) }
        }
        return seen.toList()
    }

    private fun JSONArray?.toList(): List<JSONObject> {
        if (this == null) return emptyList()
        val out = ArrayList<JSONObject>(length())
        for (i in 0 until length()) optJSONObject(i)?.let { out.add(it) }
        return out
    }

    // MARK: - In-memory cache (googlevideo URLs expire ~6h; 2h TTL keeps entries comfortably fresh)

    private const val CACHE_TTL_MS = 2 * 60 * 60 * 1000L
    private val cacheLock = Any()
    private val cache = HashMap<String, Pair<Resolved, Long>>()

    private fun cacheGet(key: String): Resolved? = synchronized(cacheLock) {
        val e = cache[key] ?: return null
        if (System.currentTimeMillis() - e.second >= CACHE_TTL_MS) {
            cache.remove(key)
            return null
        }
        e.first
    }

    private fun cacheSet(key: String, value: Resolved) = synchronized(cacheLock) {
        cache[key] = value to System.currentTimeMillis()
    }
}

/// Device hardware-decoder capability probe, consulted by the adaptive VIDEO pick so a weak box does not get
/// handed a 1080 vp9 stream it can only software-decode. Queried once (the codec list does not change at
/// runtime) and memoized. Fail-soft: a query error assumes a CAPABLE device (avc 1080 + vp9) so a probe
/// failure never needlessly downgrades quality.
private object DeviceDecoders {

    data class Caps(val avcMaxHeight: Int, val vp9Supported: Boolean)

    @Volatile private var cached: Caps? = null

    fun caps(): Caps {
        cached?.let { return it }
        val computed = runCatching { probe() }.getOrDefault(Caps(avcMaxHeight = 1080, vp9Supported = true))
        cached = computed
        return computed
    }

    private fun probe(): Caps {
        val list = MediaCodecList(MediaCodecList.ALL_CODECS)
        var avcMaxHeight = 0
        var vp9Supported = false
        for (info in list.codecInfos) {
            if (info.isEncoder) continue
            val hardware = isHardware(info)
            for (type in info.supportedTypes) {
                val lower = type.lowercase()
                when {
                    lower == "video/avc" && hardware -> {
                        val caps = runCatching { info.getCapabilitiesForType(type).videoCapabilities }.getOrNull()
                        val supported = caps?.let {
                            runCatching { it.isSizeSupported(1920, 1080) }.getOrDefault(false)
                        } ?: false
                        if (supported) avcMaxHeight = maxOf(avcMaxHeight, 1080)
                        else if (avcMaxHeight < 720) avcMaxHeight = 720
                    }
                    (lower == "video/x-vnd.on2.vp9" || lower == "video/vp9") && hardware -> vp9Supported = true
                }
            }
        }
        // If no avc hardware surfaced at all, assume a common 720 hardware floor rather than 0 (which would
        // reject every avc leg). Very old/odd devices still get avc (software) via the pick's any-avc fallback.
        if (avcMaxHeight == 0) avcMaxHeight = 720
        return Caps(avcMaxHeight = avcMaxHeight, vp9Supported = vp9Supported)
    }

    /// Treat the known software codecs (`OMX.google.*`, `c2.android.*`) as non-hardware; on API 29+ use the
    /// platform flag directly. minSdk here is 26, so the name heuristic covers 26-28.
    private fun isHardware(info: android.media.MediaCodecInfo): Boolean {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            return runCatching { info.isHardwareAccelerated }.getOrDefault(!isSoftwareName(info.name))
        }
        return !isSoftwareName(info.name)
    }

    private fun isSoftwareName(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("omx.google.") || n.startsWith("c2.android.") || n.contains(".sw.")
    }
}
