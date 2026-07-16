package com.vortx.android.mediaserver

import com.vortx.android.integrations.IntegrationsHttp
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.net.URLEncoder
import java.util.UUID

/// Jellyfin AUTH (Quick Connect + username/password) plus the Jellyfin-FAMILY resolver ([JellyfinProvider]).
/// Kotlin port of the Jellyfin halves of `app/SourcesShared/MediaServerAuth.swift` +
/// `MediaServerProvider.swift`. Jellyfin AND Emby share this REST surface (same `/Items` query,
/// `AnyProviderIdEquals`, `/Videos/{id}/stream?static=true`, `X-Emby-Token` auth), so ONE provider serves
/// both: [MediaServerCoordinator] builds it for `.jellyfin` and `.emby` alike and reads [MediaServerKind]
/// from the config. Emby's DIFFERENT bit (the `X-Emby-Authorization` sign-in header) lives in [EmbyClient].
///
/// The password entered for the username/password path is used only for the one AuthenticateByName exchange
/// and never stored; only the returned access token is persisted (Keychain).
object JellyfinClient {

    const val APP_VERSION = "1"

    /// The pre-auth `MediaBrowser` header the QuickConnect / AuthenticateByName endpoints require to
    /// identify the client (no token: this is BEFORE sign-in). Mirrors the Apple `embyAuthHeader`.
    fun clientAuthHeader(deviceId: String): String =
        "MediaBrowser Client=\"VortX\", Device=\"VortX\", DeviceId=\"$deviceId\", Version=\"$APP_VERSION\""

    // MARK: - Quick Connect

    /// Is Quick Connect enabled on this server? Fail-soft: any error / non-2xx returns false so the flow
    /// falls back to username + password.
    suspend fun quickConnectEnabled(base: String, deviceId: String): Boolean {
        val root = MediaServerResolve.normalizedBase(base) ?: return false
        val resp = IntegrationsHttp.request(
            method = "GET",
            urlString = "$root/QuickConnect/Enabled",
            headers = mapOf("Authorization" to clientAuthHeader(deviceId), "Accept" to "application/json"),
        )
        if (!resp.isSuccess) return false
        return resp.body.trim().equals("true", ignoreCase = true)
    }

    /// Initiate Quick Connect: returns the secret (polled by [awaitQuickConnect]) and the 6-digit code the
    /// user enters in their Jellyfin app/web.
    suspend fun initiateQuickConnect(base: String, deviceId: String): QuickConnectInit {
        val root = MediaServerResolve.normalizedBase(base) ?: throw MediaServerAuthException.BadUrl
        val resp = IntegrationsHttp.request(
            method = "POST",
            urlString = "$root/QuickConnect/Initiate",
            headers = mapOf("Authorization" to clientAuthHeader(deviceId), "Accept" to "application/json"),
        )
        if (resp.status == 0) throw MediaServerAuthException.Network("Could not reach the server.")
        if (!resp.isSuccess) throw MediaServerAuthException.Http(resp.status)
        val json = runCatching { JSONObject(resp.body) }.getOrNull() ?: throw MediaServerAuthException.Decode
        val secret = json.optString("Secret")
        val code = json.optString("Code")
        if (secret.isEmpty()) throw MediaServerAuthException.Decode
        return QuickConnectInit(secret = secret, code = code)
    }

    /// Poll Quick Connect until the user authorizes, then exchange for an access token. Honors cancellation
    /// (the caller's coroutine scope) and stops after [expiresIn] seconds. Mirrors `jellyfinAwaitQuickConnect`.
    suspend fun awaitQuickConnect(
        base: String,
        secret: String,
        deviceId: String,
        interval: Int = 3,
        expiresIn: Int = 300,
    ): MediaServerAuthResult {
        val root = MediaServerResolve.normalizedBase(base) ?: throw MediaServerAuthException.BadUrl
        val header = clientAuthHeader(deviceId)
        val deadline = nowSeconds() + expiresIn
        while (nowSeconds() < deadline) {
            delay(maxOf(interval, 1) * 1000L)
            val resp = IntegrationsHttp.request(
                method = "GET",
                urlString = "$root/QuickConnect/Connect?secret=${enc(secret)}",
                headers = mapOf("Authorization" to header, "Accept" to "application/json"),
            )
            if (resp.isSuccess) {
                val authed = runCatching { JSONObject(resp.body).optBoolean("Authenticated", false) }.getOrDefault(false)
                if (authed) return authenticateWithQuickConnect(root, secret, deviceId)
            }
        }
        throw MediaServerAuthException.TimedOut
    }

