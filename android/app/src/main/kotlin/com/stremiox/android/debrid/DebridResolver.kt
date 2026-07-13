package com.stremiox.android.debrid

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import kotlin.coroutines.coroutineContext

/// Native in-client debrid resolution for Android: turn a torrent (infoHash / magnet) into a DIRECT,
/// streamable HTTPS URL through the user's own debrid account, so cached torrents play instantly without
/// a debrid add-on. This is the Kotlin port of the Apple `DebridResolver.swift` (RealDebrid + TorBox
/// torrent flows), wired into [com.stremiox.android.engine.EngineStremioRepository.resolve].
///
/// Keys live in [DebridKeys] (EncryptedSharedPreferences), the Android analogue of the Apple Keychain.
/// HTTP is Android's [HttpURLConnection] and JSON is `org.json` (both ship with the platform, no added
/// dependency), matching the existing engine JSON layer (EngineState/EngineActions).
///
/// FAIL-SOFT by construction: every failure surfaces as a [DebridException] (or null from [resolve]),
/// so the caller falls back to today's path and the user is never left unable to play. All network work
/// runs on [Dispatchers.IO]; the poll loops honor coroutine cancellation so a bounded resolve stops
/// promptly.
class DebridResolver(private val keys: DebridKeys) {

    /// Which errors a resolve can surface. Mirrors the Apple `DebridError`.
    sealed class DebridException(message: String) : Exception(message) {
        object NoKey : DebridException("no debrid key configured")
        object InvalidKey : DebridException("debrid key rejected (401/403)")
        object NotCached : DebridException("torrent not cached on this account")
        object NoMatchingFile : DebridException("no playable file in the torrent")
        object NotReady : DebridException("torrent added but not ready in time")
        class Provider(detail: String) : DebridException("provider error: $detail")
    }

    /// One file inside a debrid torrent. [id] is the provider's file id used to request the stream link.
    private data class DebridFile(
        val id: Int,
        val name: String,
        val shortName: String,
        val size: Long,
    ) {
        val isVideo: Boolean
            get() {
                val candidate = shortName.ifEmpty { name }
                val ext = candidate.substringAfterLast('.', "").lowercase()
                return ext in VIDEO_EXTENSIONS
            }
    }

    /// A series episode target, for picking the right file in a season pack. Null for movies.
    data class Episode(val season: Int, val episode: Int)

