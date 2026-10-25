package com.vortx.android.ui.randompick

import com.vortx.android.home.HomeRail
import com.vortx.android.model.Catalog
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import kotlin.random.Random

internal enum class RandomLibraryFilter { ALL, MOVIES, SHOWS }

/** Selection only: callers supply the current native parental-admitted library/detail snapshot. */
internal object RandomPickPolicy {
    /** Home supplies its already published, profile-admitted rows. Selection never loads a catalog.
     * Prefer the current profile's recommendation rails; fall back to visible VOD catalogs when those
     * have no eligible titles. Continue Watching/private activity and coming-soon rails are separate.
     */
    fun homeCandidates(catalogs: List<Catalog>, now: Instant = Instant.now()): List<MetaItem> {
        val currentYear = now.atOffset(ZoneOffset.UTC).year
        val rows = catalogs.filter { catalog ->
            catalog.id != HomeRail.CONTINUE_CATALOG_ID &&
                catalog.type?.lowercase() !in setOf("tv", "channel", "events") &&
                HomeRail.forCatalog(catalog) !in setOf(HomeRail.UPCOMING_EPISODES, HomeRail.UPCOMING_MOVIES)
        }
        fun candidates(rows: List<Catalog>): List<MetaItem> = libraryCandidates(
            rows.flatMap { it.items }.filter {
                !it.watched && it.continueWatchingPermit == null &&
                    knownHomeStartYear(it.year)?.let { year -> year > currentYear } != true
            },
            RandomLibraryFilter.ALL,
        )
        val preferred = candidates(rows.filter { HomeRail.forCatalog(it) in setOf(
            HomeRail.FOR_YOU, HomeRail.SMART_COLLECTIONS, HomeRail.TOP_PICKS, HomeRail.BECAUSE_YOU_WATCHED,
        ) })
        return preferred.ifEmpty { candidates(rows) }
    }

    /** A bounded explicit year, date or range prefix is evidence; arbitrary malformed text is not. */
    private fun knownHomeStartYear(value: String?): Int? {
        val raw = value?.trim()?.takeIf { it.length in 4..64 } ?: return null
        if (!raw.take(4).all { it in '0'..'9' } ||
            (raw.length > 4 && raw[4] !in "-–— /")) return null
        return raw.take(4).toIntOrNull()
    }

    fun libraryCandidates(items: List<MetaItem>, filter: RandomLibraryFilter): List<MetaItem> =
        items.asSequence()
            .filter { item ->
                item.id.isNotBlank() && item.name.isNotBlank() &&
                    item.continueWatchingUnavailableMessage == null &&
                    when (filter) {
                        RandomLibraryFilter.ALL -> item.type == MediaType.MOVIE || item.type == MediaType.SERIES
                        RandomLibraryFilter.MOVIES -> item.type == MediaType.MOVIE
                        RandomLibraryFilter.SHOWS -> item.type == MediaType.SERIES
                    }
            }
            .distinctBy { "${it.type.id}:${it.id}" }
            .toList()

    fun episodeCandidates(detail: MetaDetail, now: Instant): List<Episode> {
        if (detail.type != MediaType.SERIES || detail.id.isBlank() || detail.name.isBlank()) return emptyList()
        // Inspect every row before eligibility filtering: an invalid/future twin cannot hide an
        // ambiguous video identity. Episode IDs are opaque; their coordinates come from metadata.
        val ambiguousIDs = detail.videos.groupBy(Episode::id).filterValues { rows ->
            val first = rows.first()
            rows.any { it.season != first.season || it.episode != first.episode }
        }.keys
        return detail.videos.asSequence()
            .filter { episode ->
                episode.id !in ambiguousIDs && episode.id.isNotBlank() && episode.title.isNotBlank() &&
                    episode.season >= 0 && episode.episode >= 0 && !episode.hasKnownFutureRelease(now)
            }
            .distinctBy(Episode::id)
            .toList()
    }

    private fun Episode.hasKnownFutureRelease(now: Instant): Boolean {
        // Detail admission remains authoritative when a provider has no usable release date.
        // Date-only VOD values are checked locally; the shared live/EPG parser is unchanged.
        val instant = releasedDate ?: released?.trim()?.let { raw ->
            runCatching { OffsetDateTime.parse(raw).toInstant() }.getOrNull()
                ?: runCatching { LocalDate.parse(raw).atStartOfDay().toInstant(ZoneOffset.UTC) }.getOrNull()
        }
        return instant?.isAfter(now) == true
    }

    fun <T> pick(
        candidates: List<T>,
        currentKey: String?,
        key: (T) -> String,
        nextInt: (Int) -> Int = Random.Default::nextInt,
    ): T? {
        val alternatives = if (currentKey == null) candidates else candidates.filter { key(it) != currentKey }
        val pool = alternatives.ifEmpty { candidates }
        return when (pool.size) {
            0 -> null
            1 -> pool.first()
            else -> pool[nextInt(pool.size)]
        }
    }
}

/** Owner must include the caller's account/profile generation and be checked again on confirmation. */
internal data class RandomPickPreview<T, O>(val item: T, val owner: O)

internal fun <T, O> RandomPickPreview<T, O>.currentOrNull(owner: O, allowed: Boolean): T? =
    if (this.owner == owner && allowed) item else null
