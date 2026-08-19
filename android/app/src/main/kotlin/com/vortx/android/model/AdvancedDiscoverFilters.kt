package com.vortx.android.model

import java.util.Locale

enum class GenreFilterState { OFF, INCLUDE, EXCLUDE }

/** Persisted client-side Discover filters. The engine-owned pivot remains [DiscoverFilters]. */
data class AdvancedDiscoverFilters(
    val includedGenres: Set<String> = emptySet(),
    val excludedGenres: Set<String> = emptySet(),
    val minYear: Int? = null,
    val maxYear: Int? = null,
    val ageRatings: Set<String> = emptySet(),
    val minMinutes: Int? = null,
    val maxMinutes: Int? = null,
    val minSeasons: Int? = null,
    val maxSeasons: Int? = null,
    val upcomingOnly: Boolean = false,
) {
    val activeCount: Int
        get() = listOf(
            includedGenres.isNotEmpty(),
            excludedGenres.isNotEmpty(),
            minYear != null || maxYear != null,
            ageRatings.isNotEmpty(),
            minMinutes != null || maxMinutes != null,
            minSeasons != null || maxSeasons != null,
            upcomingOnly,
        ).count { it }

    val isActive: Boolean get() = activeCount > 0

    fun genreState(genre: String): GenreFilterState = when {
        genre in includedGenres -> GenreFilterState.INCLUDE
        genre in excludedGenres -> GenreFilterState.EXCLUDE
        else -> GenreFilterState.OFF
    }

    fun cycleGenre(genre: String): AdvancedDiscoverFilters = when (genreState(genre)) {
        GenreFilterState.OFF -> copy(includedGenres = includedGenres + genre)
        GenreFilterState.INCLUDE -> copy(
            includedGenres = includedGenres - genre,
            excludedGenres = excludedGenres + genre,
        )
        GenreFilterState.EXCLUDE -> copy(excludedGenres = excludedGenres - genre)
    }

    /**
     * Matches Apple's field-present rule: an active filter narrows only previews carrying that field.
     * Sparse add-on previews remain visible rather than being rejected for metadata they never supplied.
     */
    fun matches(item: MetaItem, currentYear: Int): Boolean {
        val itemGenres = item.genres.map { it.lowercase(Locale.ROOT) }
        if (itemGenres.isNotEmpty()) {
            if (includedGenres.isNotEmpty()) {
                val included = includedGenres.mapTo(hashSetOf()) { it.lowercase(Locale.ROOT) }
                if (itemGenres.none(included::contains)) return false
            }
            if (excludedGenres.isNotEmpty()) {
                val excluded = excludedGenres.mapTo(hashSetOf()) { it.lowercase(Locale.ROOT) }
                if (itemGenres.any(excluded::contains)) return false
            }
        }

        item.releaseYear?.let { year ->
            if (minYear?.let { year < it } == true) return false
            if (maxYear?.let { year > it } == true) return false
            if (upcomingOnly && year < currentYear) return false
        }

        item.certificationLabel?.let { certification ->
            if (ageRatings.isNotEmpty() && ageRatings.none { it.equals(certification, ignoreCase = true) }) {
                return false
            }
        }
        item.previewRuntimeMinutes?.let { minutes ->
            if (minMinutes?.let { minutes < it } == true) return false
            if (maxMinutes?.let { minutes > it } == true) return false
        }
        item.previewSeasonCount?.let { seasons ->
            if (minSeasons?.let { seasons < it } == true) return false
            if (maxSeasons?.let { seasons > it } == true) return false
        }
        return true
    }

    companion object {
        val EMPTY = AdvancedDiscoverFilters()
    }
}

val MetaItem.releaseYear: Int?
    get() = year?.let { raw ->
        Regex("\\d{4}").find(raw)?.value?.toIntOrNull()?.takeIf { it in 1801..2199 }
    }

object AdvancedDiscoverFilterOptions {
    val ageRatings = listOf("G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-G", "TV-PG", "TV-14", "TV-MA")

    data class Decade(val label: String, val start: Int, val end: Int)
    val decades = listOf(
        Decade("2020s", 2020, 2029),
        Decade("2010s", 2010, 2019),
        Decade("2000s", 2000, 2009),
        Decade("1990s", 1990, 1999),
        Decade("1980s", 1980, 1989),
        Decade("1970s", 1970, 1979),
        Decade("Older", 1900, 1969),
    )

    data class Bucket(val label: String, val min: Int?, val max: Int?)
    val durationBuckets = listOf(
        Bucket("Under 30m", null, 29),
        Bucket("30-60m", 30, 60),
        Bucket("60-90m", 60, 90),
        Bucket("90-120m", 90, 120),
        Bucket("Over 2h", 121, null),
    )
    val seasonBuckets = listOf(
        Bucket("1 season", 1, 1),
        Bucket("2-3", 2, 3),
        Bucket("4-6", 4, 6),
        Bucket("7+", 7, null),
    )
    val animeGenres = listOf(
        "Shounen", "Shoujo", "Seinen", "Josei", "Isekai", "Mecha",
        "Slice of Life", "Iyashikei", "Ecchi", "Sports", "Supernatural", "Psychological",
    )
}

fun AdvancedDiscoverFilters.selectedDecadeStarts(): Set<Int> {
    val low = minYear ?: return emptySet()
    val high = maxYear ?: return emptySet()
    return AdvancedDiscoverFilterOptions.decades
        .filter { it.start >= low && it.end <= high }
        .mapTo(linkedSetOf()) { it.start }
}

fun AdvancedDiscoverFilters.toggleDecade(
    decade: AdvancedDiscoverFilterOptions.Decade,
): AdvancedDiscoverFilters {
    val selected = selectedDecadeStarts().toMutableSet().apply {
        if (!add(decade.start)) remove(decade.start)
    }
    val chosen = AdvancedDiscoverFilterOptions.decades.filter { it.start in selected }
    return copy(minYear = chosen.minOfOrNull { it.start }, maxYear = chosen.maxOfOrNull { it.end })
}

fun advancedDiscoverGenreOptions(result: DiscoverResult): List<String> {
    val seen = hashSetOf<String>()
    val output = mutableListOf<String>()
    fun add(raw: String) {
        val value = raw.trim()
        if (value.isNotEmpty() && seen.add(value.lowercase(Locale.ROOT))) output += value
    }
    result.filters.genres.forEach { add(it.label) }
    result.items.forEach { item -> item.genres.forEach(::add) }
    if (isAdvancedDiscoverAnimeContext(result)) AdvancedDiscoverFilterOptions.animeGenres.forEach(::add)
    return output
}

fun isAdvancedDiscoverAnimeContext(result: DiscoverResult): Boolean {
    if (result.filters.types.firstOrNull { it.selected }?.label.equals("anime", ignoreCase = true)) return true
    val animePrefixes = listOf("kitsu:", "anilist:", "mal:", "anidb:")
    if (result.items.take(16).any { item -> animePrefixes.any { item.id.lowercase(Locale.ROOT).startsWith(it) } }) return true
    return result.items.take(24).any { item -> item.genres.any { it.equals("anime", ignoreCase = true) } }
}

fun isAdvancedDiscoverSeriesContext(result: DiscoverResult): Boolean =
    result.filters.types.firstOrNull { it.selected }?.label?.lowercase(Locale.ROOT) in setOf("series", "anime")