    private suspend fun authenticateWithQuickConnect(root: String, secret: String, deviceId: String): MediaServerAuthResult {
        val resp = IntegrationsHttp.request(
            method = "POST",
            urlString = "$root/Users/AuthenticateWithQuickConnect",
            headers = mapOf(
                "Authorization" to clientAuthHeader(deviceId),
                "Content-Type" to "application/json",
                "Accept" to "application/json",
            ),
            body = JSONObject().put("Secret", secret).toString(),
        )
        if (resp.status == 0) throw MediaServerAuthException.Network("Could not reach the server.")
        if (!resp.isSuccess) throw MediaServerAuthException.Http(resp.status)
        return authResult(resp.body, root)
    }

    // MARK: - Username / password (Jellyfin fallback AND Emby primary)

    /// Username/password sign-in. [headerField] is `Authorization` for Jellyfin, `X-Emby-Authorization`
    /// for Emby (both carry the same MediaBrowser value). The password is used only for this one exchange.
    /// Mirrors the Apple `authenticateByName`.
    suspend fun authenticateByName(
        base: String,
        username: String,
        password: String,
        headerField: String,
        deviceId: String,
    ): MediaServerAuthResult {
        val root = MediaServerResolve.normalizedBase(base) ?: throw MediaServerAuthException.BadUrl
        val resp = IntegrationsHttp.request(
            method = "POST",
            urlString = "$root/Users/AuthenticateByName",
            headers = mapOf(
                headerField to clientAuthHeader(deviceId),
                "Content-Type" to "application/json",
                "Accept" to "application/json",
            ),
            body = JSONObject().put("Username", username).put("Pw", password).toString(),
        )
        if (resp.status == 0) throw MediaServerAuthException.Network("Could not reach the server.")
        if (!resp.isSuccess) throw MediaServerAuthException.Http(resp.status)
        return authResult(resp.body, root)
    }

    suspend fun authByPassword(base: String, username: String, password: String, deviceId: String): MediaServerAuthResult =
        authenticateByName(base, username, password, headerField = "Authorization", deviceId = deviceId)

    // MARK: - Response mapping

    private suspend fun authResult(body: String, base: String): MediaServerAuthResult {
        val json = runCatching { JSONObject(body) }.getOrNull() ?: throw MediaServerAuthException.Decode
        val token = json.optString("AccessToken")
        if (token.isEmpty()) throw MediaServerAuthException.Decode
        val userId = json.optJSONObject("User")?.optString("Id").orEmpty()
        val info = publicServerInfo(base)
        return MediaServerAuthResult(
            accessToken = token,
            userId = userId,
            serverId = json.optString("ServerId").takeIf { it.isNotEmpty() } ?: info?.first,
            serverName = info?.second,
        )
    }

    /// `GET /System/Info/Public` -> (id, name). Best-effort; null on any failure. Mirrors the Apple
    /// `publicServerInfo`.
    suspend fun publicServerInfo(base: String): Pair<String?, String?>? {
        val root = MediaServerResolve.normalizedBase(base) ?: return null
        val resp = IntegrationsHttp.request(
            method = "GET",
            urlString = "$root/System/Info/Public",
            headers = mapOf("Accept" to "application/json"),
        )
        if (!resp.isSuccess) return null
        val json = runCatching { JSONObject(resp.body) }.getOrNull() ?: return null
        return json.optString("Id").takeIf { it.isNotEmpty() } to json.optString("ServerName").takeIf { it.isNotEmpty() }
    }

    private fun nowSeconds(): Long = System.currentTimeMillis() / 1000L
    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}

/// Jellyfin/Emby native resolver: turn a VortX detail id (imdb `tt...` or tmdb `tmdb:123`) into a direct,
/// static direct-play URL from the user's own server. Kotlin port of the Apple `JellyfinProvider`.
///
/// Lookup: `GET /Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=ProviderIds,Path,MediaSources&
/// AnyProviderIdEquals=imdb.{tt}`. IMPORTANT: `AnyProviderIdEquals` has a known reliability bug where it can
/// return the WHOLE library, so we ALWAYS re-filter client-side on `ProviderIds.Imdb == tt` and never trust
/// the server filter alone. Series resolve the SERIES by its id, then query its episodes and pick the SxEy
/// child. Stream URL: `GET /Videos/{itemId}/stream?static=true&mediaSourceId=&container=&api_key=` (the
/// original file, no transcode).
class JellyfinProvider(private val config: MediaServerConfig) : MediaServerProvider {

