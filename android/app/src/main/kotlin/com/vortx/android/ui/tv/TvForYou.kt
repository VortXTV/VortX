package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.vortx.android.R
import com.vortx.android.ui.foryou.ForYouChip
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/** The TV chip for the For You pickers: the same `TvFilterChip` every TV filter uses. */
val tvForYouChip: ForYouChip = { label, selected, onClick, icon -> TvFilterChip(label = label, selected = selected, onClick = onClick, leadingIcon = icon) }

/** "For you" heading with Tune above the interest rows on TV Home. Takes Home's first focus when it leads. */
@Composable
internal fun TvForYouHeader(onTune: () -> Unit, focus: FocusRequester?) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = TvDimens.edge),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(stringResource(R.string.for_you_section_title), style = VortXTheme.type.sectionTitle)
        TvFilterChip(
            label = stringResource(R.string.for_you_tune), selected = false, onClick = onTune,
            modifier = focus?.let { Modifier.focusRequester(it) } ?: Modifier, leadingIcon = Icons.Filled.Tune,
        )
    }
}

/** Shown in place of the rows when the profile skipped the picker or cleared every choice. */
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvForYouInvite(onTune: () -> Unit, focus: FocusRequester?) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onTune,
        modifier = Modifier.padding(horizontal = TvDimens.edge).widthIn(max = 900.dp)
            .then(focus?.let { Modifier.focusRequester(it) } ?: Modifier),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
        colors = ClickableSurfaceDefaults.colors(containerColor = colors.surface1.copy(alpha = 0.88f), focusedContainerColor = colors.surface3),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            border = Border(BorderStroke(1.dp, colors.hairline), shape = VortXShapes.card),
            focusedBorder = Border(BorderStroke(TvDimens.focusBorder, colors.accentBright), shape = VortXShapes.card),
        ),
    ) {
        Row(modifier = Modifier.padding(VortXTheme.spacing.md), horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.FavoriteBorder, contentDescription = null, tint = colors.accentBright)
            Column {
                Text(stringResource(R.string.for_you_invite_title), style = VortXTheme.type.cardTitle)
                Text(stringResource(R.string.for_you_invite_body), style = VortXTheme.type.label.copy(color = colors.textSecondary))
            }
        }
    }
}
