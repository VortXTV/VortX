package com.vortx.android.mediaserver

import org.json.JSONObject
import java.util.UUID

/// Shared value types + helpers for the personal media-server integration (Plex / Jellyfin / Emby).
/// Kotlin port of the Apple `app/SourcesShared/MediaServerProvider.swift` value layer + `MediaServerStore`
/// record, kept in one small file so the clients and the repository share exactly one definition of each
/// shape (no drift between the Plex, Jellyfin, and Emby lanes).
///
/// CREDENTIAL CLASS (matches the Apple doc): a media-server access token is account-wide, so it is fetched
/// DIRECTLY by the client against the user's own server / plex.tv and never transits VortX infrastructure.
/// Playback likewise streams straight from the server to the device. Tokens live only in the encrypted
/// [com.vortx.android.integrations.SecureTokenStore]; the non-secret record metadata below sits in plain
/// prefs (the Android analogue of the Apple UserDefaults / Keychain split in `MediaServerStore.swift`).

/// Which media-server product a config points at. [wire] is the stable persisted/on-the-wire string.
enum class MediaServerKind(val wire: String, val label: String) {
    PLEX("plex", "Plex"),
    JELLYFIN("jellyfin", "Jellyfin"),
    EMBY("emby", "Emby");

    companion object {
        fun fromWire(value: String?): MediaServerKind? =
            entries.firstOrNull { it.wire.equals(value?.trim(), ignoreCase = true) }
    }
}

/// The injectable credentials for one connected server, built from a [MediaServerRecord] + its Keychain
/// token. [baseUrl] is the primary connection ([urls].first); Plex may carry several ([urls]) tried in
/// order, Jellyfin/Emby carry one. Mirrors the Apple `MediaServerConfig`.
data class MediaServerConfig(
    val kind: MediaServerKind,
    val baseUrl: String,
    val apiKey: String,      // Jellyfin/Emby access token, or the Plex per-server access token
    val userId: String,      // Jellyfin/Emby user id (Plex: empty)
    val id: UUID,
    val displayName: String,
    val urls: List<String>,
)

/// A matched server item with its resolved DIRECT-play URL (the original file, no transcode). The token is
/// carried in the URL's query (`?api_key=` / `?X-Plex-Token=`), so the URL is self-authenticating and the
/// player needs no extra headers. Mirrors the Apple `MediaServerHit`.
data class MediaServerHit(
    val kind: MediaServerKind,
    val itemId: String,
    val name: String,
    /// Coarse Stremio-style type of the matched item: "movie" or "episode".
    val type: String,
    val container: String?,
    val resolution: Int?,
    val streamUrl: String,
    val serverId: UUID,
    val serverName: String,
    val sizeBytes: Long?,
    val fileName: String?,
)

/// The result of a successful Jellyfin / Emby sign-in. Mirrors the Apple `MediaServerAuthResult`.
data class MediaServerAuthResult(
    val accessToken: String,
    val userId: String,
    val serverId: String?,
    val serverName: String?,
)

/// A Plex server discovered from plex.tv resources, with its own per-server access token and ordered,
/// reachability-probed connection URLs (local -> remote -> relay). Mirrors the Apple `PlexServerCandidate`.
data class PlexServerCandidate(
    val machineId: String,
    val name: String,
    val accessToken: String,
    val urls: List<String>,
)

/// A Plex PIN: the [code] the user types on plex.tv/link, plus the [id] the poll loop reads.
data class PlexPin(val id: Long, val code: String) {
    val linkUrl: String get() = "https://plex.tv/link"
}

/// A Jellyfin Quick Connect handshake: the [secret] the poll loop reads, the [code] the user enters in
/// their Jellyfin app/web under Quick Connect.
data class QuickConnectInit(val secret: String, val code: String)

/// The non-secret, persisted metadata for one connected server. The token itself is NOT here (Keychain
/// only). Mirrors the Apple `MediaServerRecord`.
data class MediaServerRecord(
    val id: UUID,
    val name: String,
    val kind: MediaServerKind,
    val urls: List<String>,
    val userId: String,
    val machineId: String?,
    val addedAtMillis: Long,
    val needsReauth: Boolean,
)

