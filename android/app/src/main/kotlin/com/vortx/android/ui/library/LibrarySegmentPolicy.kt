package com.vortx.android.ui.library

import androidx.annotation.StringRes
import com.vortx.android.R
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem

/// Pure client-side Library segmentation and smart filtering, shared by phone and TV.
/// The loaded library payload has no genre field, so refinements use only its existing item metadata.
internal enum class LibrarySegment(@param:StringRes val titleResource: Int) {
    ALL(R.string.library_segment_all),
    MOVIES(R.string.library_segment_movies),
    SHOWS(R.string.library_segment_shows),
    ANIME(R.string.library_segment_anime);

    companion object {
        private val ANIME_ID_PREFIXES = listOf("kitsu:", "anilist:", "mal:", "anidb:")
        private val ORDERED = listOf(MOVIES, SHOWS, ANIME)

        fun bucket(item: MetaItem): LibrarySegment {
            val id = item.id.lowercase()
            if (ANIME_ID_PREFIXES.any(id::startsWith)) return ANIME
            return if (item.type == MediaType.MOVIE) MOVIES else SHOWS
        }

        /// Show the segment control only when it can divide the loaded library.
        fun availableSegments(items: List<MetaItem>): List<LibrarySegment> {
            val present = ORDERED.filter { segment -> items.any { bucket(it) == segment } }
            return if (present.size >= 2) listOf(ALL) + present else emptyList()
        }
    }

    fun filter(items: List<MetaItem>): List<MetaItem> =
        if (this == ALL) items else items.filter { bucket(it) == this }
}

internal enum class LibrarySmartFilter(@param:StringRes val titleResource: Int) {
    UNWATCHED(R.string.library_filter_unwatched),
    IN_PROGRESS(R.string.library_filter_in_progress),
    WATCHED(R.string.library_filter_watched),
    SHORT(R.string.library_filter_short);

    fun matches(item: MetaItem): Boolean = when (this) {
        UNWATCHED -> !item.watched
        IN_PROGRESS -> item.progress?.let { it > 0f && it < IN_PROGRESS_CEIL } ?: false
        WATCHED -> item.watched
        SHORT -> item.previewRuntimeMinutes?.let { it in 1 until SHORT_RUNTIME_MINUTES } ?: false
    }

    companion object {
        private const val IN_PROGRESS_CEIL = 0.9f
        private const val SHORT_RUNTIME_MINUTES = 100

        fun applicable(items: List<MetaItem>): List<LibrarySmartFilter> {
            if (items.isEmpty()) return emptyList()
            return entries.filter { filter -> items.any(filter::matches) && items.any { !filter.matches(it) } }
        }

        fun apply(items: List<MetaItem>, selected: Set<LibrarySmartFilter>): List<MetaItem> =
            if (selected.isEmpty()) items else items.filter { item -> selected.all { it.matches(item) } }

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
