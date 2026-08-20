package com.vortx.android.stats

import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import kotlin.math.max
import kotlin.math.min

/**
 * The PURE, dependency-free core of Watch Stats: the normalized watch record, the computed stats, and
 * the deterministic aggregation that turns records into the numbers the screen renders. The Android
 * port of Apple `app/SourcesShared/WatchStatsAggregation.swift`.
 *
 * Nothing here touches the engine, the profile store, the file system, `org.json`, or any observable
 * state, so it is trivially unit-testable in isolation (see `test/.../stats/WatchStatsAggregationTest`).
 * [WatchStatsModel] owns the engine-coupled orchestration (which buckets / overlay / live models to
 * read) and funnels the decoded values through these pure helpers. Kept `java.time`-only ON PURPOSE:
 * it carries its OWN tolerant ISO-8601 parse rather than reusing an app formatter, so the aggregation
 * compiles and runs with no app types in scope.
 */

// MARK: - Value types

/** One title's normalized, read-only watch record. Pure value type. */
data class WatchRecord(
    val id: String,
    /** "movie" | "series". */
    val type: String,
    val name: String,
    val poster: String?,
    /**
     * Total time spent watching this title, in seconds (engine `overallTimeWatched` for the owner, an
     * estimate for overlay / live-only titles).
     */
    val watchSeconds: Double,
    /** Finished plays for a movie, or watched-episode count for a series. */
    val plays: Int,
    /** The last time this title was watched, for year-in-review scoping (null when unknown). */
    val lastWatched: Instant?,
) {
    val isSeries: Boolean get() = type == "series"
    val isMovie: Boolean get() = type == "movie"
}

/** One genre's share of watch time within the current scope. */
data class GenreStat(val name: String, val seconds: Double)

/** The single title the user sank the most into (the "longest binge"). */
data class BingeStat(val name: String, val type: String, val seconds: Double, val episodes: Int)

/** One row of the "most watched" list. */
data class TitleStat(
    val id: String,
    val name: String,
    val type: String,
    val poster: String?,
    val seconds: Double,
    val plays: Int,
)

