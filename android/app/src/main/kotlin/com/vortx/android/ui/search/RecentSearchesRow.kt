package com.vortx.android.ui.search

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

/// The "Recent Searches" section (SD-6), the Android port of Apple `iOSSearchView.historySection`
/// (iOSRootView.swift:2511-2532): a section heading over a horizontally-scrolling row of recent-term
/// chips, each led by the clock glyph, closed by a trailing "Clear" chip led by the trash glyph. Shown by
/// the caller only when the field is empty and the active profile has recents. Tapping a term re-runs it;
/// tapping Clear wipes the active profile's list.
@Composable
fun RecentSearchesRow(
    history: List<String>,
    onPick: (String) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Text(
            text = "Recent Searches",
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            history.forEach { term ->
                Chip(label = term, selected = false, leadingIcon = VortXIcons.clock, onClick = { onPick(term) })
            }
            Chip(label = "Clear", selected = false, leadingIcon = VortXIcons.delete, onClick = onClear)
        }
    }
}
