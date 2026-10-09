package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.library.WatchlistStore
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.DefaultPosterArt
import com.vortx.android.ui.components.cinemaCardFacts
import com.vortx.android.ui.components.cinemaLandscapeArtwork
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** A real modal focus window: closing returns to the still-mounted catalog tile underneath. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal fun TvQuickViewDialog(
    item: MetaItem,
    store: WatchlistStore,
    actions: TvQuickViewActions,
    onClose: () -> Unit,
) {
    val watchlist by store.items.collectAsStateWithLifecycle()
    val inWatchlist = watchlist.any { it.id == item.id && it.type == item.type }
    val storeError by store.error.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var busy by remember(item.id, item.type) { mutableStateOf(false) }
    var message by remember(item.id, item.type) { mutableStateOf<String?>(null) }
    val watchFocus = remember { FocusRequester() }
    val colors = VortXTheme.colors
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BackHandler(onBack = onClose)
        LaunchedEffect(Unit) {
            withFrameNanos { }
            runCatching { watchFocus.requestFocus() }
        }
        BoxWithConstraints(
            modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.72f)).padding(TvDimens.edge),
            contentAlignment = Alignment.Center,
        ) {
            Row(
                modifier = Modifier.widthIn(max = 1100.dp).fillMaxWidth().height(maxHeight * 0.9f)
                    .clip(VortXShapes.card).background(colors.surface1)
                    .focusGroup().focusProperties { exit = { FocusRequester.Cancel } },
            ) {
                Box(modifier = Modifier.fillMaxHeight().weight(0.38f), contentAlignment = Alignment.Center) {
                    val artwork = cinemaLandscapeArtwork(item)
                    if (artwork == null) DefaultPosterArt(item.name)
                    else AsyncImage(model = artwork, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.15f), Color.Black.copy(alpha = 0.65f)))))
                    item.poster?.takeIf(String::isNotBlank)?.let {
                        AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop,
                            modifier = Modifier.width(180.dp).height(270.dp).clip(VortXShapes.card))
                    }
                }
                Column(
                    modifier = Modifier.weight(0.62f).fillMaxHeight().padding(VortXTheme.spacing.xl),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                ) {
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Text("QUICK VIEW", style = VortXTheme.type.eyebrow.copy(color = colors.accent))
                        TvFilterChip("Close", selected = false, onClick = onClose)
                    }
                    Column(modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
                        Text(item.name, style = VortXTheme.type.hero, maxLines = 3, overflow = TextOverflow.Ellipsis)
                        cinemaCardFacts(item)?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary)) }
                        item.genres.takeIf { it.isNotEmpty() }?.let { Text(it.joinToString(" · "), style = VortXTheme.type.label.copy(color = colors.textTertiary)) }
                        item.description?.takeIf(String::isNotBlank)?.let { Text(it, style = VortXTheme.type.body.copy(color = colors.textSecondary)) }
                    }
                    TvPlayButton("Watch", enabled = true, onClick = { if (!actions.watch()) message = "Account or profile changed. Open this title again." },
                        modifier = Modifier.fillMaxWidth().focusRequester(watchFocus))
                    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                        TvFilterChip(
                            if (inWatchlist) "In Watchlist" else "Watchlist", selected = inWatchlist,
                            enabled = !busy && WatchlistStore.isSafeId(item.id),
                            onClick = {
                                val intent = try { actions.captureWatchlistToggle() } catch (error: Exception) {
                                    message = error.message ?: "Could not update Watchlist. Try again."
                                    return@TvFilterChip
                                }
                                busy = true
                                message = null
                                scope.launch {
                                    try {
                                        val added = actions.toggleWatchlist(intent)
                                        message = if (added) "Added to Watchlist" else "Removed from Watchlist"
                                    } catch (error: Exception) {
                                        if (error is CancellationException) throw error
                                        message = error.message ?: "Could not update Watchlist. Try again."
                                    } finally { busy = false }
                                }
                            },
                        )
                        TvFilterChip("Details", selected = false, onClick = { if (!actions.details()) message = "Account or profile changed. Open this title again." })
                    }
                    (message ?: storeError)?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary)) }
                }
            }
        }
    }
}
