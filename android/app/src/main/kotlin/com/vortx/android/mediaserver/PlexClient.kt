package com.vortx.android.mediaserver

import com.vortx.android.integrations.IntegrationsHttp
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.UUID

/// Plex AUTH (PIN link against plex.tv) plus the Plex resolver ([PlexProvider]). Kotlin port of the Plex
/// halves of `app/SourcesShared/MediaServerAuth.swift` + `app/SourcesShared/PlexProvider.swift`.
///
/// AUTH: request a strong PIN, show its code (the user enters it on plex.tv/link), poll the PIN until it
/// carries an account authToken, then discover the account's Plex Media Servers (each with its OWN per-server
/// access token + ordered, reachability-probed connection URLs). Every call carries the stable
/// `X-Plex-Client-Identifier` so the granted token stays anchored across discovery re-runs.
object PlexClient {

    const val PRODUCT = "VortX"
    private const val PINS_URL = "https://plex.tv/api/v2/pins"
    private const val RESOURCES_URL = "https://plex.tv/api/v2/resources"

    private fun headers(clientId: String): Map<String, String> = mapOf(
        "X-Plex-Product" to PRODUCT,
        "X-Plex-Client-Identifier" to clientId,
        "Accept" to "application/json",
    )

    /// Step 1: request a strong PIN. Returns the pin id + the code to display.
    suspend fun requestPin(clientId: String): PlexPin {
        val resp = IntegrationsHttp.request(
            method = "POST",
            urlString = "$PINS_URL?strong=true",
            headers = headers(clientId),
        )
        if (resp.status == 0) throw MediaServerAuthException.Network("Could not reach plex.tv.")
        if (!resp.isSuccess) throw MediaServerAuthException.Http(resp.status)
        val json = runCatching { JSONObject(resp.body) }.getOrNull() ?: throw MediaServerAuthException.Decode
        val id = json.optLongOrNull("id") ?: throw MediaServerAuthException.Decode
        val code = json.optString("code")
        if (code.isEmpty()) throw MediaServerAuthException.Decode
        return PlexPin(id = id, code = code)
    }

    /// Step 2: poll the PIN until it carries an `authToken` (the user entered the code) or it expires.
    /// Returns the plex.tv ACCOUNT token. Honors cancellation (the caller's coroutine scope).
    suspend fun pollForToken(pin: PlexPin, clientId: String, intervalSec: Int = 2, expiresInSec: Int = 900): String {
        val deadline = nowSeconds() + expiresInSec
        while (nowSeconds() < deadline) {
            delay(maxOf(intervalSec, 1) * 1000L)
            val resp = IntegrationsHttp.request(
                method = "GET",
                urlString = "$PINS_URL/${pin.id}",
                headers = headers(clientId),
            )
            if (resp.isSuccess) {
                val token = runCatching { JSONObject(resp.body).optString("authToken") }.getOrNull()
                if (!token.isNullOrEmpty()) return token
            }
        }
        throw MediaServerAuthException.TimedOut
    }

    /// Step 3: discover the account's Plex Media Servers, each with its own access token + reachability-probed
    /// connections (local -> remote -> relay). Mirrors the Apple `plexDiscoverServers`.
    suspend fun discoverServers(accountToken: String, clientId: String): List<PlexServerCandidate> {
        val resp = IntegrationsHttp.request(
            method = "GET",
            urlString = "$RESOURCES_URL?includeHttps=1&includeRelay=1",
            headers = headers(clientId) + ("X-Plex-Token" to accountToken),
        )
        if (resp.status == 0) throw MediaServerAuthException.Network("Could not reach plex.tv.")
        if (!resp.isSuccess) throw MediaServerAuthException.Http(resp.status)
        val arr = runCatching { JSONArray(resp.body) }.getOrNull() ?: throw MediaServerAuthException.Decode
        val out = mutableListOf<PlexServerCandidate>()
        for (i in 0 until arr.length()) {
            val r = arr.optJSONObject(i) ?: continue
            val provides = r.optString("provides").split(",").map { it.trim() }
            if (!provides.contains("server")) continue
            val machineId = r.optString("clientIdentifier").takeIf { it.isNotEmpty() } ?: continue
            val token = r.optString("accessToken").takeIf { it.isNotEmpty() } ?: continue
            val conns = r.optJSONArray("connections")
            val ordered = orderedConnections(conns)
            if (ordered.isEmpty()) continue
            val reachable = probeReachable(ordered, token)
            val urls = reachable.ifEmpty { ordered }
            out += PlexServerCandidate(
                machineId = machineId,
                name = r.optString("name").takeIf { it.isNotEmpty() } ?: "Plex",
                accessToken = token,
                urls = urls,
            )
        }
        return out
    }

