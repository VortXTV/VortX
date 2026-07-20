package com.vortx.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlassRow

/// One episode row (DESIGN-SYSTEM.md §3 "Episode row"): a 16:9 [thumb] slot + watched check + progress
/// stripe, `code` (S/E) + [title], [airDate], and a 2-line [overview]. Dims when [watched]. [thumb] is
/// a placeholder-friendly slot mirroring [PosterCard]'s `art` — a real thumbnail image drops in behind
/// it with no call-site change once Coil lands (S03).
///
/// [onLongClick] (S05 addition, opt-in/additive: null preserves every existing call site unchanged) is
/// the per-episode "mark watched/unwatched" menu trigger, mirroring the tvOS episode row's
/// `.contextMenu`.
@Composable
fun EpisodeRow(
    code: String,
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    overview: String? = null,
    airDate: String? = null,
    watched: Boolean = false,
    progress: Float? = null,
    onLongClick: (() -> Unit)? = null,
    thumb: @Composable () -> Unit = { DefaultEpisodeThumb() },
) {
    val colors = VortXTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .vortxGlassRow()
            .then(
                if (onLongClick != null) {
                    Modifier.combinedClickable(onLongClick = onLongClick, onClick = onClick)
                } else {
                    Modifier.clickable(onClick = onClick)
                },
            )
            .padding(VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Box(
            modifier = Modifier
                .width(140.dp)
                .aspectRatio(16f / 9f)
                .clip(VortXShapes.chip)
                .alpha(if (watched) 0.55f else 1f),
        ) {
            thumb()
            if (watched) {
                Icon(
                    imageVector = VortXIcons.checkmarkCircle,
                    contentDescription = "Watched",
                    tint = colors.accentBright,
                    modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(18.dp),
                )
            }
            if (progress != null && progress in 0f..1f) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .height(3.dp)
                        .background(colors.surface3.copy(alpha = 0.6f)),
                ) {
                    Box(modifier = Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).fillMaxSize().background(colors.accent))
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.alpha(if (watched) 0.7f else 1f)) {
            Badge(code)
            Text(
                text = title,
                style = VortXTheme.type.cardTitle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            airDate?.let {
                Text(text = it, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            }
            overview?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.body,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
fun DefaultEpisodeThumb() {
    Box(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.surface2))
}