    override val kind: MediaServerKind = config.kind
    private val base: String = MediaServerResolve.normalizedBase(config.baseUrl) ?: config.baseUrl.trimEnd('/')
    private val apiKey: String = config.apiKey
    private val userId: String = config.userId.trim()
    private val serverId: UUID = config.id
    private val serverName: String = config.displayName

    override suspend fun findByImdb(providerId: String, season: Int?, episode: Int?): MediaServerHit? {
        val q = providerQuery(providerId) ?: return null
        if (season == null || episode == null) {
            val items = queryItems(
                "Recursive" to "true",
                "IncludeItemTypes" to "Movie,Episode",
                "Fields" to "ProviderIds,Path,MediaSources",
                "AnyProviderIdEquals" to q.equals,
                "Limit" to "50",
            )
            val match = items.firstOrNull(q.verify) ?: return null
            return hit(match)
        }
        val seriesItems = queryItems(
            "Recursive" to "true",
            "IncludeItemTypes" to "Series",
            "Fields" to "ProviderIds",
            "AnyProviderIdEquals" to q.equals,
            "Limit" to "50",
        )
        val series = seriesItems.firstOrNull(q.verify) ?: return null
        return episode(series.id, season, episode)
    }

    override suspend fun findByTitle(title: String, year: Int?, season: Int?, episode: Int?): MediaServerHit? {
        val term = title.trim()
        if (term.isEmpty()) return null
        if (season == null || episode == null) {
            val params = mutableListOf(
                "Recursive" to "true",
                "IncludeItemTypes" to "Movie",
                "Fields" to "ProviderIds,Path,MediaSources",
                "SearchTerm" to term,
                "Limit" to "20",
            )
            if (year != null) params += "Years" to year.toString()
            val items = queryItems(*params.toTypedArray())
            val match = items.firstOrNull() ?: return null // SearchTerm is server-ranked; take the top
            return hit(match)
        }
        val params = mutableListOf(
            "Recursive" to "true",
            "IncludeItemTypes" to "Series",
            "Fields" to "ProviderIds",
            "SearchTerm" to term,
            "Limit" to "20",
        )
        if (year != null) params += "Years" to year.toString()
        val seriesItems = queryItems(*params.toTypedArray())
        val series = seriesItems.firstOrNull() ?: return null
        return episode(series.id, season, episode)
    }

    private suspend fun episode(seriesId: String, season: Int, episode: Int): MediaServerHit? {
        val items = queryItems(
            "ParentId" to seriesId,
            "Recursive" to "true",
            "IncludeItemTypes" to "Episode",
            "Fields" to "ProviderIds,Path,MediaSources",
            "Limit" to "1000",
        )
        val best = items
            .mapNotNull { item ->
                val s = MediaServerResolve.episodeMatchScore(item.parentIndex, item.index, season, episode)
                if (s > 0) item to s else null
            }
            .maxByOrNull { it.second }?.first ?: return null
        return hit(best)
    }

    // MARK: Hit assembly

    private fun hit(item: Item): MediaServerHit? {
        val source = item.mediaSources.firstOrNull()
        val container = source?.container
        val resolution = source?.videoHeight
        val url = streamUrl(item.id, source?.id, container) ?: return null
        val coarseType = if (item.type.equals("episode", ignoreCase = true)) "episode" else "movie"
        val fileName = source?.path?.substringAfterLast('/')?.takeIf { it.isNotEmpty() }
        return MediaServerHit(
            kind = kind,
            itemId = item.id,
            name = item.name ?: item.id,
            type = coarseType,
            container = container,
            resolution = resolution,
            streamUrl = url,
            serverId = serverId,
            serverName = serverName,
            sizeBytes = source?.size,
            fileName = fileName,
        )
    }

    private fun streamUrl(itemId: String, mediaSourceId: String?, container: String?): String? {
        if (base.isEmpty()) return null
        val params = buildString {
            append("static=true")
            if (!mediaSourceId.isNullOrEmpty()) append("&mediaSourceId=").append(enc(mediaSourceId))
            if (!container.isNullOrEmpty()) append("&container=").append(enc(container))
            append("&api_key=").append(enc(apiKey))
        }
        return "$base/Videos/$itemId/stream?$params"
    }

