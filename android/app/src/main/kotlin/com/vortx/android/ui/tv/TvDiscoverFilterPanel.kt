package com.vortx.android.ui.tv

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.vortx.android.R
import com.vortx.android.model.AdvancedDiscoverFilterOptions
import com.vortx.android.model.AdvancedDiscoverFilters
import com.vortx.android.model.GenreFilterState
import com.vortx.android.model.selectedDecadeStarts
import com.vortx.android.model.toggleDecade
import com.vortx.android.ui.theme.VortXTheme

private data class TvDiscoverFilterChip(
    val key: String,
    val label: String,
    val selected: Boolean,
    val stateDescription: String? = null,
    val onClick: () -> Unit,
)

@Composable
fun TvDiscoverFilterPanel(
    filters: AdvancedDiscoverFilters,
    genreOptions: List<String>,
    showSeasons: Boolean,
    onChange: (AdvancedDiscoverFilters) -> Unit,
    onDismiss: () -> Unit,
) {
    val doneFocus = remember { FocusRequester() }
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(VortXTheme.colors.canvas)
                .verticalScroll(rememberScrollState())
                .padding(vertical = TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = TvDimens.edge),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                Text(stringResource(R.string.discover_filters), style = VortXTheme.type.screenTitle)
                Spacer(Modifier.weight(1f))
                if (filters.isActive) {
                    TvFilterChip(
                        label = stringResource(R.string.discover_clear_all),
                        selected = false,
                        onClick = { onChange(AdvancedDiscoverFilters.EMPTY) },
                    )
                }
                TvFilterChip(
                    label = stringResource(R.string.discover_done),
                    selected = true,
                    onClick = onDismiss,
                    modifier = Modifier.focusRequester(doneFocus),
                )
            }

            if (genreOptions.isNotEmpty()) {
                TvFilterSection(
                    title = R.string.discover_genres,
                    caption = R.string.discover_genre_caption,
                    chips = genreOptions.map { genre ->
                        val state = filters.genreState(genre)
                        TvDiscoverFilterChip(
                            key = "genre:$genre",
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
                            onClick = { onChange(filters.cycleGenre(genre)) },
                        )
                    },
                )
            }

            val selectedDecades = filters.selectedDecadeStarts()
            TvFilterSection(
                title = R.string.discover_release_years,
                caption = R.string.discover_year_caption,
                chips = AdvancedDiscoverFilterOptions.decades.map { decade ->
                    TvDiscoverFilterChip(
                        key = "decade:${decade.start}",
                        label = tvDecadeLabel(decade.start),
                        selected = decade.start in selectedDecades,
                        onClick = { onChange(filters.toggleDecade(decade)) },
                    )
                } + TvDiscoverFilterChip(
                    key = "upcoming",
                    label = stringResource(R.string.discover_upcoming_only),
                    selected = filters.upcomingOnly,
                    onClick = { onChange(filters.copy(upcomingOnly = !filters.upcomingOnly)) },
                ),
            )

            TvFilterSection(
                title = R.string.discover_age_rating,
                chips = AdvancedDiscoverFilterOptions.ageRatings.map { rating ->
                    TvDiscoverFilterChip(
                        key = "rating:$rating",
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
                },
            )

            TvFilterSection(
                title = R.string.discover_duration,
                chips = AdvancedDiscoverFilterOptions.durationBuckets.mapIndexed { index, bucket ->
                    val selected = filters.minMinutes == bucket.min && filters.maxMinutes == bucket.max
                    TvDiscoverFilterChip(
                        key = "duration:$index",
                        label = tvDurationLabel(index),
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
                },
            )

            if (showSeasons) {
                TvFilterSection(
                    title = R.string.discover_seasons,
                    chips = AdvancedDiscoverFilterOptions.seasonBuckets.mapIndexed { index, bucket ->
                        val selected = filters.minSeasons == bucket.min && filters.maxSeasons == bucket.max
                        TvDiscoverFilterChip(
                            key = "seasons:$index",
                            label = tvSeasonLabel(index),
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
                    },
                )
            }
        }
    }
    LaunchedEffect(Unit) { runCatching { doneFocus.requestFocus() } }
}

@Composable
private fun TvFilterSection(
    @StringRes title: Int,
    @StringRes caption: Int? = null,
    chips: List<TvDiscoverFilterChip>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(
            text = stringResource(title),
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = TvDimens.edge),
        )
        caption?.let {
            Text(
                text = stringResource(it),
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                modifier = Modifier.padding(horizontal = TvDimens.edge),
            )
        }
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = TvDimens.edge),
        ) {
            items(chips, key = TvDiscoverFilterChip::key) { chip ->
                TvFilterChip(
                    label = chip.label,
                    selected = chip.selected,
                    onClick = chip.onClick,
                    stateDescription = chip.stateDescription,
                )
            }
        }
    }
}

@Composable
private fun tvDecadeLabel(start: Int): String = stringResource(
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
private fun tvDurationLabel(index: Int): String = stringResource(
    listOf(
        R.string.discover_duration_under_30,
        R.string.discover_duration_30_60,
        R.string.discover_duration_60_90,
        R.string.discover_duration_90_120,
        R.string.discover_duration_over_2h,
    )[index],
)

@Composable
private fun tvSeasonLabel(index: Int): String = stringResource(
    listOf(
        R.string.discover_seasons_one,
        R.string.discover_seasons_two_three,
        R.string.discover_seasons_four_six,
        R.string.discover_seasons_seven_plus,
    )[index],
)
