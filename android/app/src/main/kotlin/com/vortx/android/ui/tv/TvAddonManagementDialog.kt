package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/** Same D-pad/soft-keyboard field as TV settings, not a phone-only clickable text control. */
@Composable
internal fun TvAddonUrlField(value: String, onValueChange: (String) -> Unit, enabled: Boolean,
    modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    OutlinedTextField(
        value = value, onValueChange = onValueChange, enabled = enabled,
        label = { Text("Add-on manifest URL") },
        placeholder = { Text("https://…/manifest.json") },
        singleLine = true, modifier = modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = colors.accent,
            unfocusedBorderColor = colors.hairline, cursorColor = colors.accent),
    )
}

/** A confirmation keeps the original target in its caller; Back never runs [onConfirm]. */
@Composable
internal fun TvAddonManagementDialog(
    title: String, description: String, confirmLabel: String, busy: Boolean,
    message: Pair<String, Boolean>?, onConfirm: () -> Unit, onDismiss: () -> Unit,
    url: String? = null, onUrlChange: (String) -> Unit = {}, confirmEnabled: Boolean = true,
) {
    val colors = VortXTheme.colors
    val cancelFocus = remember { FocusRequester() }
    val inputFocus = remember { FocusRequester() }
    Dialog(onDismissRequest = onDismiss) {
        BackHandler(onBack = onDismiss)
        Column(
            modifier = Modifier.width(720.dp).heightIn(max = 560.dp).clip(VortXShapes.control)
                .background(colors.surface1).verticalScroll(rememberScrollState()).padding(VortXTheme.spacing.xl),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text(title, style = VortXTheme.type.sectionTitle)
            Text(description, style = VortXTheme.type.body.copy(color = colors.textSecondary))
            if (url != null) TvAddonUrlField(url, onUrlChange, !busy, Modifier.focusRequester(inputFocus))
            message?.let { (text, failed) ->
                Text(text, style = VortXTheme.type.label.copy(color = if (failed) colors.danger else colors.textSecondary))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
                TvAddonAction("Cancel", onDismiss, Modifier.weight(1f), focusRequester = cancelFocus)
                TvAddonAction(if (busy) "Working…" else confirmLabel, onConfirm, Modifier.weight(1f),
                    enabled = !busy && confirmEnabled)
            }
        }
        LaunchedEffect(Unit) {
            withFrameNanos { }
            runCatching { if (url == null) cancelFocus.requestFocus() else inputFocus.requestFocus() }
        }
    }
}
