package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.library.WatchlistStore
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.LibraryLandingViewModel

enum class TvLibraryRoute { LANDING, DOWNLOADS, WATCHLIST, HISTORY }

@Composable
internal fun TvLibraryRouteHeader(title: String, onBack: () -> Unit) {
    val backFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        withFrameNanos { }
        runCatching { backFocus.requestFocus() }
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(TvDimens.edge),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        TvFilterChip("Back to Library", selected = false, onClick = onBack, modifier = Modifier.focusRequester(backFocus))
        Text(title, style = VortXTheme.type.sectionTitle)
    }
}

/** The same native/legacy Watchlist projection used by Detail and touch; no second saved-title list. */
@Composable
internal fun TvWatchlistScreen(store: WatchlistStore, onBack: () -> Unit, onItem: (MetaItem) -> Unit) {
    val items by store.items.collectAsStateWithLifecycle()
    val error by store.error.collectAsStateWithLifecycle()
    LaunchedEffect(store) { store.requestReload() }
    Column(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        TvLibraryRouteHeader("Watchlist", onBack)
        if (error != null) TvError(error!!, store::requestReload, Modifier.weight(1f))
        else TvCinemaGrid(items, onItem, "Titles you add to Watchlist appear here.", Modifier.weight(1f))
    }
}

/** Includes unsaved played titles through the authoritative history projection, as touch does. */
@Composable
internal fun TvPreviouslyWatchedScreen(viewModel: LibraryLandingViewModel, onBack: () -> Unit, onItem: (MetaItem) -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    Column(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        TvLibraryRouteHeader("Previously Watched", onBack)
        when (val loaded = state) {
            is UiState.Loading -> TvLoading(Modifier.weight(1f))
            is UiState.Error -> TvError(loaded.message, viewModel::retry, Modifier.weight(1f))
            is UiState.Success -> TvCinemaGrid(
                loaded.data.playbackHistory,
                onItem,
                "Titles you watch appear here, even when they are not saved.",
                Modifier.weight(1f),
            )
        }
    }
}
