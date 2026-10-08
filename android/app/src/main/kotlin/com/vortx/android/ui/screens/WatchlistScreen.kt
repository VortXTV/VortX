package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.library.WatchlistStore
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

/** Profile-local Watchlist grid. This is a route over the existing persisted store, not a duplicate list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WatchlistScreen(
    store: WatchlistStore,
    onBack: () -> Unit,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val items by store.items.collectAsStateWithLifecycle()
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Watchlist", style = VortXTheme.type.screenTitle) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(VortXIcons.back, "Back") } },
        )
        PosterGrid(
            items = items,
            onItem = onItem,
            emptyHint = "Titles you add to Watchlist appear here.",
            showMenu = true,
        )
    }
}
