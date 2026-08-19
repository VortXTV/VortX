package com.vortx.android.ui.search

import com.vortx.android.R

internal val SearchResultSectionKind.titleResourceId: Int
    get() = when (this) {
        SearchResultSectionKind.MOVIES -> R.string.search_section_movies
        SearchResultSectionKind.SERIES -> R.string.search_section_series
        SearchResultSectionKind.OTHER -> R.string.search_section_other
    }

internal val SearchEmptyMessage.textResourceId: Int
    get() = when (this) {
        SearchEmptyMessage.IDLE_GUIDANCE -> R.string.search_idle_guidance
        SearchEmptyMessage.NO_MATCHES -> R.string.search_no_matches
    }
