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
    /// DET-8: a prominent "Cached" badge when the ranker marks this source instant-from-cache; the caller
    /// drops the plain "Cached" flavour tag so a cached row reads as one badge. False by default (no badge).
    cached: Boolean = false,
    /// DET-8: the advertised seeder count for a torrent source, appended to the detail line ("N seeders").
    /// Null (the default) omits it, for a non-torrent source or when no count was advertised.
    seeders: Int? = null,
    // Compact rows (Apple `vortx.streams.compactLabels`, #117): drop the raw release-title line, leaving the
    // parsed badges + flavour tags + size. Additive default keeps every existing call site unchanged.
    compact: Boolean = false,
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
                // DET-8: the instant-from-cache badge, prominent so it reads as the decisive signal.
                if (cached) Badge("⚡ Cached", prominent = true)
            }
            val detailParts = flavorTags + listOfNotNull(size) + listOfNotNull(seeders?.let { "$it seeders" })
            if (detailParts.isNotEmpty()) {
                Text(
                    text = detailParts.joinToString(" · "),
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )
            }
            if (!compact) {
                Text(
                    text = title,
                    style = VortXTheme.type.cardTitle.copy(color = if (enabled) colors.textPrimary else colors.textTertiary),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
