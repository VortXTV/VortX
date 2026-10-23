package com.vortx.android.ui.foryou

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.vortx.android.R
import com.vortx.android.foryou.ForYouInterests
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/** The phone/tablet chip for the For You pickers: the app's one secondary control. */
val phoneForYouChip: ForYouChip = { label, selected, onClick, icon -> Chip(label = label, selected = selected, onClick = onClick, leadingIcon = icon) }

/** "For you" heading with Tune, above the interest rows on phone and tablet Home. */
@Composable
fun ForYouHeaderPhone(onTune: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.edge),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(stringResource(R.string.for_you_section_title), style = VortXTheme.type.sectionTitle)
        Chip(label = stringResource(R.string.for_you_tune), selected = false, onClick = onTune, leadingIcon = Icons.Filled.Tune)
    }
}

/** Shown in place of the rows when the profile skipped the picker or cleared every choice. */
@Composable
fun ForYouInvitePhone(onTune: () -> Unit) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge).fillMaxWidth()
            .background(colors.surface1, VortXShapes.card)
            .clickable(role = Role.Button, onClick = onTune)
            .padding(VortXTheme.spacing.md),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.FavoriteBorder, contentDescription = null, tint = colors.accentBright)
        Column(modifier = Modifier.weight(1f)) {
            Text(stringResource(R.string.for_you_invite_title), style = VortXTheme.type.cardTitle)
            Text(stringResource(R.string.for_you_invite_body), style = VortXTheme.type.label.copy(color = colors.textSecondary))
        }
    }
}

/** Full-screen host for the interests picker. Back is "not now" on the first run, Cancel when editing. */
@Composable
fun ForYouPickerDialog(initial: ForYouInterests?, firstRun: Boolean, chip: ForYouChip, edge: Dp, onDismiss: () -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas).statusBarsPadding()) {
            ForYouInterestsPicker(initial, firstRun, chip, edge, onDismiss)
        }
    }
}
