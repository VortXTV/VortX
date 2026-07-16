package com.vortx.android.debrid

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.coroutineContext

/// Native in-client debrid resolution for Android: turn a torrent (infoHash / magnet) into a DIRECT,
/// streamable HTTPS URL through the user's own debrid account, so cached torrents play instantly without
/// a debrid add-on. This is the Kotlin port of the Apple `DebridResolver.swift` (RealDebrid + TorBox
/// torrent flows), wired into [com.vortx.android.engine.EngineStremioRepository.resolve].
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
    /// Public because the [DebridCoordinator] surfaces the cached-file lists from [checkCache] to the
    /// ranker/assembly layer. Mirrors the Apple `DebridFile` (adds the optional `mimetype` TorBox returns).
    data class DebridFile(
        val id: Int,
        val name: String,
        val shortName: String,
        val size: Long,
        val mimetype: String? = null,
    ) {
        val isVideo: Boolean
            get() {
                mimetype?.lowercase()?.let { if (it.startsWith("video/")) return true }
                val candidate = shortName.ifEmpty { name }
                val ext = candidate.substringAfterLast('.', "").lowercase()
                return ext in VIDEO_EXTENSIONS
            }
    }

    /// The url of a resolved debrid link PLUS the provider ids needed to LATER regenerate a fresh link
    /// without a full re-add ([reresolveLink]). TorBox carries stable `torrentId`/`fileId`; the other three
    /// leave them null and reresolve by re-adding the magnet. Mirrors the Apple `resolveWithIds` tuple.
    data class ResolvedLink(val url: String, val torrentId: Int?, val fileId: Int?)

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
            withContext(Dispatchers.IO) { resolveWithIdsInternal(chosen, hash, mag, fileIdx = null, episode).url }
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
    // Coordinator-facing throwing entry points (used by [DebridCoordinator]). Unlike [resolve] above,
    // these THROW [DebridException] so the coordinator can implement per-candidate catch, bounded
    // timeouts, and multi-candidate failover itself. Each hops to [Dispatchers.IO] at its boundary so the
    // caller need not (a nested `withContext(IO)` when already on IO is a cheap no-op). Mirrors the Apple
    // `DebridResolving.resolveWithIds` / `reresolveLink` protocol requirements.
    // ------------------------------------------------------------------------------------------------

    /// Resolve a torrent through [service], surfacing the provider ids for a later [reresolveLink]. The
    /// [magnet] is built from [infoHash] (+ [trackers]) when null. Throws on any failure. Runs on IO.
    suspend fun resolveWithIds(
        service: DebridService,
        infoHash: String,
        magnet: String? = null,
        fileIdx: Int? = null,
        episode: Episode? = null,
        trackers: List<String> = emptyList(),
    ): ResolvedLink {
        val hash = infoHash.trim().lowercase()
        val mag = magnet?.takeIf { it.isNotBlank() } ?: buildMagnet(hash, trackers)
        return withContext(Dispatchers.IO) { resolveWithIdsInternal(service, hash, mag, fileIdx, episode) }
    }

    /// Regenerate a FRESH direct link for an already-resolved file through the SAME [service], skipping the
    /// add step where the provider supports it. On TorBox with both ids present this is a single `requestdl`
    /// (no re-add); an evicted file (or any provider blip) falls through to a full re-add from [infoHash].
    /// Every other provider (and TorBox with missing ids) re-adds the magnet, which the provider dedups.
    /// Throws when the file is genuinely gone. Runs on IO. Mirrors the Apple `reresolveLink`.
    suspend fun reresolveLink(
        service: DebridService,
        infoHash: String,
        torrentId: Int?,
        fileId: Int?,
        fileIdx: Int?,
    ): String = withContext(Dispatchers.IO) {
        val hash = infoHash.trim().lowercase()
        // TorBox fast path: mint a fresh link from the stored ids with no re-add. Any DEBRID-side failure
        // (evicted file, provider blip, transient auth, not-ready) is recoverable by the full re-add below,
        // so fall through on all of them; only a genuine cancellation aborts.
        if (service == DebridService.TOR_BOX && torrentId != null && fileId != null) {
            try {
                return@withContext torBoxRequestDl(TORBOX_BASE, keys.key(DebridService.TOR_BOX), torrentId, fileId)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: DebridException) {
                Log.d(TAG, "torbox reresolve fast-path failed (${error.message}); re-adding")
            }
        }
        resolveWithIdsInternal(service, hash, buildMagnet(hash, emptyList()), fileIdx, episode = null).url
    }

    /// Build a minimal magnet from an [infoHash] (+ optional [trackers]) for the coordinator's failover
    /// legs, when a candidate carried no pre-built magnet. Mirrors the Apple `DebridResolve.magnet`.
    fun magnet(infoHash: String, trackers: List<String> = emptyList()): String =
        buildMagnet(infoHash.trim().lowercase(), trackers)

    /// The single service dispatch shared by [resolve] and [resolveWithIds]. Throws [DebridException] on
    /// failure. TorBox carries its stable ids; the other three return null ids (reresolve re-adds).
    private suspend fun resolveWithIdsInternal(
        service: DebridService,
        hash: String,
        magnet: String,
        fileIdx: Int?,
        episode: Episode?,
    ): ResolvedLink = when (service) {
        DebridService.TOR_BOX -> resolveTorBox(hash, magnet, episode, fileIdx)
        DebridService.REAL_DEBRID -> ResolvedLink(resolveRealDebrid(magnet, episode, fileIdx), null, null)
        DebridService.ALL_DEBRID -> ResolvedLink(resolveAllDebrid(magnet, episode, fileIdx), null, null)
        DebridService.PREMIUMIZE -> ResolvedLink(resolvePremiumize(magnet, episode, fileIdx), null, null)
    }

    // ------------------------------------------------------------------------------------------------
    // Batch cache-availability (the coordinator's cache-check fan-out calls one service at a time). Returns
    // infoHash -> cached files for the hashes the account has cached; an absent/empty entry means not
    // cached. Real-Debrid returns empty (it removed its instant cache-check upstream), so a "cached" badge
    // on an RD row is an add-on claim, confirmed only by the add-then-poll resolve. Fail-soft: a provider
    // error yields no confirmations (the resolve path still works). Mirrors the Apple per-actor `checkCache`.
    // ------------------------------------------------------------------------------------------------

    /// Which of [hashes] [service] has cached, hash -> files. Runs on IO. Never throws (fail-soft): a
    /// provider/network error simply yields no confirmations for that batch.
    suspend fun checkCache(service: DebridService, hashes: List<String>): Map<String, List<DebridFile>> {
        if (hashes.isEmpty() || !keys.isConfigured(service)) return emptyMap()
        val normalized = hashes.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        if (normalized.isEmpty()) return emptyMap()
        return try {
            withContext(Dispatchers.IO) {
                when (service) {
                    DebridService.TOR_BOX -> torBoxCheckCache(normalized)
                    DebridService.REAL_DEBRID -> emptyMap()   // removed upstream
                    DebridService.ALL_DEBRID -> allDebridCheckCache(normalized)
                    DebridService.PREMIUMIZE -> premiumizeCheckCache(normalized)
                }
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            Log.d(TAG, "debrid cache-check error for ${service.displayName}", error)
            emptyMap()
        }
    }

    // ------------------------------------------------------------------------------------------------
    // TorBox (torrents). Base https://api.torbox.app/v1/api/torrents, Bearer auth. Flow (cached):
    // createtorrent (idempotent) -> poll mylist by hash until ready -> requestdl. TorBox is the only one
    // of the four that kept an instant cache-check, but the resolve path here is add-then-poll like RD.
    // ------------------------------------------------------------------------------------------------

    private suspend fun resolveTorBox(hash: String, magnet: String, episode: Episode?, fileIdx: Int?): ResolvedLink {
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
        val pick = pickFile(files, episode, fileIdx) ?: throw DebridException.NoMatchingFile

        // 3. Request the direct stream URL; carry the stable ids for a later reresolve.
        val url = torBoxRequestDl(base, apiKey, id, pick.id)
        return ResolvedLink(url, id, pick.id)
    }

    /// TorBox torrent cache-check: `/checkcached?hash=<comma-list>&format=list&list_files=true`, Bearer auth.
    /// TorBox is the only one of the four that kept an instant cache-check. Up to 100 hashes per call.
    private suspend fun torBoxCheckCache(hashes: List<String>): Map<String, List<DebridFile>> {
        val out = HashMap<String, List<DebridFile>>()
        val apiKey = keys.key(DebridService.TOR_BOX)
        for (chunk in hashes.chunked(100)) {
            coroutineContext.ensureActive()
            val joined = chunk.joinToString(",")
            val env = getJson("$TORBOX_BASE/checkcached?hash=${enc(joined)}&format=list&list_files=true", apiKey)
            val data = env.optJSONArray("data") ?: continue
            for (i in 0 until data.length()) {
                val c = data.optJSONObject(i) ?: continue
                val h = c.optString("hash").lowercase()
                if (h.isNotEmpty()) out[h] = torBoxCachedFiles(c.optJSONArray("files"))
            }
        }
        return out
    }

    private fun torBoxCachedFiles(arr: JSONArray?): List<DebridFile> {
        if (arr == null) return emptyList()
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
                mimetype = f.optStringOrNull("mimetype"),
            )
        }
        return out
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

    private suspend fun resolveRealDebrid(magnet: String, episode: Episode?, fileIdx: Int?): String {
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
        val pick = pickFile(fileList, episode, fileIdx) ?: throw DebridException.NoMatchingFile
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
    // AllDebrid (torrents). Base https://api.alldebrid.com/v4, auth via `agent` + `apikey` QUERY params
    // (no Authorization header). Flow: /magnet/upload -> poll /magnet/status until statusCode 4 (Ready)
    // -> pick the file from the link list -> /link/unlock for the direct URL. Mirrors the Apple
    // AllDebridResolver.resolve. Fail-soft: any failure throws a DebridException the resolve() catch maps
    // to null, exactly like the RD/TorBox paths.
    // ------------------------------------------------------------------------------------------------

    private data class AllDebridLink(val link: String, val filename: String, val size: Long)

    // fileIdx is accepted for a uniform dispatch signature but NOT applied to the pick: AD's link list can
    // differ from the torrent's file order/count, so the pick runs the filename/size heuristic (fileIdx=null)
    // to keep links[pick.id] aligned. Matches the Apple AllDebridResolver.resolve.
    private suspend fun resolveAllDebrid(magnet: String, episode: Episode?, fileIdx: Int?): String {
        val apiKey = keys.key(DebridService.ALL_DEBRID)
        val base = AD_BASE

        // 1. Upload the magnet -> magnet id. `data.magnets` is an ARRAY here (upload can carry several).
        val upEnv = getJsonQueryAuth(adUrl(base, "/magnet/upload", apiKey, "magnets[]" to magnet))
        val id = upEnv.optJSONObject("data")
            ?.optJSONArray("magnets")
            ?.optJSONObject(0)
            ?.optIntOrNull("id")
            ?: throw DebridException.Provider("upload")

        // 2. Poll /magnet/status until Ready (statusCode 4) with links present; 5+ is an error/expired
        //    magnet. `data.magnets` is a SINGLE object when queried by id (matches the Apple StatusMagnet?).
        var links = emptyList<AllDebridLink>()
        for (attempt in 0 until AD_ATTEMPTS) {
            coroutineContext.ensureActive()
            if (attempt > 0) delay(AD_INTERVAL_MS)
            val st = getJsonQueryAuth(adUrl(base, "/magnet/status", apiKey, "id" to id.toString()))
            val m = st.optJSONObject("data")?.optJSONObject("magnets") ?: continue
            val statusCode = m.optIntOrNull("statusCode")
            if (statusCode == 4) {
                val ready = adLinks(m)
                if (ready.isNotEmpty()) { links = ready; break }
            }
            if (statusCode != null && statusCode >= 5) throw DebridException.Provider("status $statusCode")
        }
        if (links.isEmpty()) throw DebridException.NotReady

        // 3. Pick the file. fileIdx is torrent-wide; AD's link list may differ in order/count, so pick by
        //    the filename/size heuristic (which keeps links[pick.id] aligned), not the raw torrent index.
        val files = links.mapIndexed { idx, l ->
            DebridFile(id = idx, name = l.filename, shortName = l.filename.substringAfterLast('/'), size = l.size)
        }
        val pick = pickFile(files, episode, fileIdx = null)?.takeIf { it.id in links.indices }
            ?: throw DebridException.NoMatchingFile

        // 4. Unlock the chosen link into a direct, playable URL.
        val un = getJsonQueryAuth(adUrl(base, "/link/unlock", apiKey, "link" to links[pick.id].link))
        return un.optJSONObject("data")?.optStringOrNull("link") ?: throw DebridException.Provider("unlock")
    }

    private fun adLinks(magnet: JSONObject): List<AllDebridLink> {
        val arr = magnet.optJSONArray("links") ?: return emptyList()
        val out = ArrayList<AllDebridLink>(arr.length())
        for (i in 0 until arr.length()) {
            val l = arr.optJSONObject(i) ?: continue
            val link = l.optStringOrNull("link") ?: continue
            out += AllDebridLink(
                link = link,
                filename = l.optStringOrNull("filename").orEmpty(),
                size = l.optLong("size", 0L),
            )
        }
        return out
    }

    /// Build an AllDebrid authed URL: `?agent=vortx&apikey=<key>` + the extra query pairs. Matches the
    /// Apple `authed(_:_:)`. Names are appended literally (e.g. `magnets[]`), values are percent-encoded.
    private fun adUrl(base: String, path: String, apiKey: String, vararg extra: Pair<String, String>): String {
        val sb = StringBuilder(base).append(path)
            .append("?agent=").append(enc(AD_AGENT))
            .append("&apikey=").append(enc(apiKey))
        for ((name, value) in extra) sb.append('&').append(name).append('=').append(enc(value))
        return sb.toString()
    }

    /// AllDebrid cache-check: `GET /magnet/instant`, repeated `magnets[]` = infohashes, query auth. AllDebrid
    /// still ships this (only RD removed its cache-check), but it is known flaky, so a failed/empty chunk
    /// simply yields no confirmations for those hashes (resolve still works). Batch ~40. Mirrors Apple.
    private suspend fun allDebridCheckCache(hashes: List<String>): Map<String, List<DebridFile>> {
        val out = HashMap<String, List<DebridFile>>()
        val apiKey = keys.key(DebridService.ALL_DEBRID)
        for (chunk in hashes.chunked(40)) {
            coroutineContext.ensureActive()
            val pairs = chunk.map { "magnets[]" to it }.toTypedArray()
            val env = try {
                getJsonQueryAuth(adUrl(AD_BASE, "/magnet/instant", apiKey, *pairs))
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Exception) {
                continue
            }
            if (env.optString("status") != "success") continue
            val magnets = env.optJSONObject("data")?.optJSONArray("magnets") ?: continue
            for (i in 0 until magnets.length()) {
                val m = magnets.optJSONObject(i) ?: continue
                if (!m.optBoolean("instant", false)) continue
                val h = m.optString("hash").lowercase()
                if (h.isEmpty()) continue
                val files = ArrayList<DebridFile>()
                m.optJSONArray("files")?.let { arr ->
                    for (j in 0 until arr.length()) {
                        val f = arr.optJSONObject(j) ?: continue
                        val n = f.optStringOrNull("n") ?: continue
                        files += DebridFile(0, n, n.substringAfterLast('/'), f.optLong("s", 0L))
                    }
                }
                // A cached hash MUST map to a non-empty file list to count as confirmed; if the instant tree
                // was omitted, a placeholder keeps the hash confirmed (resolve picks the file).
                out[h] = files.ifEmpty { listOf(DebridFile(0, h, h, 0L)) }
            }
        }
        return out
    }

    // ------------------------------------------------------------------------------------------------
    // Premiumize (torrents). Base https://www.premiumize.me/api, auth via `apikey` QUERY param (no
    // Authorization header). ONE call: POST /transfer/directdl with the magnet returns the file list WITH
    // direct links (instant for cached, so no separate unrestrict step). Mirrors the Apple
    // PremiumizeResolver.resolve. Same fail-soft (throw -> null) shape as the RD/TorBox paths.
    // ------------------------------------------------------------------------------------------------

    private data class PremiumizeItem(val path: String, val size: Long, val link: String?, val streamLink: String?)

    // fileIdx is accepted for a uniform dispatch signature but NOT applied to the pick: PM's directdl content
    // order can differ from the torrent's, so the pick runs the filename/size heuristic (fileIdx=null) to keep
    // items[pick.id] aligned. Matches the Apple PremiumizeResolver.resolve.
    private suspend fun resolvePremiumize(magnet: String, episode: Episode?, fileIdx: Int?): String {
        val apiKey = keys.key(DebridService.PREMIUMIZE)
        val url = "$PM_BASE/transfer/directdl?apikey=${enc(apiKey)}"
        val dl = postFormQueryAuth(url, mapOf("src" to magnet))
        if (dl.optString("status") != "success") {
            throw DebridException.Provider("directdl ${dl.optString("status")}")
        }
        val content = dl.optJSONArray("content") ?: throw DebridException.NotReady
        val items = ArrayList<PremiumizeItem>(content.length())
        for (i in 0 until content.length()) {
            val c = content.optJSONObject(i) ?: continue
            val path = c.optStringOrNull("path").orEmpty()
            items += PremiumizeItem(
                path = path,
                size = c.optLong("size", 0L),
                link = c.optStringOrNull("link"),
                streamLink = c.optStringOrNull("stream_link"),
            )
        }
        if (items.isEmpty()) throw DebridException.NotReady

        // fileIdx is torrent-wide; PM's directdl content order may differ, so pick by the filename/size
        // heuristic (which keeps items[pick.id] aligned), not by the raw torrent index.
        val files = items.mapIndexed { idx, c ->
            DebridFile(id = idx, name = c.path, shortName = c.path.substringAfterLast('/'), size = c.size)
        }
        val pick = pickFile(files, episode, fileIdx = null)?.takeIf { it.id in items.indices }
            ?: throw DebridException.NoMatchingFile
        val item = items[pick.id]
        return item.streamLink ?: item.link ?: throw DebridException.Provider("no link")
    }

    /// Premiumize cache-check: `POST /cache/check` with repeated `items[]` = bare infohashes (apikey in the
    /// query). The `response` array is positionally aligned with `items[]`; a `true` means directdl will hit
    /// instantly. Premiumize still ships this (only RD removed its cache-check). Fail-soft per chunk; batch
    /// ~80. Mirrors the Apple PremiumizeResolver.checkCache.
    private suspend fun premiumizeCheckCache(hashes: List<String>): Map<String, List<DebridFile>> {
        val out = HashMap<String, List<DebridFile>>()
        val apiKey = keys.key(DebridService.PREMIUMIZE)
        for (chunk in hashes.chunked(80)) {
            coroutineContext.ensureActive()
            val url = "$PM_BASE/cache/check?apikey=${enc(apiKey)}"
            val r = try {
                postFormPairsQueryAuth(url, chunk.map { "items[]" to it })
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Exception) {
                continue
            }
            if (r.optString("status") != "success") continue
            val flags = r.optJSONArray("response") ?: continue
            val filenames = r.optJSONArray("filename")
            val filesizes = r.optJSONArray("filesize")
            for ((i, hash) in chunk.withIndex()) {
                if (i >= flags.length() || !flags.optBoolean(i, false)) continue
                val name = filenames?.optStringOrNull(i) ?: hash
                out[hash.lowercase()] = listOf(DebridFile(0, name, name.substringAfterLast('/'), pmSize(filesizes, i)))
            }
        }
        return out
    }

    /// Premiumize returns `filesize` as a base-10 STRING on a hit and the integer `0` on a miss; decode both.
    private fun pmSize(arr: JSONArray?, index: Int): Long {
        if (arr == null || index >= arr.length() || arr.isNull(index)) return 0L
        return when (val v = arr.opt(index)) {
            is Number -> v.toLong()
            is String -> v.toLongOrNull() ?: 0L
            else -> 0L
        }
    }

    // ------------------------------------------------------------------------------------------------
    // TorBox usenet. A DROP-IN TWIN of the TorBox torrent path pointed at the `/usenet/*` backend (base
    // https://api.torbox.app/v1/api/usenet, same Bearer auth). A usenet stream carries an .nzb LINK instead
    // of an infohash; the resolver adds the nzb, waits until TorBox has it present, picks the video file, and
    // mints a direct HTTPS URL. The identifier is the md5 of the nzb link (TorBox's usenet cache key). Usenet
    // is a TorBox-only backend among the four services. Mirrors the Apple TorBoxUsenetResolver.
    // ------------------------------------------------------------------------------------------------

    /// The md5 (hex) of an nzb link: TorBox's usenet cache identifier (the usenet twin of the torrent
    /// infohash). Mirrors the Apple `TorBoxUsenetResolver.identifier(forNzbURL:)`.
    fun usenetIdentifier(nzbUrl: String): String =
        MessageDigest.getInstance("MD5").digest(nzbUrl.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    /// Which nzb md5s the user's TorBox usenet account has cached, md5 -> files. Empty (no-op) with no TorBox
    /// key. Never throws (fail-soft). Runs on IO. Mirrors the Apple usenet checkCache.
    suspend fun usenetCheckCache(nzbMd5s: List<String>): Map<String, List<DebridFile>> {
        if (nzbMd5s.isEmpty() || !keys.isConfigured(DebridService.TOR_BOX)) return emptyMap()
        val normalized = nzbMd5s.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        if (normalized.isEmpty()) return emptyMap()
        return try {
            withContext(Dispatchers.IO) {
                val out = HashMap<String, List<DebridFile>>()
                val apiKey = keys.key(DebridService.TOR_BOX)
                for (chunk in normalized.chunked(100)) {
                    coroutineContext.ensureActive()
                    val env = getJson(
                        "$USENET_BASE/checkcached?hash=${enc(chunk.joinToString(","))}&format=list&list_files=true",
                        apiKey,
                    )
                    val data = env.optJSONArray("data") ?: continue
                    for (i in 0 until data.length()) {
                        val c = data.optJSONObject(i) ?: continue
                        val h = c.optString("hash").lowercase()
                        if (h.isNotEmpty()) out[h] = torBoxCachedFiles(c.optJSONArray("files"))
                    }
                }
                out
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            Log.d(TAG, "usenet cache-check error", error)
            emptyMap()
        }
    }

    /// Resolve one usenet stream (nzb link) to a direct HTTPS URL: createusenetdownload -> poll mylist until
    /// present -> pick the file (fileMustInclude regex first, then the shared heuristic) -> requestdl. Throws
    /// on failure. [knownHash] is the stream's authoritative NZB md5 when its emitter carried one (else the
    /// md5-of-the-link fallback). Runs on IO. Mirrors the Apple TorBoxUsenetResolver.resolve.
    suspend fun resolveUsenet(
        nzbUrl: String,
        knownHash: String? = null,
        fileMustInclude: String? = null,
        fileIdx: Int? = null,
        episode: Episode? = null,
    ): String = withContext(Dispatchers.IO) {
        val apiKey = keys.key(DebridService.TOR_BOX)
        val base = USENET_BASE

        // 1. Add the nzb (JSON body; post_processing default -1). Idempotent: TorBox returns the existing
        //    download id if the same nzb is already in the user's usenet list.
        val created = postJson(
            "$base/createusenetdownload",
            apiKey,
            JSONObject().put("link", nzbUrl).put("post_processing", -1),
        )
        var usenetId = created.optJSONObject("data")?.optIntOrNull("usenetdownload_id")

        // 2. Poll mylist until the download is finished + present (cached should be ~1 poll).
        var files = emptyList<DebridFile>()
        val immediate = usenetId?.let { id ->
            runCatching { usenetItem(base, apiKey, id) }.getOrNull()?.takeIf(::torBoxReady)
        }
        if (immediate != null) {
            files = torBoxFiles(immediate)
        } else {
            val polled = usenetPollByHash(base, apiKey, usenetId, knownHash?.lowercase() ?: usenetIdentifier(nzbUrl))
            usenetId = polled.first
            files = polled.second
        }
        val id = usenetId ?: throw DebridException.NotReady

        // 3. Pick the file, honoring fileMustInclude / fileIdx, then the shared episode/size heuristic.
        val pick = pickUsenetFile(files, fileMustInclude, fileIdx, episode) ?: throw DebridException.NoMatchingFile

        // 4. Request the direct stream URL.
        usenetRequestDl(base, apiKey, id, pick.id)
    }

    /// File pick with the usenet-specific [mustInclude] regex applied FIRST (when present + it matches a
    /// video), then the shared [pickFile] (explicit idx -> SxEy -> largest video). Mirrors the Apple pick.
    private fun pickUsenetFile(files: List<DebridFile>, mustInclude: String?, fileIdx: Int?, episode: Episode?): DebridFile? {
        if (!mustInclude.isNullOrEmpty()) {
            val re = runCatching { Regex(mustInclude, RegexOption.IGNORE_CASE) }.getOrNull()
            if (re != null) {
                val matched = files.filter { f ->
                    if (!f.isVideo) return@filter false
                    re.containsMatchIn(f.shortName.ifEmpty { f.name })
                }
                pickFile(matched, episode, fileIdx = null)?.let { return it }
            }
        }
        return pickFile(files, episode, fileIdx)
    }

    /// The usenet `requestdl` leg: mint a direct stream URL for a known usenet_id+file_id. Auth rides the
    /// Bearer header (the key is not repeated in the query). A missing file surfaces as [NotCached].
    private suspend fun usenetRequestDl(base: String, apiKey: String, usenetId: Int, fileId: Int): String {
        val env = getJson("$base/requestdl?usenet_id=$usenetId&file_id=$fileId&redirect=false", apiKey)
        return env.optStringOrNull("data") ?: throw DebridException.NotCached
    }

    /// Fetch one usenet download by numeric id (its mylist item shares the torrent item shape).
    private suspend fun usenetItem(base: String, apiKey: String, id: Int): JSONObject {
        val env = getJson("$base/mylist?id=$id&bypass_cache=true", apiKey)
        return env.optJSONObject("data") ?: JSONObject()
    }

    /// Poll the usenet list until the download is ready: by id when we have one (fetch that item), else scan
    /// mylist for the matching nzb md5, promoting the resolved id out. Uncached surfaces as [NotReady].
    /// Honors cancellation so a raced/bounded resolve stops promptly. Mirrors the Apple pollById.
    private suspend fun usenetPollByHash(base: String, apiKey: String, startId: Int?, hash: String): Pair<Int?, List<DebridFile>> {
        var id = startId
        for (attempt in 0 until POLL_ATTEMPTS) {
            coroutineContext.ensureActive()
            if (attempt > 0) delay(POLL_INTERVAL_MS)
            val known = id
            if (known != null) {
                val item = runCatching { usenetItem(base, apiKey, known) }.getOrNull()
                if (item != null && torBoxReady(item)) {
                    val f = torBoxFiles(item)
                    if (f.isNotEmpty()) return known to f
                }
                continue
            }
            val env = getJson("$base/mylist?bypass_cache=true", apiKey)
            val list = env.optJSONArray("data") ?: continue
            for (i in 0 until list.length()) {
                val item = list.optJSONObject(i) ?: continue
                val itemHash = item.optString("hash").lowercase()
                val f = torBoxFiles(item)
                if (itemHash == hash && torBoxReady(item) && f.isNotEmpty()) {
                    id = item.optIntOrNull("id")
                    return id to f
                }
            }
        }
        throw DebridException.NotReady
    }

    // ------------------------------------------------------------------------------------------------
    // Shared file-pick heuristic (mirrors the Apple DebridResolve.pickFile / episodeMatchScore):
    // explicit fileIdx -> SxEy filename match -> largest video file.
    // ------------------------------------------------------------------------------------------------

    private fun pickFile(files: List<DebridFile>, episode: Episode?, fileIdx: Int?): DebridFile? {
        if (fileIdx != null && fileIdx in files.indices) return files[fileIdx]
        val videos = files.filter { it.isVideo }
        // Provider omitted filenames (isVideo false for every entry, e.g. AllDebrid on a cached single-file
        // torrent): fall back to the whole file list so size selection still resolves instead of
        // NoMatchingFile. Matches the Apple DebridResolve.pickFile `pool = videos.isEmpty ? files : videos`.
        val pool = videos.ifEmpty { files }
        if (pool.isEmpty()) return null
        if (episode == null) return pool.maxByOrNull { it.size }
        val best = pool
            .mapNotNull { f ->
                val name = f.shortName.ifEmpty { f.name }
                val score = episodeMatchScore(name, episode.season, episode.episode)
                if (score > 0) f to score else null
            }
            .maxByOrNull { it.second }
            ?.first
        return best ?: pool.maxByOrNull { it.size }   // pack fallback: biggest video
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

    /// Run a blocking request on [conn] such that a coroutine cancellation (a raced / timed-out resolve leg)
    /// DISCONNECTS the socket, so an in-flight connect/write/read is unblocked promptly instead of parking its
    /// IO thread until the finite connect/read timeout. [HttpURLConnection] reads are NOT interruptible by
    /// coroutine cancellation or Thread.interrupt(); only closing the socket (`disconnect()`) unblocks them,
    /// which is what makes the coordinator's 5s resolve budget real rather than soft. Also releases the
    /// connection if [block] throws BEFORE [execute]'s own finally-disconnect runs (e.g. the output write
    /// fails), so no connection is leaked. `disconnect()` is idempotent, so the cancel-path, throw-path, and
    /// execute()'s finally disconnects safely overlap. Mirrors the Apple URLSession task cancel tearing down
    /// the socket. [block] runs synchronously on the current (Dispatchers.IO) thread; a concurrent cancel on
    /// another thread fires [invokeOnCancellation] and disconnects, unblocking [block]'s read.
    private suspend fun <T> sendCancellable(conn: HttpURLConnection, block: () -> T): T =
        suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation { runCatching { conn.disconnect() } }
            val outcome = try {
                Result.success(block())
            } catch (error: Throwable) {
                // block() threw before execute()'s finally could disconnect (e.g. the write failed): release
                // the socket here so it is never leaked, then surface the failure.
                runCatching { conn.disconnect() }
                Result.failure(error)
            }
            cont.resumeWith(outcome)
        }

    private suspend fun getJson(urlString: String, bearer: String): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "GET"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        return sendCancellable(conn) { execute(conn) }
    }

    private suspend fun postForm(urlString: String, bearer: String, fields: Map<String, String>): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        return sendCancellable(conn) {
            conn.outputStream.use { it.write(formBody(fields).toByteArray(Charsets.UTF_8)) }
            execute(conn)
        }
    }

    /// A Bearer-auth POST with a JSON body (the TorBox usenet createusenetdownload leg). Mirrors the Apple
    /// TorBoxUsenetResolver.postJSON.
    private suspend fun postJson(urlString: String, bearer: String, json: JSONObject): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        conn.setRequestProperty("Content-Type", "application/json")
        conn.doOutput = true
        return sendCancellable(conn) {
            conn.outputStream.use { it.write(json.toString().toByteArray(Charsets.UTF_8)) }
            execute(conn)
        }
    }

    /// A POST whose 2xx carries no JSON body (RD selectFiles is 204). Validates the status only. The whole
    /// body (write + status read + checks) sits inside the try/finally so the connection is ALWAYS released,
    /// including when the write or `responseCodeSafe()` throws.
    private suspend fun postFormNoBody(urlString: String, bearer: String, fields: Map<String, String>) {
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Authorization", "Bearer $bearer")
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        sendCancellable(conn) {
            try {
                conn.outputStream.use { it.write(formBody(fields).toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCodeSafe()
                if (code == 401 || code == 403) throw DebridException.InvalidKey
                if (code !in 200..299) throw DebridException.Provider("HTTP $code")
            } finally {
                conn.disconnect()
            }
        }
    }

    private suspend fun postMultipart(urlString: String, bearer: String, fields: Map<String, String>): JSONObject {
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
        return sendCancellable(conn) {
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            execute(conn)
        }
    }

    /// GET whose auth rides the QUERY string (AllDebrid: `agent` + `apikey`), so NO Authorization header.
    /// Mirrors the Apple AllDebrid `get` (a plain `URLRequest(url:)`).
    private suspend fun getJsonQueryAuth(urlString: String): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "GET"
        return sendCancellable(conn) { execute(conn) }
    }

    /// POST form-urlencoded whose auth rides the QUERY string (Premiumize: `apikey`), so NO Authorization
    /// header. Mirrors the Apple Premiumize `form` (apikey in the query, fields in the body).
    private suspend fun postFormQueryAuth(urlString: String, fields: Map<String, String>): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        return sendCancellable(conn) {
            conn.outputStream.use { it.write(formBody(fields).toByteArray(Charsets.UTF_8)) }
            execute(conn)
        }
    }

    /// Like [postFormQueryAuth] but with REPEATED form keys preserved (Premiumize `/cache/check` needs many
    /// `items[]=...`, which a `Map` would collapse). `apikey` rides the query. Mirrors the Apple `formItems`.
    private suspend fun postFormPairsQueryAuth(urlString: String, pairs: List<Pair<String, String>>): JSONObject {
        val conn = open(urlString)
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        val body = pairs.joinToString("&") { "${enc(it.first)}=${enc(it.second)}" }
        return sendCancellable(conn) {
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            execute(conn)
        }
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
        const val USENET_BASE = "https://api.torbox.app/v1/api/usenet"
        const val RD_BASE = "https://api.real-debrid.com/rest/1.0"
        const val AD_BASE = "https://api.alldebrid.com/v4"
        const val AD_AGENT = "vortx"
        const val PM_BASE = "https://www.premiumize.me/api"

        const val CONNECT_TIMEOUT_MS = 15_000
        const val READ_TIMEOUT_MS = 20_000

        // TorBox poll: up to 10 attempts, 3s apart (~30s streaming budget), matching the Apple resolver.
        const val POLL_ATTEMPTS = 10
        const val POLL_INTERVAL_MS = 3_000L

        // Real-Debrid poll: up to 12 attempts, 2s apart, matching the Apple resolver.
        const val RD_ATTEMPTS = 12
        const val RD_INTERVAL_MS = 2_000L

        // AllDebrid /magnet/status poll: up to 12 attempts, 3s apart, matching the Apple resolver.
        const val AD_ATTEMPTS = 12
        const val AD_INTERVAL_MS = 3_000L

        val RD_DEAD_STATUSES = setOf("magnet_error", "error", "virus", "dead")
        // Active-download statuses that trigger the not-cached fast-fail after one grace poll.
        val RD_ACTIVE_STATUSES = setOf("downloading", "queued", "compressing", "uploading")

        val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "avi", "mov", "ts", "m2ts", "webm", "wmv", "flv", "m4v",
        )
    }
}
