package com.vortx.android.ui.randompick

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.vortx.android.R
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.tv.TvFilterChip

/** Presentation only. The owning model validates every Open/Play action. */
@Composable
internal fun RandomPickControls(
    title: String,
    preview: String?,
    message: String?,
    loading: Boolean = false,
    onPick: () -> Unit,
    onOpen: () -> Unit,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
    tv: Boolean = false,
    filters: List<Pair<String, Boolean>> = emptyList(),
    onFilter: (Int) -> Unit = {},
    playEnabled: Boolean = true,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(text = title, style = VortXTheme.type.sectionTitle)
        if (filters.isNotEmpty()) {
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                filters.forEachIndexed { index, (label, selected) ->
                    RandomPickChip(label, selected, !loading, tv) { onFilter(index) }
                }
            }
        }
        Column(modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) {
            preview?.let { Text(text = it, style = VortXTheme.type.body) }
            message?.let {
                Text(text = it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
            }
            if (loading) {
                Text(
                    text = stringResource(R.string.random_pick_loading),
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                )
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            RandomPickChip(
                label = stringResource(if (preview == null) R.string.random_pick_pick else R.string.random_pick_pick_again),
                selected = false,
                enabled = !loading,
                tv = tv,
                onClick = onPick,
            )
            if (preview != null) {
                RandomPickChip(stringResource(R.string.random_pick_open), false, !loading, tv, onOpen)
                RandomPickChip(stringResource(R.string.random_pick_play), false, !loading && playEnabled, tv, onPlay)
            }
        }
    }
}

@Composable
private fun RandomPickChip(label: String, selected: Boolean, enabled: Boolean, tv: Boolean, onClick: () -> Unit) {
    if (tv) {
        TvFilterChip(label = label, selected = selected, enabled = enabled, onClick = onClick)
    } else {
        Chip(label = label, selected = selected, enabled = enabled, onClick = onClick)
    }
}