    /// Resolve a raw torrent (infoHash [+ magnet]) to a DIRECT, playable HTTPS URL through the first
    /// configured provider (or a specific [service]). Returns null on ANY failure (no key, not cached,
    /// no file, provider/network error) so the caller falls soft to today's behavior.
    ///
    /// [infoHash] is required; [magnet] is optional (built from the infohash when absent, plus any
    /// [trackers] the add-on carried). [episode] biases the season-pack file pick. Runs on IO.
    suspend fun resolve(
        infoHash: String,
        magnet: String? = null,
        service: DebridService? = null,
        trackers: List<String> = emptyList(),
        episode: Episode? = null,
    ): String? {
        val hash = infoHash.trim().lowercase()
        if (hash.isEmpty()) return null
        val chosen = service?.takeIf(keys::isConfigured) ?: keys.configuredServices().firstOrNull() ?: return null
        val mag = magnet?.takeIf { it.isNotBlank() } ?: buildMagnet(hash, trackers)
        return try {
            withContext(Dispatchers.IO) {
                when (chosen) {
                    DebridService.TOR_BOX -> resolveTorBox(hash, mag, episode)
                    DebridService.REAL_DEBRID -> resolveRealDebrid(mag, episode)
                    // AllDebrid / Premiumize are not ported yet (parity with the first-wired Apple pair);
                    // treat as no-op so the caller falls soft rather than erroring.
                    DebridService.ALL_DEBRID, DebridService.PREMIUMIZE -> null
                }
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: DebridException) {
            Log.d(TAG, "debrid resolve failed for ${chosen.displayName}: ${error.message}")
            null
        } catch (error: Exception) {
            Log.d(TAG, "debrid resolve error for ${chosen.displayName}", error)
            null
        }
    }

    // ------------------------------------------------------------------------------------------------
    // TorBox (torrents). Base https://api.torbox.app/v1/api/torrents, Bearer auth. Flow (cached):
    // createtorrent (idempotent) -> poll mylist by hash until ready -> requestdl. TorBox is the only one
    // of the four that kept an instant cache-check, but the resolve path here is add-then-poll like RD.
    // ------------------------------------------------------------------------------------------------

    private suspend fun resolveTorBox(hash: String, magnet: String, episode: Episode?): String {
        val apiKey = keys.key(DebridService.TOR_BOX)
        val base = TORBOX_BASE

        // 1. Add the magnet (idempotent; returns the existing torrent_id if already in the library).
        val created = postMultipart("$base/createtorrent", apiKey, mapOf("magnet" to magnet))
        var torrentId = created.optJSONObject("data")?.optIntOrNull("torrent_id")

        // 2. Poll mylist by hash until a torrent_id appears AND it is ready (cached should be ~1 poll).
        var files = emptyList<DebridFile>()
        val immediate = torrentId?.let { id ->
            runCatching { torBoxItem(base, apiKey, id) }.getOrNull()?.takeIf(::torBoxReady)
        }
        if (immediate != null) {
            files = torBoxFiles(immediate)
        } else {
            val polled = torBoxPollByHash(base, apiKey, hash)
            torrentId = polled.first
            files = polled.second
        }
        val id = torrentId ?: throw DebridException.NotReady
        val pick = pickFile(files, episode, fileIdx = null) ?: throw DebridException.NoMatchingFile

        // 3. Request the direct stream URL.
        return torBoxRequestDl(base, apiKey, id, pick.id)
    }

    /// The requestdl leg: mint a direct stream URL for a known torrent_id+file_id. A missing/evicted
    /// file surfaces as [DebridException.NotCached].
    private suspend fun torBoxRequestDl(base: String, apiKey: String, torrentId: Int, fileId: Int): String {
        val url = "$base/requestdl?token=${enc(apiKey)}&torrent_id=$torrentId&file_id=$fileId&redirect=false"
        val env = getJson(url, apiKey)
        return env.optStringOrNull("data") ?: throw DebridException.NotCached
    }

    private suspend fun torBoxItem(base: String, apiKey: String, id: Int): JSONObject {
        val env = getJson("$base/mylist?id=$id&bypass_cache=true", apiKey)
        return env.optJSONObject("data") ?: JSONObject()
    }

    /// Poll the library by infohash until the torrent is ready (cached ~1 poll). ~30s streaming budget;
    /// an uncached download surfaces as [DebridException.NotReady] so the caller falls back to today's
    /// path. Honors cancellation so a bounded/raced resolve stops promptly.
    private suspend fun torBoxPollByHash(base: String, apiKey: String, hash: String): Pair<Int?, List<DebridFile>> {
        for (attempt in 0 until POLL_ATTEMPTS) {
            coroutineContext.ensureActive()
            if (attempt > 0) delay(POLL_INTERVAL_MS)
            val env = getJson("$base/mylist?bypass_cache=true", apiKey)
            val list = env.optJSONArray("data") ?: continue
            for (i in 0 until list.length()) {
                val item = list.optJSONObject(i) ?: continue
                val itemHash = item.optString("hash").lowercase()
                val itemFiles = torBoxFiles(item)
                if (itemHash == hash && torBoxReady(item) && itemFiles.isNotEmpty()) {
                    return item.optIntOrNull("id") to itemFiles
                }
            }
        }
        throw DebridException.NotReady
    }

    /// Whether a TorBox mylist item is ready to stream: download_finished && download_present, OR a
    /// cached/completed download_state (mirrors the Apple `Item.ready`).
    private fun torBoxReady(item: JSONObject): Boolean {
        val finished = item.optBoolean("download_finished", false) && item.optBoolean("download_present", false)
        val state = item.optString("download_state")
        return finished || state == "cached" || state == "completed"
    }

    private fun torBoxFiles(item: JSONObject): List<DebridFile> {
        val arr = item.optJSONArray("files") ?: return emptyList()
        val out = ArrayList<DebridFile>(arr.length())
        for (i in 0 until arr.length()) {
            val f = arr.optJSONObject(i) ?: continue
            val name = f.optStringOrNull("name").orEmpty()
            val shortName = f.optStringOrNull("short_name").orEmpty()
            out += DebridFile(
                id = f.optInt("id", i),
                name = name.ifEmpty { shortName },
                shortName = shortName.ifEmpty { name.substringAfterLast('/') },
                size = f.optLong("size", 0L),
            )
        }
        return out
    }

    // ------------------------------------------------------------------------------------------------
    // Real-Debrid (torrents). Base https://api.real-debrid.com/rest/1.0, Bearer auth. RD REMOVED its
    // instant cache-check, so the ONLY path is add-then-poll:
    //   addMagnet -> wait for the file list -> select ONLY the wanted file -> poll info until
    //   `downloaded` (with the active-download FAST-FAIL) -> unrestrict its link.
    // Selecting the ONE wanted file BEFORE download is the verified-against-live-API path: a multi-file
    // selection packs into a single unstreamable RAR, and selectFiles is a no-op once downloaded.
    // ------------------------------------------------------------------------------------------------

    private suspend fun resolveRealDebrid(magnet: String, episode: Episode?): String {
        val apiKey = keys.key(DebridService.REAL_DEBRID)
        val base = RD_BASE

        // 1. Add the magnet -> torrent id.
        val add = postForm("$base/torrents/addMagnet", apiKey, mapOf("magnet" to magnet))
        val id = add.optStringOrNull("id") ?: throw DebridException.Provider("no torrent id")

        // 2. Wait for RD to parse the magnet into its file list.
        var fileList = emptyList<DebridFile>()
        for (attempt in 0 until RD_ATTEMPTS) {
            coroutineContext.ensureActive()
            if (attempt > 0) delay(RD_INTERVAL_MS)
            val info = getJson("$base/torrents/info/$id", apiKey)
            rdGuardStatus(info)
            val files = rdFiles(info)
            if (files.isNotEmpty()) { fileList = files; break }
        }
        if (fileList.isEmpty()) throw DebridException.NotReady

        // 3. Pick the ONE target file, then select ONLY it.
        val pick = pickFile(fileList, episode, fileIdx = null) ?: throw DebridException.NoMatchingFile
        postFormNoBody("$base/torrents/selectFiles/$id", apiKey, mapOf("files" to pick.id.toString()))

        // 4. Poll info until `downloaded`, with the NOT-CACHED FAST-FAIL: RD retired the instant
        //    cache-check, so a "cached" badge on an RD row is the add-on's claim, not a check against
        //    THIS account. A genuinely cached torrent reports `downloaded` within a poll or two; an
        //    active-download status means RD is pulling from peers now = it was NOT cached and will not
        //    finish inside the play budget. Bail after one grace poll so the user reaches a truly-cached
        //    source in ~2s instead of hanging the resolve timeout.
        var link: String? = null
        for (attempt in 0 until RD_ATTEMPTS) {
            coroutineContext.ensureActive()
            if (attempt > 0) delay(RD_INTERVAL_MS)
            val info = getJson("$base/torrents/info/$id", apiKey)
            rdGuardStatus(info)
            val status = info.optString("status")
            if (status == "downloaded") {
                link = info.optJSONArray("links")?.optStringOrNull(0)
                if (link != null) break
            }
            if (attempt >= 1 && status in RD_ACTIVE_STATUSES) throw DebridException.NotReady
        }
        val restricted = link ?: throw DebridException.NotReady

        // 5. Unrestrict the restricted link into a direct, playable URL.
        val un = postForm("$base/unrestrict/link", apiKey, mapOf("link" to restricted))
        return un.optStringOrNull("download") ?: throw DebridException.Provider("no download url")
    }

    private fun rdGuardStatus(info: JSONObject) {
        if (info.optString("status") in RD_DEAD_STATUSES) {
            throw DebridException.Provider("status ${info.optString("status")}")
        }
    }

    private fun rdFiles(info: JSONObject): List<DebridFile> {
        val arr = info.optJSONArray("files") ?: return emptyList()
        val out = ArrayList<DebridFile>(arr.length())
        for (i in 0 until arr.length()) {
            val f = arr.optJSONObject(i) ?: continue
            val path = f.optString("path")
            out += DebridFile(
                id = f.optInt("id", i),
                name = path,
                shortName = path.substringAfterLast('/'),
                size = f.optLong("bytes", 0L),
            )
        }
        return out
    }

    // ------------------------------------------------------------------------------------------------
    // Shared file-pick heuristic (mirrors the Apple DebridResolve.pickFile / episodeMatchScore):
    // explicit fileIdx -> SxEy filename match -> largest video file.
    // ------------------------------------------------------------------------------------------------

    private fun pickFile(files: List<DebridFile>, episode: Episode?, fileIdx: Int?): DebridFile? {
        if (fileIdx != null && fileIdx in files.indices) return files[fileIdx]
        val videos = files.filter { it.isVideo }
        if (videos.isEmpty()) return null
        if (episode == null) return videos.maxByOrNull { it.size }
        val best = videos
            .mapNotNull { f ->
                val name = f.shortName.ifEmpty { f.name }
                val score = episodeMatchScore(name, episode.season, episode.episode)
                if (score > 0) f to score else null
            }
            .maxByOrNull { it.second }
            ?.first
        return best ?: videos.maxByOrNull { it.size }   // pack fallback: biggest video
    }

    /// Score a filename against a SxEy target (SnnEnn, n x nn, "season n ... episode n"). 0 = no match.
    private fun episodeMatchScore(filename: String, season: Int, episode: Int): Int {
        val lower = filename.lowercase()
        if (lower.contains("s%02de%02d".format(season, episode))) return 3
        if (lower.contains("${season}x%02d".format(episode))) return 2
        if (lower.contains("season $season") && lower.contains("episode $episode")) return 1
        return 0
    }

    private fun buildMagnet(hash: String, trackers: List<String>): String {
        val sb = StringBuilder("magnet:?xt=urn:btih:").append(hash)
        for (tr in trackers) sb.append("&tr=").append(enc(tr))
        return sb.toString()
    }

    // ------------------------------------------------------------------------------------------------
    // HTTP (HttpURLConnection). Maps 401/403 -> InvalidKey, other non-2xx -> Provider, decode failure
    // -> Provider, matching the Apple send() contract. All calls run on Dispatchers.IO (the resolve
    // entry point already switched context), and each connection sets finite connect/read timeouts.
    // ------------------------------------------------------------------------------------------------

    private fun getJson(urlString: String, bearer: String): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "GET"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        return execute(conn)
    }

