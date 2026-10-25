package com.vortx.android.ui.randompick

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.vortx.android.R
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.tv.TvFilterChip

/** Shared phone/TV control. The ViewModel rechecks the current owner on every press. */
@Composable
internal fun HomeSurpriseControl(
    onPick: () -> Boolean,
    modifier: Modifier = Modifier,
    tv: Boolean = false,
) {
    var unavailable by remember { mutableStateOf(false) }
    val label = stringResource(R.string.home_surprise_pick)
    val pick = { unavailable = !onPick() }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        if (tv) {
            TvFilterChip(label = label, selected = false, leadingIcon = Icons.Default.Shuffle, onClick = pick)
        } else {
            Chip(label = label, selected = false, leadingIcon = Icons.Default.Shuffle, onClick = pick)
        }
        if (unavailable) {
            Text(
                text = stringResource(R.string.home_surprise_unavailable),
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
    }
}
