package com.vortx.android.ui.screens

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.vortx.android.R
import com.vortx.android.model.AdvancedDiscoverFilterOptions
import com.vortx.android.model.AdvancedDiscoverFilters
import com.vortx.android.model.GenreFilterState
import com.vortx.android.model.selectedDecadeStarts
import com.vortx.android.model.toggleDecade
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiscoverFilterSheet(
    filters: AdvancedDiscoverFilters,
    genreOptions: List<String>,
    showSeasons: Boolean,
    onChange: (AdvancedDiscoverFilters) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 680.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.discover_filters), style = VortXTheme.type.sectionTitle)
                Spacer(Modifier.weight(1f))
                if (filters.isActive) {
                    TextButton(onClick = { onChange(AdvancedDiscoverFilters.EMPTY) }) {
                        Text(stringResource(R.string.discover_clear_all))
                    }
                }
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.discover_done)) }
            }

            if (genreOptions.isNotEmpty()) {
                FilterSection(R.string.discover_genres, R.string.discover_genre_caption) {
                    genreOptions.forEach { genre ->
                        val state = filters.genreState(genre)
                        Chip(
                            label = when (state) {
                                GenreFilterState.OFF -> genre
                                GenreFilterState.INCLUDE -> "+ $genre"
                                GenreFilterState.EXCLUDE -> "- $genre"
                            },
                            selected = state != GenreFilterState.OFF,
                            stateDescription = when (state) {
                                GenreFilterState.OFF -> null
                                GenreFilterState.INCLUDE -> stringResource(R.string.discover_genre_included, genre)
                                GenreFilterState.EXCLUDE -> stringResource(R.string.discover_genre_excluded, genre)
                            },
                            accent = if (state == GenreFilterState.EXCLUDE) VortXTheme.colors.danger else VortXTheme.colors.accent,
                            accentText = if (state == GenreFilterState.EXCLUDE) VortXTheme.colors.danger else VortXTheme.colors.accentBright,
                            onClick = { onChange(filters.cycleGenre(genre)) },
                        )
                    }
                }
            }

            FilterSection(R.string.discover_release_years, R.string.discover_year_caption) {
                val selected = filters.selectedDecadeStarts()
                AdvancedDiscoverFilterOptions.decades.forEach { decade ->
                    Chip(
                        label = decadeLabel(decade.start),
                        selected = decade.start in selected,
                        onClick = { onChange(filters.toggleDecade(decade)) },
                    )
                }
                Chip(
                    label = stringResource(R.string.discover_upcoming_only),
                    selected = filters.upcomingOnly,
                    onClick = { onChange(filters.copy(upcomingOnly = !filters.upcomingOnly)) },
                )
            }

            FilterSection(R.string.discover_age_rating) {
                AdvancedDiscoverFilterOptions.ageRatings.forEach { rating ->
                    Chip(
                        label = rating,
                        selected = rating in filters.ageRatings,
                        onClick = {
                            onChange(
                                filters.copy(
                                    ageRatings = filters.ageRatings.toMutableSet().apply {
                                        if (!add(rating)) remove(rating)
                                    },
                                ),
                            )
                        },
                    )
                }
            }

            FilterSection(R.string.discover_duration) {
                AdvancedDiscoverFilterOptions.durationBuckets.forEachIndexed { index, bucket ->
                    val selected = filters.minMinutes == bucket.min && filters.maxMinutes == bucket.max
                    Chip(
                        label = durationLabel(index),
                        selected = selected,
                        onClick = {
                            onChange(
                                filters.copy(
                                    minMinutes = if (selected) null else bucket.min,
                                    maxMinutes = if (selected) null else bucket.max,
                                ),
                            )
                        },
                    )
                }
            }

            if (showSeasons) {
                FilterSection(R.string.discover_seasons) {
                    AdvancedDiscoverFilterOptions.seasonBuckets.forEachIndexed { index, bucket ->
                        val selected = filters.minSeasons == bucket.min && filters.maxSeasons == bucket.max
                        Chip(
                            label = seasonLabel(index),
                            selected = selected,
                            onClick = {
                                onChange(
                                    filters.copy(
                                        minSeasons = if (selected) null else bucket.min,
                                        maxSeasons = if (selected) null else bucket.max,
                                    ),
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FilterSection(
    @StringRes title: Int,
    @StringRes caption: Int? = null,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(stringResource(title), style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
        caption?.let {
            Text(stringResource(it), style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
        }
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            content = { content() },
        )
    }
}

@Composable
private fun decadeLabel(start: Int): String = stringResource(
    when (start) {
        2020 -> R.string.discover_decade_2020s
        2010 -> R.string.discover_decade_2010s
        2000 -> R.string.discover_decade_2000s
        1990 -> R.string.discover_decade_1990s
        1980 -> R.string.discover_decade_1980s
        1970 -> R.string.discover_decade_1970s
        else -> R.string.discover_decade_older
    },
)

@Composable
private fun durationLabel(index: Int): String = stringResource(
    listOf(
        R.string.discover_duration_under_30,
        R.string.discover_duration_30_60,
        R.string.discover_duration_60_90,
        R.string.discover_duration_90_120,
        R.string.discover_duration_over_2h,
    )[index],
)

@Composable
private fun seasonLabel(index: Int): String = stringResource(
    listOf(
        R.string.discover_seasons_one,
        R.string.discover_seasons_two_three,
        R.string.discover_seasons_four_six,
        R.string.discover_seasons_seven_plus,
    )[index],
)