/// One media server's resolver. Each conformer owns its own HTTP + serial work so the coordinator can fan a
/// query out across configured servers concurrently. Mirrors the Apple `MediaServerProviding` protocol.
interface MediaServerProvider {
    val kind: MediaServerKind

    /// Find by a VortX detail id (imdb `tt...` or tmdb `tmdb:123`). For a series pass [season]/[episode] to
    /// resolve the SxEy episode. Returns null on a clean no-match; throws [MediaServerProviderException] on
    /// auth/network failure.
    suspend fun findByImdb(providerId: String, season: Int?, episode: Int?): MediaServerHit?

    /// Title+year fallback when no id matched. For a series, [season]/[episode] resolve the episode.
    suspend fun findByTitle(title: String, year: Int?, season: Int?, episode: Int?): MediaServerHit?
}

/// Provider-side failures (kept distinct from the connect-flow [MediaServerAuthException]). Mirrors the
/// Apple `MediaServerError`.
sealed class MediaServerProviderException(message: String) : Exception(message) {
    data object AuthFailed : MediaServerProviderException("The server rejected the stored login.")
    data class ProviderError(val detail: String) : MediaServerProviderException(detail)
}

/// Typed failures surfaced by the connect flows, mapping the documented HTTP statuses + transport/decode
/// faults, so the settings screen can show a real message. Mirrors the Apple `MediaServerAuthError`.
sealed class MediaServerAuthException(message: String) : Exception(message) {
    data object BadUrl : MediaServerAuthException("That server address does not look valid.")
    data object TimedOut : MediaServerAuthException("Timed out waiting for you to authorize.")
    data object Cancelled : MediaServerAuthException("Cancelled.")
    data object Decode : MediaServerAuthException("The server sent a response VortX could not read.")
    data class Http(val status: Int) : MediaServerAuthException("The server returned an error (HTTP $status).")
    data class Network(val detail: String) : MediaServerAuthException(detail)
}

/// Stateless shared helpers used by every provider + client. Mirrors the Apple `MediaServerResolve`.
object MediaServerResolve {
    /// Normalize a user-pasted base URL: trim, drop trailing slashes, require an http(s) scheme + host.
    /// Returns null when it cannot be made into a usable root (callers fail soft).
    fun normalizedBase(raw: String?): String? {
        var s = raw?.trim().orEmpty()
        if (s.isEmpty()) return null
        while (s.endsWith("/")) s = s.dropLast(1)
        val lower = s.lowercase()
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return null
        // Require a non-empty host after the scheme.
        val afterScheme = s.substringAfter("://", "")
        val host = afterScheme.substringBefore('/').substringBefore(':')
        if (host.isEmpty()) return null
        return s
    }

    /// Score an episode item against a SxEy target: exact (season+episode) = 2; episode-only (season
    /// unknown on the item) = 1; else 0. Lets us pick the right episode when a query returns a whole
    /// season. Mirrors the Apple `episodeMatchScore`.
    fun episodeMatchScore(parentIndex: Int?, index: Int?, season: Int, episode: Int): Int {
        if (index == null || index != episode) return 0
        if (parentIndex != null) return if (parentIndex == season) 2 else 0
        return 1
    }

    /// The provider id a detail page carries, mapped to (imdb `tt...`) or (tmdb numeric). Null for an id
    /// scheme neither client can match (kitsu-only, etc.).
    fun parseImdb(detailId: String?): String? =
        detailId?.trim()?.takeIf { it.startsWith("tt") }

    fun parseTmdb(detailId: String?): String? {
        val s = detailId?.trim() ?: return null
        if (!s.startsWith("tmdb:")) return null
        return s.removePrefix("tmdb:").takeIf { it.isNotEmpty() }
    }
}

/// `org.json` returns 0 for a missing int/long; these treat absent/null as null so a real 0 is never
/// confused with "not reported" (matters for size / episode index). Shared by every client.
internal fun JSONObject.optIntOrNull(key: String): Int? = if (has(key) && !isNull(key)) optInt(key) else null
internal fun JSONObject.optLongOrNull(key: String): Long? = if (has(key) && !isNull(key)) optLong(key) else null