    private fun postForm(urlString: String, bearer: String, fields: Map<String, String>): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        conn.outputStream.use { it.write(formBody(fields).toByteArray(Charsets.UTF_8)) }
        return execute(conn)
    }

    /// A POST whose 2xx carries no JSON body (RD selectFiles is 204). Validates the status only.
    private fun postFormNoBody(urlString: String, bearer: String, fields: Map<String, String>) {
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        conn.outputStream.use { it.write(formBody(fields).toByteArray(Charsets.UTF_8)) }
        val code = conn.responseCodeSafe()
        try {
            if (code == 401 || code == 403) throw DebridException.InvalidKey
            if (code !in 200..299) throw DebridException.Provider("HTTP $code")
        } finally {
            conn.disconnect()
        }
    }

    private fun postMultipart(urlString: String, bearer: String, fields: Map<String, String>): JSONObject {
        val boundary = "vortx-${UUID.randomUUID()}"
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
        conn.doOutput = true
        val body = StringBuilder()
        for ((k, v) in fields) {
            body.append("--").append(boundary).append("\r\n")
                .append("Content-Disposition: form-data; name=\"").append(k).append("\"\r\n\r\n")
                .append(v).append("\r\n")
        }
        body.append("--").append(boundary).append("--\r\n")
        conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
        return execute(conn)
    }

    /// Read the response, mapping status codes to [DebridException], then parse the body as JSON. The
    /// body is always read (2xx from the input stream, error from the error stream) so the connection
    /// releases cleanly.
    private fun execute(conn: HttpURLConnection): JSONObject {
        try {
            val code = conn.responseCodeSafe()
            if (code == 401 || code == 403) throw DebridException.InvalidKey
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use(BufferedReader::readText).orEmpty()
            if (code !in 200..299) throw DebridException.Provider("HTTP $code")
            return runCatching { JSONObject(text) }.getOrElse {
                throw DebridException.Provider("decode: ${it.message}")
            }
        } finally {
            conn.disconnect()
        }
    }

    private fun open(urlString: String): HttpURLConnection {
        val conn = URL(urlString).openConnection() as HttpURLConnection
        conn.connectTimeout = CONNECT_TIMEOUT_MS
        conn.readTimeout = READ_TIMEOUT_MS
        conn.instanceFollowRedirects = true
        return conn
    }

    private fun HttpURLConnection.responseCodeSafe(): Int =
        try { responseCode } catch (io: IOException) { throw DebridException.Provider(io.message ?: "io") }

    private fun formBody(fields: Map<String, String>): String =
        fields.entries.joinToString("&") { "${enc(it.key)}=${enc(it.value)}" }

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")

    // ---- org.json null-safety helpers (org.json returns the string "null" from optString) ----

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    private fun JSONObject.optIntOrNull(key: String): Int? =
        if (has(key) && !isNull(key)) optInt(key) else null

    private fun org.json.JSONArray.optStringOrNull(index: Int): String? {
        if (isNull(index)) return null
        return optString(index).ifBlank { null }
    }

    private companion object {
        const val TAG = "DebridResolver"
        const val TORBOX_BASE = "https://api.torbox.app/v1/api/torrents"
        const val RD_BASE = "https://api.real-debrid.com/rest/1.0"

        const val CONNECT_TIMEOUT_MS = 15_000
        const val READ_TIMEOUT_MS = 20_000

        // TorBox poll: up to 10 attempts, 3s apart (~30s streaming budget), matching the Apple resolver.
        const val POLL_ATTEMPTS = 10
        const val POLL_INTERVAL_MS = 3_000L

        // Real-Debrid poll: up to 12 attempts, 2s apart, matching the Apple resolver.
        const val RD_ATTEMPTS = 12
        const val RD_INTERVAL_MS = 2_000L

        val RD_DEAD_STATUSES = setOf("magnet_error", "error", "virus", "dead")
        // Active-download statuses that trigger the not-cached fast-fail after one grace poll.
        val RD_ACTIVE_STATUSES = setOf("downloading", "queued", "compressing", "uploading")

        val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "avi", "mov", "ts", "m2ts", "webm", "wmv", "flv", "m4v",
        )
    }
}
