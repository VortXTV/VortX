package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import coil3.compose.AsyncImage
import com.vortx.android.model.MetaItem
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.components.PosterArt
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// A D-pad-focusable poster tile for the TV Home rows, built on androidx.tv's `Surface` so focus brings
/// the couch-scale affordances for free: it scales up ([TvDimens.focusScale]), lights an accent-bright
/// ring, and fires [onClick] on the D-pad center key -- none of which a phone touch card needs. Reuses the
/// SAME [PosterArt] slot every phone poster goes through (Coil art with the brand-tinted placeholder
/// fallback), so there is no second image path. [onFocused] fires whenever this tile takes focus, letting
/// the Home screen drive its cinematic backdrop off whatever the viewer is pointing at. [focusRequester],
/// when set, lets the screen seed initial focus on the first tile.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvPosterCard(
    item: MetaItem,
    onClick: () -> Unit,
    onFocused: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
) {
    val colors = VortXTheme.colors
    var focused by remember { mutableStateOf(false) }
    Column(modifier = modifier.width(TvDimens.posterWidth)) {
        Surface(
            onClick = onClick,
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
            // Continue Watching items carry a watched fraction; draw the accent progress track under the
            // art the same way the phone [com.vortx.android.ui.components.PosterCard] does.
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
        val subtitle = listOfNotNull(item.year, item.type.label).joinToString(" · ")
        if (subtitle.isNotBlank()) {
            Text(
                text = subtitle,
                style = VortXTheme.type.label.copy(color = colors.textTertiary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/// A D-pad-focusable source row for the TV Detail page's stream list. Same tv `Surface` focus model as the
/// poster tile (scale + accent ring + D-pad-center click), tuned flatter for a list row. Tapping it plays
/// that specific source through [DetailViewModel.play].
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvSourceRow(
    source: StreamSource,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp)) {
            Text(
                text = source.title,
                style = VortXTheme.type.body,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val meta = listOfNotNull(
                source.quality,
                source.addon,
                if (source.isTorrent) "TORRENT" else null,
            ).joinToString(" · ")
            if (meta.isNotBlank()) {
                Text(
                    text = meta,
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            source.description?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/// The primary Watch/Resume call-to-action on the TV Detail page: a focusable accent pill that runs
/// [DetailViewModel.playBest]. Focus brightens the fill to accentBright and scales it up.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvPlayButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.pill),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.accent,
            contentColor = colors.onAccent,
            focusedContainerColor = colors.accentBright,
            focusedContentColor = colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.05f),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 28.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(imageVector = VortXIcons.playFill, contentDescription = null, tint = colors.onAccent)
            Spacer(Modifier.width(10.dp))
            Text(
                text = label,
                style = VortXTheme.type.body.copy(color = colors.onAccent, fontWeight = FontWeight.SemiBold),
            )
        }
    }
}

/// Full-bleed cinematic backdrop for the hero band and the detail page. A Coil [AsyncImage] when [url] is
/// present, otherwise a deterministic brand-tinted gradient keyed by [seed] so an art-less title (an
/// unloaded preview, a still-hydrating engine row) still reads as an intentional panel rather than a black
/// bar. The caller layers scrims + content over it.
@Composable
fun TvBackdrop(url: String?, seed: String, modifier: Modifier = Modifier) {
    if (url.isNullOrBlank()) {
        Box(modifier = modifier.background(backdropBrush(seed, VortXTheme.colors)))
    } else {
        AsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = modifier,
        )
    }
}

/// A deterministic two-stop gradient hued around the live accent, seeded by a string so an art-less hero
/// stays in the current theme family. Mirrors the placeholder idea in
/// [com.vortx.android.ui.components.DefaultPosterArt] but sized/toned for a wide backdrop.
private fun backdropBrush(seed: String, colors: com.vortx.android.ui.theme.VortXColors): Brush {
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(colors.accent.toArgb(), hsv)
    val hueShift = ((seed.hashCode() ushr 8) % 40) - 20
    val hue = ((hsv[0] + hueShift) % 360f + 360f) % 360f
    val top = Color(android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.40f, 0.22f)))
    return Brush.verticalGradient(listOf(top, colors.canvas))
}

/// Centered loading state (a bare spinner is acceptable for the TV slice's first paint; the phone shell's
/// skeleton shimmer is a later parity item).
@Composable
fun TvLoading(modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = VortXTheme.colors.accent)
    }
}

/// Centered error state with a focusable Retry, so a failed catalog/detail load on TV is a recoverable
/// card rather than a dead black screen.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvError(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    val retryFocus = remember { FocusRequester() }
    Column(
        modifier = modifier.fillMaxSize().padding(TvDimens.edge),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = message,
            style = VortXTheme.type.body.copy(color = colors.textSecondary),
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(TvDimens.rowGap))
        TvPlayButton(label = "Retry", enabled = true, onClick = onRetry, focusRequester = retryFocus)
    }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        runCatching { retryFocus.requestFocus() }
    }
}