    /// Order connections local first, then non-relay remote, then relay (matching the Apple sort).
    private fun orderedConnections(conns: JSONArray?): List<String> {
        if (conns == null) return emptyList()
        data class Conn(val uri: String, val rank: Int)
        val list = (0 until conns.length()).mapNotNull { idx ->
            val c = conns.optJSONObject(idx) ?: return@mapNotNull null
            val uri = c.optString("uri").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val rank = when {
                c.optBoolean("local", false) -> 0
                c.optBoolean("relay", false) -> 2
                else -> 1
            }
            Conn(uri, rank)
        }
        return list.sortedBy { it.rank }.map { it.uri }
    }

    /// Probe each `{uri}/identity` concurrently with a short read; keep the reachable ones in input order.
    /// Fail-soft: an all-unreachable list yields empty and the caller keeps the unprobed order.
    private suspend fun probeReachable(uris: List<String>, token: String): List<String> = coroutineScope {
        uris.map { uri ->
            async {
                val resp = IntegrationsHttp.request(
                    method = "GET",
                    urlString = "$uri/identity",
                    headers = mapOf("X-Plex-Token" to token, "Accept" to "application/json"),
                )
                uri to resp.isSuccess
            }
        }.awaitAll().filter { it.second }.map { it.first }
    }

    private fun nowSeconds(): Long = System.currentTimeMillis() / 1000L
}

/// Plex Media Server native resolver: turn a VortX detail id (imdb `tt...` or tmdb `tmdb:123`) into a direct
/// file URL from the user's own PMS. Kotlin port of the Apple `PlexProvider`.
///
/// Auth: the per-server access token is sent as `X-Plex-Token`. Matching: the GUID filter
/// `GET {server}/library/all?includeGuids=1&guid=imdb://{tt}`, with every returned item re-verified
/// client-side on its own `Guid[]` (legacy-agent libraries + loose filters can return non-matches). Episodes
/// resolve the show, then `/library/metadata/{ratingKey}/allLeaves` scored on parentIndex/index. A title+year
/// `/search` is the fallback. Direct play: `{serverUrl}{Media.Part.key}?X-Plex-Token=<token>` (original file).
/// URLs are tried in discovered order; the first that answers is remembered for the actor's lifetime.
class PlexProvider(config: MediaServerConfig, private val clientId: String) : MediaServerProvider {

    override val kind: MediaServerKind = MediaServerKind.PLEX
    private val token: String = config.apiKey
    private val serverId: UUID = config.id
    private val serverName: String = config.displayName
    private val urls: List<String> = (config.urls.ifEmpty { listOf(config.baseUrl) })
        .mapNotNull { MediaServerResolve.normalizedBase(it) }
    @Volatile private var workingBase: String? = null

    override suspend fun findByImdb(providerId: String, season: Int?, episode: Int?): MediaServerHit? {
        val guid = plexGuid(providerId) ?: return null
        if (season == null || episode == null) {
            val items = libraryAll(guid)
            val match = items.firstOrNull { it.guids.contains(guid) && it.firstPartKey() != null } ?: return null
            return hit(match)
        }
        val shows = libraryAll(guid)
        val show = shows.firstOrNull { it.guids.contains(guid) } ?: return null
        val ratingKey = show.ratingKey ?: return null
        return episode(ratingKey, season, episode)
    }

    override suspend fun findByTitle(title: String, year: Int?, season: Int?, episode: Int?): MediaServerHit? {
        val term = title.trim()
        if (term.isEmpty()) return null
        val results = search(term)
        fun yearOk(m: Metadatum): Boolean = year == null || m.year == null || m.year == year
        if (season == null || episode == null) {
            val match = results.firstOrNull { it.type == "movie" && yearOk(it) && it.firstPartKey() != null } ?: return null
            return hit(match)
        }
        val show = results.firstOrNull { it.type == "show" && yearOk(it) } ?: return null
        val ratingKey = show.ratingKey ?: return null
        return episode(ratingKey, season, episode)
    }

    private suspend fun episode(showRatingKey: String, season: Int, episode: Int): MediaServerHit? {
        val leaves = allLeaves(showRatingKey)
        val best = leaves
            .mapNotNull { m ->
                val s = MediaServerResolve.episodeMatchScore(m.parentIndex, m.index, season, episode)
                if (s > 0) m to s else null
            }
            .maxByOrNull { it.second }?.first ?: return null
        return hit(best)
    }

    // MARK: Hit assembly

    private fun hit(m: Metadatum): MediaServerHit? {
        val base = workingBase ?: return null
        val media = m.media.firstOrNull() ?: return null
        val part = media.parts.firstOrNull() ?: return null
        val key = part.key ?: return null
        val url = "$base$key?X-Plex-Token=${enc(token)}"
        val container = part.container ?: media.container
        val resolution = plexHeight(media.videoResolution)
        val coarseType = if (m.type == "episode") "episode" else "movie"
        val fileName = part.file?.substringAfterLast('/')?.takeIf { it.isNotEmpty() }
        return MediaServerHit(
            kind = kind,
            itemId = m.ratingKey ?: key,
            name = m.title ?: "Plex",
            type = coarseType,
            container = container,
            resolution = resolution,
            streamUrl = url,
            serverId = serverId,
            serverName = serverName,
            sizeBytes = part.size,
            fileName = fileName,
        )
    }

