package com.vortx.android.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.vortx.android.R
import com.vortx.android.home.CollectionsHubBrowsePhase
import com.vortx.android.home.CollectionsHubBrowseState
import com.vortx.android.home.CollectionsHubCategory
import com.vortx.android.home.CollectionsHubLabel
import com.vortx.android.home.CollectionsHubSnapshot
import com.vortx.android.home.CollectionsHubTarget
import com.vortx.android.home.CollectionsHubTile
import com.vortx.android.metadata.ProviderBrandLogo
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.theme.VortXTheme

@Composable
internal fun CollectionsHub(
    snapshot: CollectionsHubSnapshot,
    onOpen: (CollectionsHubTarget) -> Unit,
    onRetryProviders: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!snapshot.isVisible) return
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg)) {
        Text(
            text = stringResource(R.string.collections_title),
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
        )
        HubTileRow(stringResource(R.string.collections_group_discover), snapshot.discover, onOpen)
        if (snapshot.streaming.isNotEmpty()) {
            HubTileRow(stringResource(R.string.collections_group_streaming), snapshot.streaming, onOpen)
        }
        if (snapshot.streamingLoading) {
            ProviderLoading()
        }
        if (snapshot.streamingLoadFailed) {
            ProviderLoadError(onRetryProviders)
        }
        HubTileRow(stringResource(R.string.collections_group_genres), snapshot.genres, onOpen)
        HubTileRow(stringResource(R.string.collections_group_decades), snapshot.decades, onOpen)
    }
}

@Composable
private fun ProviderLoading() {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.edge),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator()
        Text(
            text = stringResource(R.string.collections_streaming_loading),
            style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
        )
    }
}

@Composable
private fun ProviderLoadError(onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(
            text = stringResource(R.string.collections_group_streaming),
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(R.string.collections_streaming_load_error),
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.weight(1f),
            )
            Button(onClick = onRetry) { Text(stringResource(R.string.collections_action_retry)) }
        }
    }
}

@Composable
private fun HubTileRow(
    title: String,
    tiles: List<CollectionsHubTile>,
    onOpen: (CollectionsHubTarget) -> Unit,
) {
    if (tiles.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Text(
            text = title,
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            items(tiles, key = CollectionsHubTile::id) { tile -> HubTile(tile, onOpen) }
        }
    }
}

@Composable
private fun HubTile(tile: CollectionsHubTile, onOpen: (CollectionsHubTarget) -> Unit) {
    val title = tile.title.resolve()
    val subtitle = tile.subtitle?.resolve()
    Card(
        onClick = { onOpen(tile.target) },
        modifier = Modifier.width(178.dp).aspectRatio(16f / 9f),
        colors = CardDefaults.cardColors(containerColor = VortXTheme.colors.surface2),
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            // A streaming-service tile with a curated brand style is drawn as a full-bleed brand fill with
            // its own centered mark (item 8), which IS its label, so the dark gradient + name overlay is
            // suppressed for it. Every other tile (Discover / genre / decade, or a service with no curated
            // style) keeps the representative-backdrop crop + the editorial title overlay.
            val serviceTarget = tile.target as? CollectionsHubTarget.Service
            val brandLabeled = serviceTarget != null &&
                ProviderBrandLogo.brandStyle(serviceTarget.providerId) != null
            if (serviceTarget != null) {
                ServiceTileArt(
                    providerId = serviceTarget.providerId,
                    name = serviceTarget.name,
                    imageUrl = tile.imageUrl,
                    modifier = Modifier.fillMaxSize(),
                )
            } else if (tile.imageUrl != null) {
                AsyncImage(
                    model = tile.imageUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            if (!brandLabeled) {
                Box(
                    modifier = Modifier.fillMaxSize().background(
                        Brush.verticalGradient(listOf(Color.Transparent, VortXTheme.colors.canvas.copy(alpha = 0.94f))),
                    ),
                )
                Column(
                    modifier = Modifier.align(Alignment.BottomStart).padding(VortXTheme.spacing.md),
                ) {
                    Text(title, style = VortXTheme.type.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    subtitle?.let {
                        Text(
                            it,
                            style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.textSecondary),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun CollectionsBrowseScreen(
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
            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.edge),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Button(onClick = onBack) { Text(stringResource(R.string.collections_action_back)) }
            Text(state.target?.title?.resolve().orEmpty(), style = VortXTheme.type.screenTitle)
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            items(state.categories, key = CollectionsHubCategory::id) { category ->
                val title = stringResource(category.titleResource)
                Button(
                    onClick = { onCategory(category) },
                    enabled = !state.loading || category == state.selectedCategory,
                ) {
                    Text(
                        if (category == state.selectedCategory) {
                            stringResource(R.string.collections_category_selected, title)
                        } else {
                            title
                        },
                    )
                }
            }
        }
        when (state.phase) {
            CollectionsHubBrowsePhase.IDLE -> Unit
            CollectionsHubBrowsePhase.LOADING -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            CollectionsHubBrowsePhase.ERROR -> ErrorState(
                stringResource(requireNotNull(state.error).messageResource),
                onRetry = onRetry,
                modifier = Modifier.fillMaxSize(),
            )
            CollectionsHubBrowsePhase.EMPTY -> EmptyState(
                hint = stringResource(R.string.collections_browse_empty),
                modifier = Modifier.fillMaxSize(),
                actionLabel = stringResource(R.string.collections_action_retry),
                onAction = onRetry,
            )
            CollectionsHubBrowsePhase.CONTENT -> LazyVerticalGrid(
                columns = GridCells.Adaptive(132.dp),
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(VortXTheme.spacing.edge),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
            ) {
                items(state.items, key = { "${it.type.id}|${it.id}" }) { item ->
                    PosterCard(
                        title = item.name,
                        subtitle = listOfNotNull(item.year, item.type.label).joinToString(" · "),
                        onClick = { onItem(item) },
                        art = { PosterArt(item.poster, item.name, id = item.id, type = item.type.id) },
                    )
                }
                if (state.hasMore || (state.error != null && state.items.isNotEmpty())) {
                    item {
                        Button(onClick = onLoadMore, enabled = !state.loading) {
                            Text(
                                when {
                                    state.loading -> stringResource(R.string.collections_loading)
                                    state.error != null -> stringResource(R.string.collections_action_retry)
                                    else -> stringResource(R.string.collections_action_load_more)
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CollectionsHubLabel.resolve(): String = when (this) {
    is CollectionsHubLabel.Literal -> value
    is CollectionsHubLabel.Resource -> stringResource(resourceId)
}
