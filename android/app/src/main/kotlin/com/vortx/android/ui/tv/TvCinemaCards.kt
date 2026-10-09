package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items as railItems
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.VortXApplication
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.PosterCardMenu
import com.vortx.android.ui.components.PosterQuickActionMenu
import com.vortx.android.ui.components.cinemaCardFacts
import com.vortx.android.ui.search.SearchResultSection
import com.vortx.android.ui.search.searchResultItemKey
import com.vortx.android.ui.search.searchResultSectionHeaderKey
import com.vortx.android.ui.search.searchResultSections
import com.vortx.android.ui.search.titleResourceId
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource

/** A single remote target containing existing wide artwork, preview facts and synopsis. */
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvCinemaCard(
    item: MetaItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp? = null,
    onFocused: () -> Unit = {},
    focusRequester: FocusRequester? = null,
    continueWatching: Boolean = false,
    onRemoveFromContinueWatching: (() -> Unit)? = null,
) {
    val colors = VortXTheme.colors
    val appContext = LocalContext.current.applicationContext
    var menuOpen by remember(item.type, item.id) { mutableStateOf(false) }
    Box(modifier = modifier.then(if (width == null) Modifier.fillMaxWidth() else Modifier.width(width))) {
        if (continueWatching) {
            PosterQuickActionMenu(
                item = item,
                menu = PosterCardMenu.CONTINUE_WATCHING,
                expanded = menuOpen,
                onDismiss = { menuOpen = false },
                onDetails = onClick,
                onRemoveFromContinueWatching = onRemoveFromContinueWatching,
                repository = { (appContext as? VortXApplication)?.catalogRepository },
            )
        }
        Surface(
            onClick = onClick,
            onLongClick = if (continueWatching) ({ menuOpen = true }) else null,
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = listOfNotNull(item.name, cinemaCardFacts(item), item.resumeLabel).joinToString(". ") }
                .onFocusChanged { if (it.isFocused) onFocused() }
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
            shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = colors.surface1.copy(alpha = 0.88f),
                contentColor = colors.textPrimary,
                focusedContainerColor = colors.surface3,
                focusedContentColor = colors.textPrimary,
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.035f),
            border = ClickableSurfaceDefaults.border(
                border = Border(BorderStroke(1.dp, colors.hairline), shape = VortXShapes.card),
                focusedBorder = Border(BorderStroke(TvDimens.focusBorder, colors.accentBright), shape = VortXShapes.card),
            ),
        ) {
            Column {
                Box(modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f)) {
                    TvPosterArt(item, landscape = true)
                    Box(modifier = Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.65f)))))
                    val status = if (continueWatching) item.resumeLabel?.let { "Resume $it" } else if (item.watched) "Watched" else null
                    status?.let {
                        Text(it, style = VortXTheme.type.label, modifier = Modifier.align(Alignment.BottomStart).padding(12.dp))
                    }
                    item.progress?.takeIf { it in 0f..1f }?.let { progress ->
                        Box(modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(colors.surface3)) {
                            Box(modifier = Modifier.fillMaxWidth(progress).fillMaxSize().background(colors.accent))
                        }
                    }
                }
                Column(modifier = Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(item.name, style = VortXTheme.type.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    cinemaCardFacts(item)?.let {
                        Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    if (!continueWatching) {
                        Text(
                            item.description?.takeIf(String::isNotBlank) ?: item.genres.take(3).joinToString(" · "),
                            style = VortXTheme.type.label.copy(color = colors.textTertiary),
                            minLines = 2,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

/** Search keeps its content-type sections while presenting each result as a large landscape card. */
@Composable
internal fun TvCinemaGrid(
    items: List<MetaItem>,
    onItem: (MetaItem) -> Unit,
    emptyHint: String,
    modifier: Modifier = Modifier,
    sectioned: Boolean = false,
) {
    if (items.isEmpty()) {
        TvEmpty(emptyHint, modifier)
        return
    }
    val deduped = remember(items) { items.distinctBy(::searchResultItemKey) }
    val sections = remember(deduped, sectioned) {
        if (sectioned) searchResultSections(deduped) else listOf(SearchResultSection(null, deduped))
    }
    LazyVerticalGrid(
        columns = GridCells.Adaptive(280.dp),
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(TvDimens.edge),
        horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
    ) {
        sections.forEach { section ->
            section.kind?.let { kind ->
                item(key = searchResultSectionHeaderKey(kind), span = { GridItemSpan(maxLineSpan) }) {
                    Text(stringResource(kind.titleResourceId), style = VortXTheme.type.sectionTitle)
                }
            }
            items(section.items, key = ::searchResultItemKey) { item -> TvCinemaCard(item, onClick = { onItem(item) }) }
        }
    }
}

/** Home and Library use the same geometry, facts, resume label and long-press behavior. */
@Composable
internal fun TvContinueWatchingRail(
    items: List<MetaItem>,
    onItem: (MetaItem) -> Unit,
    onRemove: (MetaItem) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Column(modifier = Modifier.padding(horizontal = TvDimens.edge)) {
            Text("Pick up where you left off", style = VortXTheme.type.eyebrow)
            Text("Continue Watching", style = VortXTheme.type.sectionTitle)
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        ) {
            railItems(tvHomeItems(items), key = ::tvHomeItemKey) { item ->
                TvCinemaCard(item, onClick = { onItem(item) }, width = 300.dp, continueWatching = true, onRemoveFromContinueWatching = { onRemove(item) })
            }
        }
    }
}
