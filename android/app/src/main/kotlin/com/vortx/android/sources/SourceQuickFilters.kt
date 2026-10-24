package com.vortx.android.sources

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import java.util.Locale

/** Local list presentation, never a source/ranking preference or a playback capability. */
internal enum class SourceCacheFacet(val label: String) {
    ALL("All"), CONFIRMED("Confirmed cached"), UNKNOWN("Unknown"),
}

internal enum class SourceRangeFacet(val label: String) {
    DOLBY_VISION("Dolby Vision"), HDR10_PLUS("HDR10+"), HDR10("HDR10"), HLG("HLG"),
    HDR("HDR"), SDR("SDR"), UNKNOWN("Unknown"),
}

internal enum class SourceCodecFacet(val label: String) {
    HEVC("HEVC / H.265"), AVC("AVC / H.264"), AV1("AV1"), VP9("VP9"),
    MPEG2("MPEG-2"), UNKNOWN("Unknown"),
}

internal data class SourceQuickFilters(
    val cache: SourceCacheFacet = SourceCacheFacet.ALL,
    val range: SourceRangeFacet? = null,
    val codec: SourceCodecFacet? = null,
) {
    val active: Boolean get() = cache != SourceCacheFacet.ALL || range != null || codec != null

    internal fun acceptsCache(confirmedCached: Boolean): Boolean =
        (cache == SourceCacheFacet.ALL ||
            (cache == SourceCacheFacet.CONFIRMED && confirmedCached) ||
            (cache == SourceCacheFacet.UNKNOWN && !confirmedCached))

    internal fun accepts(facts: SourceQuickFilterFacts, confirmedCached: Boolean): Boolean =
        acceptsCache(confirmedCached) &&
            (range == null || range in facts.ranges) &&
            (codec == null || codec in facts.codecs)
}

internal data class SourceQuickFilterFacts(
    val confirmedCached: Boolean,
    val ranges: Set<SourceRangeFacet>,
    val codecs: Set<SourceCodecFacet>,
)

/**
 * Parse once per immutable list snapshot, not for every row/recomposition. Entries carry the ACTUAL source
 * value, not a map keyed by provider-controlled id: duplicate IDs with different handles/metadata remain
 * distinct. Group slots/order (including newly empty groups) stay intact so TV's existing base/index
 * focus and collapse identities do not shift. No rank, deduplication, preference, fetch or play occurs.
 */
internal class SourceQuickFilterIndex(private val groups: List<StreamGroup>) {
    private val entries by lazy {
        groups.map { group -> group.streams.map { source -> source to sourceQuickFilterFacts(source) } }
    }

    fun matchingGroups(filters: SourceQuickFilters, currentCacheRevision: Long = -1L): List<StreamGroup> {
        if (!filters.active) return groups
        return groups.mapIndexed { index, group ->
            // All and cache-only never parse provider metadata. Format facts are lazy/cached per snapshot.
            val sources = if (filters.range == null && filters.codec == null) {
                group.streams.filter { filters.acceptsCache(sourceConfirmedCacheIsCurrent(it, currentCacheRevision)) }
            } else {
                entries[index].mapNotNull { (source, facts) ->
                    source.takeIf { filters.accepts(facts, sourceConfirmedCacheIsCurrent(source, currentCacheRevision)) }
                }
            }
            if (sources.size == group.streams.size) group else group.copy(streams = sources)
        }
    }
}

/** Actual cache-check observations only; Unknown means NOT CONFIRMED, not known-uncached. */
internal fun markAccountConfirmedCache(
    groups: List<StreamGroup>,
    hashes: Set<String>,
    credentialEventRevision: Long,
): List<StreamGroup> {
    var changed = false
    val confirmed = groups.map { group ->
        var groupChanged = false
        val sources = group.streams.map { source ->
            val hash = source.infoHash?.trim()?.lowercase(Locale.ROOT)
            val proof = credentialEventRevision.takeIf {
                it >= 0 && !source.isUsenet && !source.isMediaServer && !source.isYouTubeTrailer &&
                    !hash.isNullOrEmpty() && hash in hashes
            }
            if (source.accountConfirmedCacheRevision != proof) {
                changed = true
                groupChanged = true
                source.copy(accountConfirmedCacheRevision = proof)
            } else source
        }
        if (groupChanged) group.copy(streams = sources) else group
    }
    return if (changed) confirmed else groups
}

