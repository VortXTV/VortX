package com.vortx.android.ui.randompick

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
