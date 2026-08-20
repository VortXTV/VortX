package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.R
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.PosterArt
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// A D-pad-focusable Library poster tile with a long-press quick-action menu, the 10-foot analogue of
/// Apple `SourcesTV/LibraryView.swift`'s `.contextMenu(menu: .library)` on the focused card: press-and-hold
/// Select opens Mark as Watched / Mark as Unwatched / Remove from Library. It reuses the SAME [PosterArt]
/// slot + tv `Surface` focus model as [TvPosterCard]; the library-specific menu is why it is a dedicated
/// tile rather than [TvPosterCard] (whose menu is fixed to the Catalog / Continue-Watching cases).
///
/// [onFocused] drives the Library hero off the focused tile; [onRemove] fires the engine remove
/// ([com.vortx.android.ui.viewmodel.LibraryViewModel.remove]); [onMarkWatched] flips the whole-title watched
/// flag through the repository's card-level mark (the engine's `MetaItemMarkAsWatched`).
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvLibraryPosterCard(
    item: MetaItem,
    onClick: () -> Unit,
    onFocused: () -> Unit,
    onRemove: () -> Unit,
    onMarkWatched: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
) {
    val colors = VortXTheme.colors
    var focused by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    Column(modifier = modifier.fillMaxWidth()) {
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_action_mark_watched)) },
                onClick = {
                    menuOpen = false
                    onMarkWatched(true)
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_action_mark_unwatched)) },
                onClick = {
                    menuOpen = false
                    onMarkWatched(false)
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.library_action_remove)) },
                onClick = {
                    menuOpen = false
                    onRemove()
                },
            )
        }
        Surface(
            onClick = onClick,
            onLongClick = { menuOpen = true },
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .onFocusChanged {
                    focused = it.isFocused
                    if (it.isFocused) onFocused()
                }
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
            shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = colors.surface2,
                contentColor = colors.textPrimary,
                focusedContainerColor = colors.surface2,
                focusedContentColor = colors.textPrimary,
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = TvDimens.focusScale),
            border = ClickableSurfaceDefaults.border(
                focusedBorder = Border(
                    border = BorderStroke(TvDimens.focusBorder, colors.accentBright),
                    shape = VortXShapes.card,
                ),
            ),
        ) {
            PosterArt(item.poster, item.name)
            if (item.watched) {
                Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
                Icon(
                    imageVector = VortXIcons.checkmarkCircle,
                    contentDescription = stringResource(R.string.library_watched_badge),
                    tint = colors.accentBright,
                    modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(24.dp),
                )
            }
            val progress = item.progress
            if (progress != null && progress in 0f..1f) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .height(4.dp)
                        .background(colors.surface3.copy(alpha = 0.6f)),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(progress.coerceIn(0f, 1f))
                            .fillMaxSize()
                            .background(colors.accent),
                    )
                }
            }
        }
        Text(
            text = item.name,
            style = VortXTheme.type.cardTitle.copy(
                color = if (focused) colors.textPrimary else colors.textPrimary.copy(alpha = 0.85f),
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}
