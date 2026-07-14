package com.vortx.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxShadow

/// One ranked source (DESIGN-SYSTEM.md §3 "Source row"): a surface-card row, leading play/download
/// icon, a prominent [quality] badge (4K/1080p) + [addon] badge + a TORRENT badge when [isTorrent],
/// then [flavorTags] + [size], then the release [title] (2-line clamp). Tapping resolves + plays;
/// [enabled] dims + disables the row while another resolve is in flight.
@Composable
fun SourceRow(
    addon: String,
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    quality: String? = null,
    isTorrent: Boolean = false,
    flavorTags: List<String> = emptyList(),
    size: String? = null,
    enabled: Boolean = true,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .vortxShadow(VortXTheme.elevation.rest, VortXShapes.card)
            .clip(VortXShapes.card)
            .background(colors.surface1, VortXShapes.card)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Icon(
            imageVector = if (isTorrent) VortXIcons.arrowDownCircle else VortXIcons.playCircle,
            contentDescription = null,
            tint = if (enabled) colors.accent else colors.textTertiary,
        )
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                quality?.let { Badge(it) }
                Badge(addon)
                if (isTorrent) Badge("Torrent")
            }
            if (flavorTags.isNotEmpty() || size != null) {
                Text(
                    text = (flavorTags + listOfNotNull(size)).joinToString(" · "),
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )
            }
            Text(
                text = title,
                style = VortXTheme.type.cardTitle.copy(color = if (enabled) colors.textPrimary else colors.textTertiary),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
