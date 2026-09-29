package com.vortx.android.player

import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.MediaRef
import com.vortx.android.model.SubtitleRequestMetadata
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/// One external subtitle offered by a subtitles add-on (e.g. an OpenSubtitles add-on). Mirrors Apple
/// `AddonSubtitle` (SubtitleAddons.swift:4).
data class AddonSubtitle(
    val id: String,
    val url: String,
    val lang: String,
    val addonName: String,
    val releaseName: String? = null,
) {
    val displayTitle: String get() = releaseName?.takeIf { it.isNotBlank() }
        ?.let { "$addonName · $it" } ?: addonName
}

/// A minimal installed subtitle add-on to query: the base URL and a display name. Mirrors Apple
/// `SubtitleAddonSource` (SubtitleAddons.swift:15).
data class SubtitleAddonSource(
    val baseUrl: String,
    val name: String,
)

/// Fetches external subtitles from every installed add-on that declares the `subtitles` resource,
/// the way the official clients do -- the Android port of Apple `SubtitleAddonService`
/// (SubtitleAddons.swift:23). The player lists these next to the file's embedded tracks; picking
/// one mounts the URL on the live engine (mpv `sub-add` / the ExoPlayer side-loaded text track).
object SubtitleAddonService {

    /// The installed subtitle add-ons to query, from the engine's installed set (Apple
    /// `installedSources`, SubtitleAddons.swift:37; the Android engine store is already the single
    /// authoritative addon list, so no second legacy-collection union is needed here). Filters to
    /// `subtitles`-capable add-ons the active profile has not turned off, and derives each query
    /// base from the transport URL by dropping the `/manifest.json` suffix (Apple `CoreDescriptor
    /// .baseUrl` does the same).
    fun installedSources(addons: List<InstalledAddon>): List<SubtitleAddonSource> {
        val seen = mutableSetOf<String>()
        return addons
            .filter { it.providesSubtitles && !it.isDisabled }
            .mapNotNull { addon ->
                val trimmed = addon.transportUrl.trim().trimEnd('/')
                val base = if (trimmed.endsWith(MANIFEST_LEAF, ignoreCase = true)) {
                    trimmed.dropLast(MANIFEST_LEAF.length)
                } else {
                    trimmed
                }.trimEnd('/')
                if (base.isBlank() || !seen.add(base.lowercase())) return@mapNotNull null
                SubtitleAddonSource(baseUrl = base, name = addon.name)
            }
    }

    /// The manifest leaf every transport URL ends with; dropping it yields the resource base.
    private const val MANIFEST_LEAF = "/manifest.json"

    /// The `(type, videoId)` pair the subtitles resource is queried with, from the playable's
    /// [MediaRef]: a movie queries its imdb id, a series episode queries `imdb:season:episode`
    /// (the same engine video-id shape Apple hands to `SubtitleAddonService.fetch`). Null when the
    /// ref carries no imdb identity (a pasted magnet, a tmdb-only catalog) -- the fetch is simply
    /// skipped, fail-soft.
    fun queryFor(ref: MediaRef): Pair<String, String>? {
        val imdb = ref.imdb?.takeIf { it.isNotBlank() } ?: return null
        return if (ref.isSeries) {
            val season = ref.season ?: return null
            val episode = ref.episode ?: return null
            "series" to "$imdb:$season:$episode"
        } else {
            "movie" to imdb
        }
    }

    /// All subtitles for `type/videoId` across the given subtitle add-ons, in source order,
    /// deduplicated by URL (Apple `fetch`, SubtitleAddons.swift:54: same route
    /// `{base}/subtitles/{type}/{videoId}.json`, same 15s per-source timeout, same fail-soft
    /// empty-on-error per add-on, same source-order concat + URL dedupe).
    suspend fun fetch(sources: List<SubtitleAddonSource>, type: String, videoId: String,
                      metadata: SubtitleRequestMetadata = SubtitleRequestMetadata()): List<AddonSubtitle> {
        if (sources.isEmpty()) return emptyList()
        val path = metadata.resourcePath(type, videoId)
        val legacyPath = SubtitleRequestMetadata().resourcePath(type, videoId)
        val paths = if (path == legacyPath) listOf(path) else listOf(path, legacyPath)
        val collected = coroutineScope {
            sources.map { source ->
                async(Dispatchers.IO) { fetchOne(source, paths) }
            }.awaitAll()
        }
        val seen = mutableSetOf<String>()
        return collected.flatten().filter { seen.add(it.url) }
    }

    /// One add-on's `subtitles` response, or empty on ANY failure (bad URL, network error, non-2xx,
    /// malformed JSON) -- a flaky subtitle add-on must never break the player's track list.
    private suspend fun fetchOne(source: SubtitleAddonSource, paths: List<String>): List<AddonSubtitle> =
        withContext(Dispatchers.IO) {
            runCatching {
                for ((attempt, path) in paths.withIndex()) {
                    val connection = URL("${source.baseUrl.trimEnd('/')}/$path").openConnection() as HttpURLConnection
                    try {
                        connection.requestMethod = "GET"
                        connection.connectTimeout = FETCH_TIMEOUT_MS
                        connection.readTimeout = FETCH_TIMEOUT_MS
                        connection.instanceFollowRedirects = true
                        val status = connection.responseCode
                        if (attempt == 0 && paths.size > 1 && status in listOf(404, 405)) continue
                        if (status !in 200..299) return@runCatching emptyList()
                        // Listings are tiny: enforce the cap even when Content-Length is absent or false.
                        if (connection.contentLengthLong > LISTING_RESPONSE_MAX_BYTES) return@runCatching emptyList()
                        val bytes = connection.inputStream.use { input ->
                            val out = java.io.ByteArrayOutputStream()
                            val buffer = ByteArray(16 * 1024)
                            var total = 0
                            while (true) {
                                val read = input.read(buffer)
                                if (read < 0) break
                                total += read
                                if (total > LISTING_RESPONSE_MAX_BYTES) return@runCatching emptyList()
                                out.write(buffer, 0, read)
                            }
                            out.toByteArray()
                        }
                        return@runCatching parseSubtitles(bytes.toString(Charsets.UTF_8), source.name)
                    } finally {
                        connection.disconnect()
                    }
                }
                emptyList()
            }.getOrDefault(emptyList())
        }

    /// Decode `{ "subtitles": [{ id?, url, lang? }] }` (the Stremio subtitles-resource shape) into
    /// [AddonSubtitle]s; entries with no `url` are dropped, `lang` defaults to "und" exactly as the
    /// Apple decoder does.
    private fun parseSubtitles(body: String, addonName: String): List<AddonSubtitle> {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return emptyList()
        val array = root.optJSONArray("subtitles") ?: return emptyList()
        val out = mutableListOf<AddonSubtitle>()
        for (i in 0 until array.length()) {
            val sub = array.optJSONObject(i) ?: continue
            val url = (sub.opt("url") as? String)?.takeIf { it.isNotBlank() } ?: continue
            out += AddonSubtitle(
                id = (sub.opt("id") as? String)?.takeIf { it.isNotBlank() } ?: url,
                url = url,
                lang = (sub.opt("lang") as? String)?.takeIf { it.isNotBlank() } ?: "und",
                addonName = addonName,
                releaseName = (sub.opt("subtitleFileName") as? String)?.takeIf { it.isNotBlank() },
            )
        }
        return out
    }

    /// Per-source fetch timeout, matching Apple's `req.timeoutInterval = 15`.
    private const val FETCH_TIMEOUT_MS = 15_000
    private const val LISTING_RESPONSE_MAX_BYTES = 1024 * 1024
}