/** The fully computed stats for one scope (all time, or one year). Pure output; the view only formats it. */
data class WatchStats(
    val scopeLabel: String,
    val totalWatchSeconds: Double,
    val titlesCount: Int,
    val moviesCount: Int,
    val seriesCount: Int,
    val episodesCount: Int,
    val topGenres: List<GenreStat>,
    /** How many scoped titles had a locally known genre (so the view can caption the genre card honestly). */
    val genreCoverage: Int,
    val longestBinge: BingeStat?,
    val topTitles: List<TitleStat>,
) {
    /** True when there is anything at all to show. */
    val hasData: Boolean get() = titlesCount > 0

    companion object {
        /** How many titles to surface in the "most watched" list and the internal work caps. */
        const val TOP_TITLES_LIMIT = 8
        const val TOP_GENRES_LIMIT = 6

        /**
         * Corruption ceiling for a single title and the displayed all-series total. One million watched
         * episodes is already far beyond a human lifetime, while keeping the value small enough that every
         * aggregate remains mechanically non-trapping even when a producer hands us Int.MAX_VALUE.
         */
        const val MAXIMUM_PLAY_COUNT = 1_000_000

        /**
         * The VOD content types this screen counts. Live TV / channels and the internal "other" docs are
         * excluded (they are not "titles watched").
         */
        fun isVODType(type: String): Boolean = type == "movie" || type == "series"

        /** The app's own internal library docs (e.g. the `stremiox:profiles` sync doc) must never count. */
        fun isInternalID(id: String): Boolean = id.startsWith("stremiox:") || id.startsWith("vortx:")

        /**
         * Corruption guard: keep a finite, non-negative value and cap it at an absurdly high ceiling so a
         * single bad accumulator can never dominate the total. Real values sit far below this.
         */
        fun clampSeconds(seconds: Double): Double {
            if (!seconds.isFinite() || seconds <= 0.0) return 0.0
            return min(seconds, 500_000.0 * 3600.0)
        }

        fun clampPlayCount(value: Int): Int = min(max(value, 0), MAXIMUM_PLAY_COUNT)

        /** The UTC year of an instant (year-in-review buckets by UTC so a title's year is stable device-to-device). */
        fun yearOf(instant: Instant): Int = instant.atZone(ZoneOffset.UTC).year

        /**
         * Tolerant ISO-8601 parse for a stored `lastWatched`. The engine writes up to nanosecond fractional
         * seconds (e.g. "2026-05-13T05:50:02.786798226Z"), so try the offset-date-time and instant forms
         * first (both accept up to nanoseconds) and finally fall back to the leading calendar day. Only the
         * year is load-bearing (year-in-review scoping), so pinning a UTC day when the full timestamp is
         * over-precise is enough; null when absent / unparseable.
         */
        fun parseISODate(raw: String?): Instant? {
            if (raw.isNullOrEmpty()) return null
            runCatching { OffsetDateTime.parse(raw).toInstant() }.getOrNull()?.let { return it }
            runCatching { Instant.parse(raw) }.getOrNull()?.let { return it }
            if (raw.length >= 10) {
                runCatching {
                    LocalDate.parse(raw.substring(0, 10)).atStartOfDay(ZoneOffset.UTC).toInstant()
                }.getOrNull()?.let { return it }
            }
            return null
        }

        /**
         * Compute the stats over already-scoped records. Pure and deterministic (no I/O), so it is trivially
         * testable and cheap enough to run on every scope change.
         */
        fun compute(
            records: List<WatchRecord>,
            genresByID: Map<String, List<String>>,
            scopeLabel: String,
            topTitles: Int,
            topGenres: Int,
        ): WatchStats {
            // Every producer normally supplies small, non-negative play counts, but this pure boundary is
            // also fed by persisted JSON and overlay models. Normalize here so a hostile or corrupt
            // Int.MAX_VALUE cannot escape through another constructor, dominate ranking, or trap the
            // aggregate with overflowing `+`.
            val safeRecords = records.map { it.copy(plays = clampPlayCount(it.plays)) }
            val movies = safeRecords.filter { it.isMovie }
            val series = safeRecords.filter { it.isSeries }
            val totalSeconds = safeRecords.sumOf { it.watchSeconds }
            val episodes = series.fold(0) { acc, r -> boundedPlayTotal(acc, r.plays) }

            // Top genres, weighted by watch time so a genre the user spent more hours on ranks higher.
            val genreSeconds = HashMap<String, Double>()
            var covered = 0
            for (record in safeRecords) {
                val genres = genresByID[record.id]
                if (genres.isNullOrEmpty()) continue
                covered += 1
                // Split the title's time evenly across its genres so a 3-genre title does not triple-count.
                val share = record.watchSeconds / genres.size.toDouble()
                for (genre in genres) genreSeconds[genre] = (genreSeconds[genre] ?: 0.0) + share
            }
            val genres = genreSeconds
                .map { GenreStat(name = it.key, seconds = it.value) }
                .filter { it.seconds > 0.0 }
                .sortedByDescending { it.seconds }
                .take(topGenres)

            // Longest binge: the series with the most watched episodes (tiebreak on time). With no series,
            // the movie with the most watch time stands in.
            val topSeries = series.maxWithOrNull(compareBy({ it.plays }, { it.watchSeconds }))
            val topMovie = movies.maxByOrNull { it.watchSeconds }
            val binge: BingeStat? = when {
                topSeries != null && topSeries.plays > 0 ->
                    BingeStat(topSeries.name, topSeries.type, topSeries.watchSeconds, topSeries.plays)
                topMovie != null && topMovie.watchSeconds > 0.0 ->
                    BingeStat(topMovie.name, topMovie.type, topMovie.watchSeconds, 0)
                else -> null
            }

            // Most watched, ranked by time spent (tiebreak on play count).
            val ranked = safeRecords
                .filter { it.watchSeconds > 0.0 || it.plays > 0 }
                .sortedWith(compareByDescending<WatchRecord> { it.watchSeconds }.thenByDescending { it.plays.toDouble() })
                .take(topTitles)
                .map { TitleStat(it.id, it.name, it.type, it.poster, it.watchSeconds, it.plays) }

            return WatchStats(
                scopeLabel = scopeLabel,
                totalWatchSeconds = totalSeconds,
                titlesCount = safeRecords.size,
                moviesCount = movies.size,
                seriesCount = series.size,
                episodesCount = episodes,
                topGenres = genres,
                genreCoverage = covered,
                longestBinge = binge,
                topTitles = ranked,
            )
        }

        /** Saturating add for the all-series episode total, capped at [MAXIMUM_PLAY_COUNT]. */
        private fun boundedPlayTotal(current: Int, next: Int): Int {
            val remaining = MAXIMUM_PLAY_COUNT - min(max(current, 0), MAXIMUM_PLAY_COUNT)
            return MAXIMUM_PLAY_COUNT - max(remaining - clampPlayCount(next), 0)
        }
    }
}
