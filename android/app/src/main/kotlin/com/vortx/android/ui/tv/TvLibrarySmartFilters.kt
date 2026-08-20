package com.vortx.android.ui.tv

import androidx.annotation.StringRes
import com.vortx.android.R
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem

/// Client-side Library refinement for TV, the parity twin of Apple `SourcesTV/LibraryView.swift`'s
/// `LibrarySegment` (type bucket bar, including the Anime segment) + `LibrarySmartFilter` (Unwatched / In
/// Progress / Watched / Short). The engine only knows movie vs series, so anime is DERIVED per title and the
/// smart predicates run over the already-loaded [MetaItem]s -- no extra engine round-trip.

/// The type segment bar. Anime is its own bucket (mirrors Apple `LibrarySegment.bucket`): the engine has no
/// "anime" type, so an anime title is a movie/series carrying an anime catalog id (`kitsu:`/`anilist:`/
/// `mal:`/`anidb:`). Everything else buckets by media type (movie -> Movies; series/channel/tv -> Shows).
internal enum class LibrarySegment(@param:StringRes val titleResource: Int) {
    ALL(R.string.library_segment_all),
    MOVIES(R.string.library_segment_movies),
    SHOWS(R.string.library_segment_shows),
    ANIME(R.string.library_segment_anime);

    companion object {
        /// The id prefixes an anime catalog uses (mirrors Apple `LibrarySegment.bucket`'s prefix set).
        private val ANIME_ID_PREFIXES = listOf("kitsu:", "anilist:", "mal:", "anidb:")

        /// The non-ALL buckets in display order.
        private val ORDERED = listOf(MOVIES, SHOWS, ANIME)

        /// Bucket one title. Anime wins over the media type (an anime series is Anime, not Shows).
        fun bucket(item: MetaItem): LibrarySegment {
            val id = item.id.lowercase()
            if (ANIME_ID_PREFIXES.any(id::startsWith)) return ANIME
            return if (item.type == MediaType.MOVIE) MOVIES else SHOWS
        }

        /// The segment bar to render: `[ALL] + present buckets`, but ONLY when at least two distinct buckets
        /// are present (mirrors Apple `availableSegments`: a single-bucket library shows no bar). Empty means
        /// "no segment bar".
        fun availableSegments(items: List<MetaItem>): List<LibrarySegment> {
            val present = ORDERED.filter { segment -> items.any { bucket(it) == segment } }
            return if (present.size >= 2) listOf(ALL) + present else emptyList()
        }
    }

    /// Keep only the titles in this segment. [ALL] keeps everything.
    fun filter(items: List<MetaItem>): List<MetaItem> =
        if (this == ALL) items else items.filter { bucket(it) == this }
}

/// One smart filter (mirrors Apple `LibrarySmartFilter`), AND-combined and multi-select. Only "applicable"
/// filters render (a filter that matches none or all of the current titles is a dead control) -- see
/// [applicable]. Watched and Unwatched are mutually exclusive in the UI.
internal enum class LibrarySmartFilter(@param:StringRes val titleResource: Int) {
    UNWATCHED(R.string.library_filter_unwatched),
    IN_PROGRESS(R.string.library_filter_in_progress),
    WATCHED(R.string.library_filter_watched),
    SHORT(R.string.library_filter_short);

    /// The predicate for one title, byte-for-byte with Apple `LibrarySmartFilter.matches`.
    fun matches(item: MetaItem): Boolean = when (this) {
        UNWATCHED -> !item.watched
        IN_PROGRESS -> item.progress?.let { it > 0f && it < IN_PROGRESS_CEIL } ?: false
        WATCHED -> item.watched
        // Apple: durationMs > 0 && < 100 min; the Android preview carries whole minutes, unknown = null,
        // which (like Apple's duration 0) never matches.
        SHORT -> item.previewRuntimeMinutes?.let { it in 1 until SHORT_RUNTIME_MINUTES } ?: false
    }

    companion object {
        /// Progress ceiling for "In Progress" (mirrors Apple `inProgressCeil = 0.9`).
        private const val IN_PROGRESS_CEIL = 0.9f

        /// "Short" runtime ceiling in minutes (mirrors Apple `shortRuntimeMs = 100 * 60 * 1000`).
        private const val SHORT_RUNTIME_MINUTES = 100

        /// The filters worth showing: each partitions the current [items] (matches at least one AND not all),
        /// so no dead control appears (mirrors Apple `applicableFilters`). Preserves enum order.
        fun applicable(items: List<MetaItem>): List<LibrarySmartFilter> {
            if (items.isEmpty()) return emptyList()
            val total = items.size
            return entries.filter { filter ->
                val matched = items.count(filter::matches)
                matched in 1 until total
            }
        }

        /// Apply the selected filters (AND-combined). Empty selection keeps everything.
        fun apply(items: List<MetaItem>, selected: Set<LibrarySmartFilter>): List<MetaItem> =
            if (selected.isEmpty()) items else items.filter { item -> selected.all { it.matches(item) } }

        /// Toggle [filter] in [selected], keeping Watched and Unwatched mutually exclusive (mirrors Apple
        /// `LibrarySmartFilter.toggle`).
        fun toggle(selected: Set<LibrarySmartFilter>, filter: LibrarySmartFilter): Set<LibrarySmartFilter> {
            if (filter in selected) return selected - filter
            val opposite = when (filter) {
                WATCHED -> UNWATCHED
                UNWATCHED -> WATCHED
                else -> null
            }
            return (selected - setOfNotNull(opposite)) + filter
        }
    }
}
