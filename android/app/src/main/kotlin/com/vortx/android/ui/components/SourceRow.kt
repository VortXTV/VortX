package com.vortx.android.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlassRow

/// One ranked source (DESIGN-SYSTEM.md §3 "Source row"): a surface-card row, leading play/download
/// icon, a prominent [quality] badge (4K/1080p) + [addon] badge + a TORRENT badge when [isTorrent],
/// then [flavorTags] + [size], then the release [title] (2-line clamp). Tapping resolves + plays;
/// [enabled] dims + disables the row while another resolve is in flight.
///
/// [pinned] marks the stream the user's source pin floats to the top (Apple's per-row pin badge, #15);
/// [onLongClick] (additive: null keeps every existing call site unchanged) opens the pin menu the
/// caller anchors to this row, the Android analogue of Apple's `.contextMenu { pinMenu(...) }`.
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
    pinned: Boolean = false,
    onLongClick: (() -> Unit)? = null,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .vortxGlassRow()
            .then(
                if (onLongClick != null) {
                    Modifier.combinedClickable(enabled = enabled, onClick = onClick, onLongClick = onLongClick)
                } else {
                    Modifier.clickable(enabled = enabled, onClick = onClick)
                },
            )
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
                if (pinned) Badge("Pinned")
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