    // MARK: HTTP

    private suspend fun libraryAll(guid: String): List<Metadatum> =
        getMetadata("/library/all", listOf("includeGuids" to "1", "guid" to guid))

    private suspend fun search(query: String): List<Metadatum> =
        getMetadata("/search", listOf("includeGuids" to "1", "query" to query))

    private suspend fun allLeaves(showRatingKey: String): List<Metadatum> =
        getMetadata("/library/metadata/$showRatingKey/allLeaves", emptyList())

    /// Run a Plex GET across the ordered URLs (first success wins, remembered as [workingBase]) and decode the
    /// `MediaContainer.Metadata` array. Auth via `X-Plex-Token`.
    private suspend fun getMetadata(path: String, query: List<Pair<String, String>>): List<Metadatum> {
        if (urls.isEmpty()) return emptyList()
        val wb = workingBase
        val ordered = if (wb != null) listOf(wb) + urls.filter { it != wb } else urls
        for (base in ordered) {
            val params = (query + ("X-Plex-Token" to token)).joinToString("&") { "${enc(it.first)}=${enc(it.second)}" }
            val resp = IntegrationsHttp.request(
                method = "GET",
                urlString = "$base$path?$params",
                headers = mapOf(
                    "Accept" to "application/json",
                    "X-Plex-Product" to PlexClient.PRODUCT,
                    "X-Plex-Client-Identifier" to clientId,
                ),
            )
            if (resp.status == 401 || resp.status == 403) throw MediaServerProviderException.AuthFailed
            if (!resp.isSuccess) continue
            workingBase = base
            return runCatching { parseMetadata(resp.body) }.getOrDefault(emptyList())
        }
        return emptyList()
    }

    // MARK: Parsing

    private data class Metadatum(
        val ratingKey: String?,
        val title: String?,
        val type: String?,
        val year: Int?,
        val index: Int?,
        val parentIndex: Int?,
        val guids: List<String>,
        val media: List<Media>,
    ) {
        fun firstPartKey(): String? = media.firstOrNull()?.parts?.firstOrNull()?.key
    }

    private data class Media(val videoResolution: String?, val container: String?, val parts: List<Part>)
    private data class Part(val key: String?, val file: String?, val size: Long?, val container: String?)

    private fun parseMetadata(body: String): List<Metadatum> {
        val root = JSONObject(body)
        val mc = root.optJSONObject("MediaContainer") ?: return emptyList()
        val arr = mc.optJSONArray("Metadata") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i -> arr.optJSONObject(i)?.let(::parseMetadatum) }
    }

    private fun parseMetadatum(o: JSONObject): Metadatum {
        val guids = o.optJSONArray("Guid")?.let { g ->
            (0 until g.length()).mapNotNull { g.optJSONObject(it)?.optString("id")?.takeIf { s -> s.isNotEmpty() } }
        } ?: emptyList()
        val media = o.optJSONArray("Media")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.let(::parseMedia) }
        } ?: emptyList()
        return Metadatum(
            ratingKey = o.optString("ratingKey").takeIf { it.isNotEmpty() },
            title = o.optString("title").takeIf { it.isNotEmpty() },
            type = o.optString("type").takeIf { it.isNotEmpty() },
            year = o.optIntOrNull("year"),
            index = o.optIntOrNull("index"),
            parentIndex = o.optIntOrNull("parentIndex"),
            guids = guids,
            media = media,
        )
    }

    private fun parseMedia(o: JSONObject): Media {
        val parts = o.optJSONArray("Part")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.let(::parsePart) }
        } ?: emptyList()
        return Media(
            videoResolution = o.optString("videoResolution").takeIf { it.isNotEmpty() },
            container = o.optString("container").takeIf { it.isNotEmpty() },
            parts = parts,
        )
    }

    private fun parsePart(o: JSONObject): Part = Part(
        key = o.optString("key").takeIf { it.isNotEmpty() },
        file = o.optString("file").takeIf { it.isNotEmpty() },
        size = o.optLongOrNull("size"),
        container = o.optString("container").takeIf { it.isNotEmpty() },
    )

    // MARK: Helpers

    /// The Plex GUID string for a VortX detail id: `imdb://tt...` or `tmdb://123`.
    private fun plexGuid(id: String): String? {
        val s = id.trim()
        if (s.startsWith("tt")) return "imdb://$s"
        if (s.startsWith("tmdb:")) {
            val n = s.removePrefix("tmdb:")
            return if (n.isEmpty()) null else "tmdb://$n"
        }
        return null
    }

    /// Map Plex's `videoResolution` string ("4k"/"1080"/"720"/"sd") to a vertical pixel height.
    private fun plexHeight(s: String?): Int? {
        val v = s?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        return when (v) {
            "4k" -> 2160
            "1080" -> 1080
            "720" -> 720
            "480", "sd" -> 480
            else -> v.toIntOrNull()
        }
    }

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}
