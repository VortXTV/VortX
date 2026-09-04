package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.R
import com.vortx.android.home.UPCOMING_EPISODES_CATALOG_ID
import com.vortx.android.home.UPCOMING_MOVIES_CATALOG_ID
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.prefs.PosterStylePreferences
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.HomeViewModel

/// Settings > Upcoming: a dedicated full-grid view of the next-airing episode of every followed series and
/// every followed movie with a release inside the calendar horizon, the couch analogue of Apple's
/// `TVUpcomingScreen` / the shared `UpcomingView`. It reuses the SAME already-built release-calendar catalogs
/// the Home surface assembles ([UPCOMING_EPISODES_CATALOG_ID] / [UPCOMING_MOVIES_CATALOG_ID], driven by
/// [com.vortx.android.home.ReleaseCalendarModel]), read from the shared [HomeViewModel], so there is no second
/// data path: this is purely the couch full-list RENDERING of the same "Coming soon" rows Home already shows.
@Composable
fun TvUpcomingScreen(
    viewModel: HomeViewModel,
    onItem: (MetaItem) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val state by viewModel.state.collectAsStateWithLifecycle()
    val posterStyle by PosterStylePreferences.state.collectAsStateWithLifecycle()
    val layout = TvPosterLayoutPolicy.layout(posterStyle)

    val catalogs = (state as? UiState.Success<List<Catalog>>)?.data.orEmpty()
    val episodes = catalogs.firstOrNull { it.id == UPCOMING_EPISODES_CATALOG_ID }?.items.orEmpty()
    val movies = catalogs.firstOrNull { it.id == UPCOMING_MOVIES_CATALOG_ID }?.items.orEmpty()

    when {
        state is UiState.Loading && catalogs.isEmpty() -> TvLoading(modifier.fillMaxSize())
        episodes.isEmpty() && movies.isEmpty() ->
            TvEmpty(stringResource(R.string.tv_upcoming_empty), modifier.fillMaxSize())
        else -> LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = layout.width),
            modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas),
            contentPadding = PaddingValues(TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Text(stringResource(R.string.tv_upcoming_title), style = VortXTheme.type.screenTitle)
            }
            if (episodes.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    TvUpcomingSectionHeader(stringResource(R.string.tv_upcoming_episodes))
                }
                items(episodes, key = { "ep:${it.type.id}|${it.id}" }) { item ->
                    TvPosterCard(item = item, onClick = { onItem(item) }, onFocused = {})
                }
            }
            if (movies.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    TvUpcomingSectionHeader(stringResource(R.string.tv_upcoming_movies))
                }
                items(movies, key = { "mv:${it.type.id}|${it.id}" }) { item ->
                    TvPosterCard(item = item, onClick = { onItem(item) }, onFocused = {})
                }
            }
        }
    }
}

@Composable
private fun TvUpcomingSectionHeader(title: String) {
    Column {
        Text(title, style = VortXTheme.type.sectionTitle, modifier = Modifier.padding(top = VortXTheme.spacing.md))
    }
}
