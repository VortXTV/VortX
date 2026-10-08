package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.vortx.android.library.WatchlistStore
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.DefaultPosterArt
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.cinemaCardFacts
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/**
 * Lightweight, presentation-only title view. Actions delegate to the shell's existing detail/watchlist
 * owners: it never resolves a stream or fabricates an item URL itself.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CinemaQuickViewScreen(
    item: MetaItem,
    watchlistStore: WatchlistStore,
    onClose: () -> Unit,
    onWatch: () -> Unit,
    onDetails: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var watchlistMessage by remember(item.id) { mutableStateOf<String?>(null) }
    val inWatchlist = watchlistStore.isWatchlisted(item.id)
    Column(modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        TopAppBar(
            title = { Text("Quick view", style = VortXTheme.type.screenTitle) },
            navigationIcon = { IconButton(onClick = onClose) { Icon(VortXIcons.back, "Back") } },
        )
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Box(
                modifier = Modifier.fillMaxWidth().height(230.dp).clip(VortXShapes.card),
                contentAlignment = Alignment.Center,
            ) {
                val artwork = item.background?.takeIf { it.isNotBlank() } ?: item.poster
                if (artwork.isNullOrBlank()) {
                    DefaultPosterArt(item.name)
                } else {
                    AsyncImage(
                        model = artwork,
                        contentDescription = item.name,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                item.poster?.takeIf { it.isNotBlank() }?.let { poster ->
                    AsyncImage(
                        model = poster,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.width(112.dp).height(168.dp).clip(VortXShapes.card),
                    )
                }
            }
            Text(item.type.label.uppercase(), style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.accent))
            Text(item.name, style = VortXTheme.type.hero, maxLines = 2, overflow = TextOverflow.Ellipsis)
            cinemaCardFacts(item)?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary)) }
            item.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary), maxLines = 4, overflow = TextOverflow.Ellipsis)
            }
            PrimaryButton(text = "Watch", onClick = onWatch, leadingIcon = VortXIcons.playFill)
            Chip(
                label = if (inWatchlist) "Remove from Watchlist" else "Watchlist",
                selected = inWatchlist,
                leadingIcon = VortXIcons.bookmark,
                onClick = {
                    scope.launch {
                        val nowWatchlisted = watchlistStore.toggle(item)
                        watchlistMessage = if (nowWatchlisted) "Added to Watchlist" else "Removed from Watchlist"
                    }
                },
            )
            Chip(label = "Details", selected = false, leadingIcon = VortXIcons.moreHoriz, onClick = onDetails)
            watchlistMessage?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.accent)) }
        }
    }
}
