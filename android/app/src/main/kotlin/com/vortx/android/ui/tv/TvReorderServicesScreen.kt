package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import coil3.compose.AsyncImage
import com.vortx.android.R
import com.vortx.android.home.CollectionsHubLabel
import com.vortx.android.home.CollectionsHubModel
import com.vortx.android.home.CollectionsHubTarget
import com.vortx.android.home.CollectionsHubTile
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// Settings > Streaming Services: choose and reorder the streaming-service tiles shown in the Collections hub
/// on Home and Discover, the couch analogue of the phone / Apple `TVReorderServicesView` (BrowseGridView.swift).
/// "Your services" lists the current selection with Up / Down / Remove; "All services" lists the region pool
/// with Add. With nothing chosen the hub shows every service in the region (AUTO), exactly as before. Every
/// action writes the SAME cross-device `vortx.collections.selectedProviders` key through the shared
/// [CollectionsHubModel], whose change listener reloads the live hubs, so a pick here reflects everywhere.
@Composable
fun TvReorderServicesScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    // A picker-local model instance: it writes the shared selection key and its own listener republishes the
    // "Your services" list live; the write also fans out to every OTHER live hub instance via that key.
    val model = remember { CollectionsHubModel(context.applicationContext) }
    val snapshot by model.snapshot.collectAsStateWithLifecycle()
    var allServices by remember { mutableStateOf<List<CollectionsHubTile>>(emptyList()) }
    LaunchedEffect(model) {
        model.load()
        allServices = model.availableServices()
    }
    DisposableEffect(model) { onDispose { model.close() } }

    val yourServices = snapshot.streaming
    val yourIds = remember(yourServices) { yourServices.mapNotNull { it.serviceId() }.toSet() }
    val addable = remember(allServices, yourIds) {
        allServices.filter { it.serviceId()?.let { id -> id !in yourIds } ?: false }
    }

    LazyColumn(
        modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Text(stringResource(R.string.tv_services_title), style = VortXTheme.type.screenTitle)
                Text(
                    stringResource(R.string.tv_services_subtitle),
                    style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                )
                Row {
                    TvServicesAction(label = stringResource(R.string.tv_services_done), enabled = true, onClick = onBack)
                }
            }
        }

        item {
            Text(
                stringResource(R.string.tv_services_your),
                style = VortXTheme.type.cardTitle,
                modifier = Modifier.padding(top = VortXTheme.spacing.md),
            )
        }
        if (yourServices.isEmpty()) {
            item {
                Text(
                    stringResource(R.string.tv_services_your_empty),
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        itemsIndexed(yourServices, key = { _, tile -> tile.id }) { index, tile ->
            val id = tile.serviceId()
            Row(
                modifier = Modifier.fillMaxWidth().focusGroup().padding(vertical = VortXTheme.spacing.xs),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                Text("${index + 1}", style = VortXTheme.type.label, modifier = Modifier.width(36.dp))
                TvServiceLogo(tile.imageUrl)
                Text(
                    tile.serviceName(),
                    style = VortXTheme.type.cardTitle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                TvServicesAction(
                    label = stringResource(R.string.tv_services_up),
                    enabled = index > 0,
                    onClick = { id?.let { moveService(model, yourServices, index, -1) } },
                )
                TvServicesAction(
                    label = stringResource(R.string.tv_services_down),
                    enabled = index < yourServices.lastIndex,
                    onClick = { id?.let { moveService(model, yourServices, index, 1) } },
                )
                TvServicesAction(
                    label = stringResource(R.string.tv_services_remove),
                    enabled = id != null,
                    onClick = { id?.let(model::removeService) },
                )
            }
        }

        item {
            Text(
                stringResource(R.string.tv_services_all),
                style = VortXTheme.type.cardTitle,
                modifier = Modifier.padding(top = VortXTheme.spacing.md),
            )
        }
        if (addable.isEmpty()) {
            item {
                Text(
                    stringResource(R.string.tv_services_all_empty),
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        itemsIndexed(addable, key = { _, tile -> tile.id }) { _, tile ->
            val id = tile.serviceId()
            Row(
                modifier = Modifier.fillMaxWidth().focusGroup().padding(vertical = VortXTheme.spacing.xs),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                TvServiceLogo(tile.imageUrl)
                Text(
                    tile.serviceName(),
                    style = VortXTheme.type.cardTitle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                TvServicesAction(
                    label = stringResource(R.string.tv_services_add),
                    enabled = id != null,
                    onClick = { id?.let(model::addService) },
                )
            }
        }
        item { Spacer(Modifier.height(TvDimens.edge)) }
    }
}

/// Swap the service at [index] with its neighbour [delta] away and persist the new order (Apple `move`).
private fun moveService(model: CollectionsHubModel, tiles: List<CollectionsHubTile>, index: Int, delta: Int) {
    val target = index + delta
    if (target < 0 || target > tiles.lastIndex) return
    val ids = tiles.mapNotNull { it.serviceId() }.toMutableList()
    if (index > ids.lastIndex || target > ids.lastIndex) return
    val moved = ids[index]
    ids[index] = ids[target]
    ids[target] = moved
    model.reorderServices(ids)
}

/// The provider id behind a streaming tile, or null for a non-service tile (defensive; the hub's streaming row
/// only ever carries [CollectionsHubTarget.Service] tiles).
private fun CollectionsHubTile.serviceId(): Int? = (target as? CollectionsHubTarget.Service)?.providerId

/// The provider display name (streaming tiles always carry a literal name).
private fun CollectionsHubTile.serviceName(): String = (title as? CollectionsHubLabel.Literal)?.value.orEmpty()

/// A provider logo on the warm near-white plate that keeps a dark brand mark legible on the app's dark chrome,
/// the same plate the Where-to-Watch rail uses. Falls back to a blank plate when a tile has no logo.
@Composable
private fun TvServiceLogo(url: String?) {
    Box(
        modifier = Modifier
            .size(width = 64.dp, height = 40.dp)
            .clip(VortXShapes.control)
            .background(Color(0xFFF3F0EA)),
        contentAlignment = Alignment.Center,
    ) {
        if (!url.isNullOrBlank()) {
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().padding(6.dp),
            )
        }
    }
}

/// A compact neutral action button, mirroring the reorder controls on `TvCustomizeHomeScreen`.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvServicesAction(label: String, enabled: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
            disabledContainerColor = colors.surface1,
            disabledContentColor = colors.textTertiary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Text(label, style = VortXTheme.type.label, modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp))
    }
}
