package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.PosterCardMenu
import com.vortx.android.ui.components.posterMenuFor
import com.vortx.android.ui.theme.VortXTheme

/** Full-grid projection of the live Home row, including client rails and the existing row paging owner. */
@Composable
internal fun TvHomeCatalogBrowse(
    catalog: Catalog?,
    onBack: () -> Unit,
    onItem: (MetaItem) -> Unit,
    onLoadNextPage: (Catalog) -> Unit,
    onRemoveFromContinueWatching: (MetaItem) -> Unit,
) {
    val backFocus = remember { FocusRequester() }
    BackHandler(onBack = onBack)
    LaunchedEffect(Unit) {
        withFrameNanos { }
        runCatching { backFocus.requestFocus() }
    }
    Column(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(TvDimens.edge),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            TvFilterChip("Back to Home", selected = false, onClick = onBack, modifier = Modifier.focusRequester(backFocus))
            Text(catalog?.title ?: "Catalog unavailable", style = VortXTheme.type.sectionTitle)
        }
        if (catalog == null) {
            TvEmpty("This Home row is no longer available.", Modifier.weight(1f))
        } else {
            val menu = posterMenuFor(catalog)
            val continueWatching = tvIsContinueWatchingCatalog(catalog)
            TvBrowseGrid(
                items = tvHomeItems(catalog.items),
                emptyHint = "No titles in this catalog yet.",
                modifier = Modifier.weight(1f),
                minCardWidth = if (continueWatching) 300.dp else null,
                // Preserve a continuation even when a page is empty but another engine page exists.
                header = if (catalog.items.isEmpty() && catalog.hasNextPage) ({}) else null,
                footer = if (catalog.hasNextPage) {
                    {
                        TvFilterChip(
                            label = if (catalog.pageLoading) "Loading…" else "Load more",
                            selected = false,
                            onClick = { if (!catalog.pageLoading) onLoadNextPage(catalog) },
                        )
                    }
                } else null,
            ) { item ->
                if (continueWatching) {
                    TvCinemaCard(
                        item,
                        onClick = { onItem(item) },
                        continueWatching = true,
                        onRemoveFromContinueWatching = if (menu == PosterCardMenu.CONTINUE_WATCHING) ({ onRemoveFromContinueWatching(item) }) else null,
                    )
                } else {
                    TvPosterCard(item, onClick = { onItem(item) }, onFocused = {}, width = null, menu = menu)
                }
            }
        }
    }
}
