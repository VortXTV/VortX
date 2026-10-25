package com.vortx.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import com.vortx.android.sources.SourceCacheFacet
import com.vortx.android.sources.SourceCodecFacet
import com.vortx.android.sources.SourceQuickFilters
import com.vortx.android.sources.SourceRangeFacet
import com.vortx.android.ui.theme.VortXTheme

/** Phone/tablet and TV use their existing chip/focus style; only these local menus are shared. */
@Composable
internal fun SourceQuickFilterControls(
    filters: SourceQuickFilters,
    onChange: (SourceQuickFilters) -> Unit,
    button: @Composable (String, Boolean, () -> Unit) -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs), verticalAlignment = Alignment.CenterVertically) {
        SourceQuickFilterMenu(
            label = "Cache: ${filters.cache.label}", active = filters.cache != SourceCacheFacet.ALL,
            choices = SourceCacheFacet.entries.map { it.label to it }, selected = filters.cache,
            onSelect = { onChange(filters.copy(cache = it)) }, button = button,
        )
        SourceQuickFilterMenu(
            label = "Reported range: ${filters.range?.label ?: "All"}", active = filters.range != null,
            choices = listOf<Pair<String, SourceRangeFacet?>>("All" to null) + SourceRangeFacet.entries.map { it.label to it }, selected = filters.range,
            onSelect = { onChange(filters.copy(range = it)) }, button = button,
        )
        SourceQuickFilterMenu(
            label = "Reported codec: ${filters.codec?.label ?: "All"}", active = filters.codec != null,
            choices = listOf<Pair<String, SourceCodecFacet?>>("All" to null) + SourceCodecFacet.entries.map { it.label to it }, selected = filters.codec,
            onSelect = { onChange(filters.copy(codec = it)) }, button = button,
        )
        if (filters.active) button("Reset list filters", false) { onChange(SourceQuickFilters()) }
    }
}

@Composable
private fun <T> SourceQuickFilterMenu(
    label: String,
    active: Boolean,
    choices: List<Pair<String, T>>,
    selected: T,
    onSelect: (T) -> Unit,
    button: @Composable (String, Boolean, () -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        button(label, active) { open = true }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            choices.forEach { (title, value) ->
                DropdownMenuItem(
                    text = { Text(if (value == selected) "✓ $title" else title) },
                    onClick = { open = false; onSelect(value) },
                )
            }
        }
    }
}