/** These are provider-REPORTED facets. Neither a filename nor a tag verifies decoded/output media. */
internal fun sourceQuickFilterFacts(source: StreamSource, currentCacheRevision: Long = -1L): SourceQuickFilterFacts {
    val text = sourceFacetText(source)
    val ranges = linkedSetOf<SourceRangeFacet>()
    if (reported(text, "dolby[ ._-]?vision|dovi|dv(?:hdr)?|bl[+]?rpu")) ranges += SourceRangeFacet.DOLBY_VISION
    if (reported(text, "hdr[ ._-]?10(?:[+]|plus)")) ranges += SourceRangeFacet.HDR10_PLUS
    if (reported(text, "hdr[ ._-]?10(?![+]|plus)")) ranges += SourceRangeFacet.HDR10
    if (reported(text, "hlg")) ranges += SourceRangeFacet.HLG
    if (reported(text, "hdr(?![ ._-]?10)")) ranges += SourceRangeFacet.HDR
    if (reported(text, "sdr")) ranges += SourceRangeFacet.SDR
    if (ranges.isEmpty()) ranges += SourceRangeFacet.UNKNOWN

    val codecs = linkedSetOf<SourceCodecFacet>()
    if (reported(text, "hevc|[xh][ ._-]?265")) codecs += SourceCodecFacet.HEVC
    if (reported(text, "avc|[xh][ ._-]?264")) codecs += SourceCodecFacet.AVC
    if (reported(text, "av[ ._-]?1")) codecs += SourceCodecFacet.AV1
    if (reported(text, "vp[ ._-]?9")) codecs += SourceCodecFacet.VP9
    if (reported(text, "mpeg[ ._-]?2")) codecs += SourceCodecFacet.MPEG2
    if (codecs.isEmpty()) codecs += SourceCodecFacet.UNKNOWN
    return SourceQuickFilterFacts(sourceConfirmedCacheIsCurrent(source, currentCacheRevision), ranges, codecs)
}

private fun sourceConfirmedCacheIsCurrent(source: StreamSource, currentRevision: Long): Boolean =
    currentRevision >= 0 && source.accountConfirmedCacheRevision == currentRevision &&
        !source.isUsenet && !source.isMediaServer && !source.isYouTubeTrailer && !source.infoHash.isNullOrBlank()

// Fixed bounded input and precompiled, simple token patterns; no URL/header/credential or id parsing.
private fun sourceFacetText(source: StreamSource): String {
    val text = buildString {
        for (field in listOf(source.title, source.description, source.quality, source.filename)) {
            if (length >= SOURCE_FACET_TEXT_LIMIT) break
            if (field != null) {
                append(field.take((SOURCE_FACET_TEXT_LIMIT - length - 1).coerceAtLeast(0)))
                append(' ')
            }
        }
    }.lowercase(Locale.ROOT).replace("\uFE0F", "")
    var cleaned = text
    repeat(4) { cleaned = SOURCE_FACET_TEMPLATE.replace(cleaned, " ") }
    return cleaned
}

private val SOURCE_FACET_TOKENS = listOf(
    "dolby[ ._-]?vision|dovi|dv(?:hdr)?|bl[+]?rpu", "hdr[ ._-]?10(?:[+]|plus)",
    "hdr[ ._-]?10(?![+]|plus)", "hlg", "hdr(?![ ._-]?10)", "sdr", "hevc|[xh][ ._-]?265",
    "avc|[xh][ ._-]?264", "av[ ._-]?1", "vp[ ._-]?9", "mpeg[ ._-]?2",
).associateWith { Regex("(?<![a-z0-9])(?:$it)(?![a-z0-9])") }
private val SOURCE_FACET_NEGATION = Regex("(?:^|[^a-z0-9])(?:no|not|without|non)[ ._-]*$")
private val SOURCE_FACET_TEMPLATE = Regex("\\{[^{}]*}")
private const val SOURCE_FACET_TEXT_LIMIT = 16_384

private fun reported(text: String, pattern: String): Boolean =
    requireNotNull(SOURCE_FACET_TOKENS[pattern]).findAll(text).any { match ->
        !SOURCE_FACET_NEGATION.containsMatchIn(text.substring((match.range.first - 24).coerceAtLeast(0), match.range.first))
    }
