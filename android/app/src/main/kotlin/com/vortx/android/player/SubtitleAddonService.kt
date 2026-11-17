package com.vortx.android.player

import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.MediaRef
import com.vortx.android.model.SubtitleRequestMetadata
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import org.json.JSONObject
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/// One external subtitle offered by a subtitles add-on (e.g. an OpenSubtitles add-on). Mirrors Apple
/// `AddonSubtitle` (SubtitleAddons.swift:4).
data class AddonSubtitle(
    val id: String,
    val url: String,
    val lang: String,
    val addonName: String,
    val releaseName: String? = null,
    /** Exact installed manifest transport URL; only this origin may authorize private DNS. */
    val originalInstalledBase: String? = null,
    /** Actual final subtitle-index URL; resolution base only, never private-address authority. */
    val actualFinalIndexUri: String? = null,
) {
    val displayTitle: String get() = releaseName?.takeIf { it.isNotBlank() }
        ?.let { "$addonName · $it" } ?: addonName
}

/// A minimal installed subtitle add-on to query: the base URL and a display name. Mirrors Apple
/// `SubtitleAddonSource` (SubtitleAddons.swift:15).
data class SubtitleAddonSource(
    val baseUrl: String,
    val name: String,
    /** Keep the exact installed transport URL distinct from the derived resource base. */
    val originalInstalledBase: String = baseUrl,
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
                val original = addon.transportUrl.trim()
                val trimmed = original.trimEnd('/')
                val base = if (trimmed.endsWith(MANIFEST_LEAF, ignoreCase = true)) {
                    trimmed.dropLast(MANIFEST_LEAF.length)
                } else {
                    trimmed
                }.trimEnd('/')
                if (base.isBlank() || !seen.add(base.lowercase())) return@mapNotNull null
                SubtitleAddonSource(baseUrl = base, name = addon.name, originalInstalledBase = original)
            }
    }

    /// The manifest leaf every transport URL ends with; dropping it yields the resource base.
    private const val MANIFEST_LEAF = "/manifest.json"

    /// The `(type, videoId)` pair the subtitles resource is queried with, from the playable's
    /// [MediaRef]: a movie queries its imdb id, a series episode queries `imdb:season:episode`.
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
    /// deduplicated by resolved canonical URL.
    suspend fun fetch(sources: List<SubtitleAddonSource>, type: String, videoId: String,
                      metadata: SubtitleRequestMetadata = SubtitleRequestMetadata()): List<AddonSubtitle> {
        return subtitles(fetchSources(sources, resourcePaths(type, videoId, metadata)))
    }

    // Publish the first batch immediately. A subtitle-sheet open may spend one retry on
    // unresolved providers while preserving ready rows and authoritative empty responses.
    internal suspend fun discoverForPlayback(
        sources: List<SubtitleAddonSource>,
        type: String,
        videoId: String,
        metadata: SubtitleRequestMetadata,
        publish: (List<AddonSubtitle>) -> Boolean,
        awaitRetry: suspend () -> Boolean,
    ) {
        val paths = resourcePaths(type, videoId, metadata)
        val first = fetchSources(sources, paths)
        if (!publish(subtitles(first))) return
        val retryIndices = first.indices.filter { first[it] == SourceOutcome.Retryable }
        if (retryIndices.isEmpty() || !awaitRetry()) return
        val retried = fetchSources(retryIndices.map { sources[it] }, paths)
        val merged = first.toMutableList()
        retryIndices.forEachIndexed { offset, index -> merged[index] = retried[offset] }
        publish(subtitles(merged))
    }

    private sealed interface SourceOutcome {
        data class Completed(val subtitles: List<AddonSubtitle>) : SourceOutcome
        data object Retryable : SourceOutcome
        data object Rejected : SourceOutcome
    }

    private fun resourcePaths(type: String, videoId: String, metadata: SubtitleRequestMetadata): List<String> {
        val path = metadata.resourcePath(type, videoId)
        val legacyPath = SubtitleRequestMetadata().resourcePath(type, videoId)
        return if (path == legacyPath) listOf(path) else listOf(path, legacyPath)
    }

    private suspend fun fetchSources(sources: List<SubtitleAddonSource>, paths: List<String>): List<SourceOutcome> =
        coroutineScope {
            sources.map { source -> async(Dispatchers.IO) { fetchOne(source, paths) } }.awaitAll()
        }

    private fun subtitles(outcomes: List<SourceOutcome>): List<AddonSubtitle> {
        val seen = mutableSetOf<String>()
        return outcomes.filterIsInstance<SourceOutcome.Completed>()
            .flatMap { it.subtitles }.filter { seen.add(it.url) }
    }

    private suspend fun fetchOne(source: SubtitleAddonSource, paths: List<String>): SourceOutcome {
        try {
            val deadline = AddonSubtitleIndexTransport.deadlineAfterTimeout()
            for ((attempt, path) in paths.withIndex()) {
                val endpoint = "${source.baseUrl.trimEnd('/')}/$path"
                val response = AddonSubtitleIndexTransport.get(endpoint, source.originalInstalledBase, deadline)
                    ?: return SourceOutcome.Retryable
                val status = response.status
                if (attempt == 0 && paths.size > 1 && (status == 404 || status == 405)) continue
                if (status == 408 || status == 429 || status in 500..599) return SourceOutcome.Retryable
                if (status !in 200..299) return SourceOutcome.Rejected
                val body = response.body ?: return SourceOutcome.Retryable
                val rows = parseSubtitles(
                    body.toString(Charsets.UTF_8), source.name, source.originalInstalledBase, response.finalIndexUri,
                ) ?: return SourceOutcome.Retryable
                return SourceOutcome.Completed(rows)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return SourceOutcome.Retryable
        }
        return SourceOutcome.Rejected
    }

    /// Decode Stremio subtitle rows, resolving references against the actual final index URL.
    /// Each canonical URL and the aggregate UTF-8 URL text are bounded to prevent oversized rows or
    /// relative-prefix amplification; when the aggregate budget is exhausted, stop in source order.
    private fun parseSubtitles(
        body: String,
        addonName: String,
        originalInstalledBase: String,
        actualFinalIndexUri: String,
    ): List<AddonSubtitle>? {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return null
        val array = root.optJSONArray("subtitles") ?: return null
        val index = actualFinalIndexUri.toHttpUrlOrNull() ?: return null
        val out = mutableListOf<AddonSubtitle>()
        val seen = mutableSetOf<String>()
        var retainedUrlBytes = 0
        for (i in 0 until array.length()) {
            val sub = array.optJSONObject(i) ?: continue
            val rawUrl = (sub.opt("url") as? String)?.takeIf { it.isNotBlank() } ?: continue
            if (rawUrl.toByteArray(Charsets.UTF_8).size > MAX_URL_TEXT_BYTES) continue
            val canonicalUrl = resolveAddonSubtitleUrl(index, rawUrl) ?: continue
            if (!seen.add(canonicalUrl)) continue
            val bytes = canonicalUrl.toByteArray(Charsets.UTF_8).size
            if (bytes > MAX_URL_TEXT_BYTES || retainedUrlBytes + bytes > MAX_RETAINED_URL_BYTES) break
            retainedUrlBytes += bytes
            out += AddonSubtitle(
                id = (sub.opt("id") as? String)?.takeIf { it.isNotBlank() } ?: canonicalUrl,
                url = canonicalUrl,
                lang = (sub.opt("lang") as? String)?.takeIf { it.isNotBlank() } ?: "und",
                addonName = addonName,
                releaseName = (sub.opt("subtitleFileName") as? String)?.takeIf { it.isNotBlank() },
                originalInstalledBase = originalInstalledBase,
                actualFinalIndexUri = actualFinalIndexUri,
            )
        }
        return out
    }

}

/** Resolve one bounded resource reference against the actual index URI without broadening the origin policy. */
internal fun resolveAddonSubtitleUrl(indexUri: okhttp3.HttpUrl, raw: String): String? {
    if (raw.toByteArray(Charsets.UTF_8).size > MAX_URL_TEXT_BYTES || raw.any { it.code < 0x20 || it.code == 0x7f }) return null
    val resolved = indexUri.resolve(raw) ?: return null
    if (resolved.scheme != "http" && resolved.scheme != "https") return null
    if (resolved.username.isNotEmpty() || resolved.password.isNotEmpty()) return null
    val canonical = resolved.newBuilder().fragment(null).build().toString()
    return canonical.takeIf { it.toByteArray(Charsets.UTF_8).size <= MAX_URL_TEXT_BYTES }
}

private const val MAX_URL_TEXT_BYTES = 128 * 1024
private const val MAX_RETAINED_URL_BYTES = 1024 * 1024
