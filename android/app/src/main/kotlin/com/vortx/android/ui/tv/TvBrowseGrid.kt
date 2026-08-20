package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.search.searchResultItemKey

/// The focus-tracking poster grid shared by TV Discover and Library, the analogue of Apple's
/// `BrowseGridView` grid: a dense D-pad `LazyVerticalGrid` that can carry full-span [header] content (a
/// Collections hub, a segment/filter bar, a result count) ABOVE the poster cells, and whose cells are drawn
/// by the caller's [card] slot so each surface wires its own focus -> hero + long-press affordances.
///
/// It differs from [TvPosterGrid] only by exposing the header slot and delegating the cell, which
/// [TvPosterGrid] cannot do (its cells are fixed and focus-inert). Identities are de-duplicated the same way
/// so a page-boundary duplicate never collides the grid `key`.
@Composable
internal fun TvBrowseGrid(
    items: List<MetaItem>,
    emptyHint: String,
    modifier: Modifier = Modifier,
    header: (LazyGridScope.() -> Unit)? = null,
    footer: (@Composable () -> Unit)? = null,
    card: @Composable (MetaItem) -> Unit,
) {
    // An empty grid with NO header is a calm hint; with a header (e.g. the Collections hub) the header still
    // renders so the surface is never a dead black panel while the catalog is empty.
    if (items.isEmpty() && header == null) {
        TvEmpty(emptyHint, modifier)
        return
    }
    val deduped = remember(items) { items.distinctBy(::searchResultItemKey) }
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = TvDimens.posterWidth),
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(TvDimens.edge),
        horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
    ) {
        header?.invoke(this)
        items(deduped, key = ::searchResultItemKey) { item -> card(item) }
        if (footer != null) {
            item(span = { GridItemSpan(maxLineSpan) }) { footer() }
        }
    }
}
