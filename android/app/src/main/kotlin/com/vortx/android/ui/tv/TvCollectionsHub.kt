package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import coil3.compose.AsyncImage
import com.vortx.android.R
import com.vortx.android.home.CollectionsHubBrowsePhase
import com.vortx.android.home.CollectionsHubBrowseState
import com.vortx.android.home.CollectionsHubCategory
import com.vortx.android.home.CollectionsHubLabel
import com.vortx.android.home.CollectionsHubSnapshot
import com.vortx.android.home.CollectionsHubTarget
import com.vortx.android.home.CollectionsHubTile
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

@Composable
internal fun TvCollectionsHub(
    snapshot: CollectionsHubSnapshot,
    onOpen: (CollectionsHubTarget) -> Unit,
    onRetryProviders: () -> Unit,
    initialFocusRequester: FocusRequester? = null,
) {
    if (!snapshot.isVisible) return
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg)) {
        Text(
            stringResource(R.string.collections_title),
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = TvDimens.edge),
        )
        TvHubRow(stringResource(R.string.collections_group_discover), snapshot.discover, onOpen, initialFocusRequester)
        if (snapshot.streaming.isNotEmpty()) {
            TvHubRow(stringResource(R.string.collections_group_streaming), snapshot.streaming, onOpen)
        }
        if (snapshot.streamingLoading) {
            Text(
                text = stringResource(R.string.collections_streaming_loading),
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.padding(horizontal = TvDimens.edge),
            )
        }
        if (snapshot.streamingLoadFailed) {
            TvProviderLoadError(onRetryProviders)
        }
        TvHubRow(stringResource(R.string.collections_group_genres), snapshot.genres, onOpen)
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvProviderLoadError(onRetry: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = TvDimens.edge),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = stringResource(R.string.collections_streaming_load_error),
            style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            modifier = Modifier.weight(1f),
        )
        Surface(onClick = onRetry) {
            Text(
                text = stringResource(R.string.collections_action_retry),
                modifier = Modifier.padding(horizontal = VortXTheme.spacing.lg, vertical = VortXTheme.spacing.sm),
            )
        }
    }
}

@Composable
private fun TvHubRow(
    title: String,
    tiles: List<CollectionsHubTile>,
    onOpen: (CollectionsHubTarget) -> Unit,
    initialFocusRequester: FocusRequester? = null,
) {
    if (tiles.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Text(
            title.uppercase(),
            style = VortXTheme.type.eyebrow,
            modifier = Modifier.padding(horizontal = TvDimens.edge),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        ) {
            itemsIndexed(tiles, key = { _, tile -> tile.id }) { index, tile ->
                TvHubTile(tile, onOpen, if (index == 0) initialFocusRequester else null)
            }
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvHubTile(
    tile: CollectionsHubTile,
    onOpen: (CollectionsHubTarget) -> Unit,
    focusRequester: FocusRequester?,
) {
    val colors = VortXTheme.colors
    val title = tile.title.resolve()
    val subtitle = tile.subtitle?.resolve()
    var focused by remember { mutableStateOf(false) }
    Surface(
        onClick = { onOpen(tile.target) },
        modifier = Modifier
            .width(250.dp)
            .height(140.dp)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .onFocusChanged { focused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface2,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.05f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(3.dp, colors.accentBright),
                shape = VortXShapes.card,
            ),
        ),
    ) {
        Box(Modifier.fillMaxSize()) {
            tile.imageUrl?.let {
                AsyncImage(
                    model = it,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(listOf(Color.Transparent, colors.canvas.copy(alpha = 0.95f))),
                ),
            )
            Column(Modifier.align(Alignment.BottomStart).padding(VortXTheme.spacing.md)) {
                Text(title, style = VortXTheme.type.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                subtitle?.let {
                    Text(
                        it,
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
internal fun TvCollectionsBrowseScreen(
    state: CollectionsHubBrowseState,
    onBack: () -> Unit,
    onItem: (MetaItem) -> Unit,
    onCategory: (CollectionsHubCategory) -> Unit,
    onRetry: () -> Unit,
    onLoadMore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    Column(modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(TvDimens.edge),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        ) {
            TvPlayButton(stringResource(R.string.collections_action_back), enabled = true, onClick = onBack)
            Text(state.target?.title?.resolve().orEmpty(), style = VortXTheme.type.screenTitle)
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            itemsIndexed(state.categories, key = { _, category -> category.id }) { _, category ->
                val title = stringResource(category.titleResource)
                TvPlayButton(
                    label = if (category == state.selectedCategory) {
                        stringResource(R.string.collections_category_selected, title)
                    } else {
                        title
                    },
                    enabled = !state.loading || category == state.selectedCategory,
                    onClick = { onCategory(category) },
                )
            }
        }
        when (state.phase) {
            CollectionsHubBrowsePhase.IDLE -> Unit
            CollectionsHubBrowsePhase.LOADING -> TvLoading(Modifier.fillMaxSize())
            CollectionsHubBrowsePhase.ERROR -> TvError(
                stringResource(requireNotNull(state.error).messageResource),
                onRetry = onRetry,
                modifier = Modifier.fillMaxSize(),
            )
            CollectionsHubBrowsePhase.EMPTY -> TvCollectionsEmpty(onRetry, Modifier.weight(1f))
            CollectionsHubBrowsePhase.CONTENT -> TvPosterGrid(
                items = state.items,
                onItem = onItem,
                emptyHint = stringResource(R.string.collections_browse_empty),
                modifier = Modifier.weight(1f),
                footer = if (state.hasMore || (state.error != null && state.items.isNotEmpty())) {
                    {
                        Box(Modifier.fillMaxWidth().padding(vertical = VortXTheme.spacing.lg), contentAlignment = Alignment.Center) {
                            TvPlayButton(
                                label = when {
                                    state.loading -> stringResource(R.string.collections_loading)
                                    state.error != null -> stringResource(R.string.collections_action_retry)
                                    else -> stringResource(R.string.collections_action_load_more)
                                },
                                enabled = !state.loading,
                                onClick = onLoadMore,
                            )
                        }
                    }
                } else {
                    null
                },
            )
        }
    }
}

@Composable
private fun TvCollectionsEmpty(onRetry: () -> Unit, modifier: Modifier = Modifier) {
    val retryFocus = remember { FocusRequester() }
    Column(
        modifier = modifier.fillMaxSize().padding(TvDimens.edge),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = stringResource(R.string.collections_browse_empty),
            style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
        )
        TvPlayButton(
            label = stringResource(R.string.collections_action_retry),
            enabled = true,
            onClick = onRetry,
            focusRequester = retryFocus,
        )
    }
    LaunchedEffect(Unit) { runCatching { retryFocus.requestFocus() } }
}

@Composable
private fun CollectionsHubLabel.resolve(): String = when (this) {
    is CollectionsHubLabel.Literal -> value
    is CollectionsHubLabel.Resource -> stringResource(resourceId)
}