    // MARK: HTTP + parsing

    private suspend fun queryItems(vararg extra: Pair<String, String>): List<Item> {
        val params = extra.toMutableList()
        if (userId.isNotEmpty()) params += "UserId" to userId
        params += "EnableTotalRecordCount" to "false"
        val query = params.joinToString("&") { "${enc(it.first)}=${enc(it.second)}" }
        val resp = IntegrationsHttp.request(
            method = "GET",
            urlString = "$base/Items?$query",
            headers = authHeaders(),
        )
        if (resp.status == 401 || resp.status == 403) throw MediaServerProviderException.AuthFailed
        if (!resp.isSuccess) return emptyList()
        val root = runCatching { JSONObject(resp.body) }.getOrNull() ?: return emptyList()
        val arr = root.optJSONArray("Items") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i -> arr.optJSONObject(i)?.let(::parseItem) }
    }

    private fun authHeaders(): Map<String, String> = mapOf(
        // Jellyfin's documented API-key scheme; only Token is required, the rest is advisory metadata.
        "Authorization" to "MediaBrowser Token=\"$apiKey\", Client=\"VortX\", Device=\"VortX\", Version=\"${JellyfinClient.APP_VERSION}\"",
        // Legacy fallback header for older servers that don't parse the scheme (harmless on modern ones).
        "X-Emby-Token" to apiKey,
        "Accept" to "application/json",
    )

    private data class Item(
        val id: String,
        val name: String?,
        val type: String?,
        val parentIndex: Int?,
        val index: Int?,
        val providerIds: Map<String, String>,
        val mediaSources: List<Source>,
    )

    private data class Source(
        val id: String?,
        val container: String?,
        val path: String?,
        val size: Long?,
        val videoHeight: Int?,
    )

    private fun parseItem(o: JSONObject): Item? {
        val id = o.optString("Id").takeIf { it.isNotEmpty() } ?: return null
        val providerIds = o.optJSONObject("ProviderIds")?.let { p ->
            p.keys().asSequence().associateWith { p.optString(it) }
        } ?: emptyMap()
        val sources = o.optJSONArray("MediaSources")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.let(::parseSource) }
        } ?: emptyList()
        return Item(
            id = id,
            name = o.optString("Name").takeIf { it.isNotEmpty() },
            type = o.optString("Type").takeIf { it.isNotEmpty() },
            parentIndex = o.optIntOrNull("ParentIndexNumber"),
            index = o.optIntOrNull("IndexNumber"),
            providerIds = providerIds,
            mediaSources = sources,
        )
    }

    private fun parseSource(o: JSONObject): Source {
        val height = o.optJSONArray("MediaStreams")?.let { streams ->
            (0 until streams.length())
                .mapNotNull { streams.optJSONObject(it) }
                .firstOrNull { it.optString("Type").equals("Video", ignoreCase = true) }
                ?.optIntOrNull("Height")
        }
        return Source(
            id = o.optString("Id").takeIf { it.isNotEmpty() },
            container = o.optString("Container").takeIf { it.isNotEmpty() },
            path = o.optString("Path").takeIf { it.isNotEmpty() },
            size = o.optLongOrNull("Size"),
            videoHeight = height,
        )
    }

    private fun providerId(item: Item, key: String): String? =
        item.providerIds.entries.firstOrNull { it.key.equals(key, ignoreCase = true) }?.value

    /// Parse a VortX detail id into the Jellyfin `AnyProviderIdEquals` value + a client-side verifier (the
    /// server filter has a known whole-library bug). Supports imdb (`tt...`) and tmdb (`tmdb:123`).
    private fun providerQuery(id: String): ProviderQuery? {
        val s = id.trim()
        if (s.startsWith("tt")) return ProviderQuery("imdb.$s") { providerId(it, "imdb") == s }
        if (s.startsWith("tmdb:")) {
            val n = s.removePrefix("tmdb:")
            if (n.isEmpty()) return null
            return ProviderQuery("tmdb.$n") { providerId(it, "tmdb") == n }
        }
        return null
    }

    private inner class ProviderQuery(val equals: String, val verify: (Item) -> Boolean)

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}
