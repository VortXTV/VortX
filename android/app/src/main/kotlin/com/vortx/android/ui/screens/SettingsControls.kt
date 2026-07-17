package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// The shared building blocks for every Settings sub-screen (Playback, Sources).
///
/// These live in ONE file rather than being duplicated per screen for the same reason [Chip] is documented
/// as the single secondary control for the whole app: a settings-only look-alike would be a second visual
/// language, so "selected" would come to mean two different things on two different screens. They are
/// `internal` (not `private`) precisely so a sibling screen reuses them instead of re-deriving them.
///
/// Each is presentation only: it owns no preference and performs no persistence. The calling screen holds
/// the state and writes through to the store, so the store stays the single source of truth.

/// A titled group inside one glass card, with the Apple section footer as explanatory text below it. The
/// eyebrow/footer pairing is the DESIGN-SYSTEM section shape, so this reads as VortX rather than a stock
/// Material preference list.
@Composable
internal fun SettingsSection(
    title: String,
    footer: String?,
    content: @Composable () -> Unit,
) {
    val colors = VortXTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(
            title.uppercase(),
            style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary),
            modifier = Modifier.padding(start = VortXTheme.spacing.xs),
        )
        SurfaceCard {
            Column(
                modifier = Modifier.padding(vertical = VortXTheme.spacing.xs),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                content()
            }
        }
        if (footer != null) {
            Text(
                footer,
                style = VortXTheme.type.label.copy(color = colors.textTertiary),
                modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
            )
        }
    }
}

/// One selectable option carrying Apple's own `label` + `detail` copy. A radio (not a dropdown) because
/// the detail line is the whole point for these settings: "Forces a stereo downmix. Choose this if a
/// soundbar or receiver plays no sound." is the text that actually resolves a support problem.
@Composable
internal fun OptionRow(
    label: String,
    detail: String?,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            // selectable(role = RadioButton) on the ROW with a null-onClick RadioButton, rather than making
            // both the row and the radio clickable: that would expose two separate targets for one choice
            // and make a screen reader announce the option twice. This way the whole row is one radio.
            .selectable(
                selected = selected,
                role = Role.RadioButton,
                onClick = onClick,
            )
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected,
            onClick = null,
            colors = RadioButtonDefaults.colors(
                selectedColor = colors.accent,
                unselectedColor = colors.textTertiary,
            ),
        )
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                label,
                style = VortXTheme.type.body.copy(
                    color = if (selected) colors.textPrimary else colors.textSecondary,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                ),
            )
            if (detail != null) {
                Text(detail, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            }
        }
    }
}

/// A label plus a wrapping run of choice chips. Used where the options are short and self-explanatory
/// (font/size/colour/language/resolution) and a per-option detail line would be noise.
///
/// Renders through the shared [Chip] rather than a local look-alike, for the reason given on this file's
/// header doc.
@Composable
internal fun PickerRow(
    label: String,
    options: List<Pair<String, String>>,
    selectedId: String,
    onSelect: (String) -> Unit,
) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Text(label, style = VortXTheme.type.label.copy(color = colors.textSecondary))
        // Wraps instead of scrolling horizontally: the 16-language list must stay reachable one-handed,
        // and a hidden off-screen chip is a chip nobody picks.
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            options.forEach { (id, optionLabel) ->
                Chip(
                    label = optionLabel,
                    selected = id == selectedId,
                    onClick = { onSelect(id) },
                )
            }
        }
    }
}

/// A labelled on/off switch. The whole row toggles (role = Switch) with a null-onCheckedChange [Switch],
/// for the same one-target/one-announcement reason as [OptionRow].
@Composable
internal fun ToggleRow(
    label: String,
    detail: String?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(
                selected = checked,
                role = Role.Switch,
                onClick = { onCheckedChange(!checked) },
            )
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.fillMaxWidth(0.8f)) {
            Text(
                label,
                style = VortXTheme.type.body.copy(
                    color = if (checked) colors.textPrimary else colors.textSecondary,
                    fontWeight = if (checked) FontWeight.SemiBold else FontWeight.Normal,
                ),
            )
            if (detail != null) {
                Text(detail, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = null,
            colors = SwitchDefaults.colors(
                checkedTrackColor = colors.accent,
                uncheckedTrackColor = colors.surface3,
            ),
        )
    }
}

/// Apple's `Stepper` (iOSSettingsView.swift:1365) has no Material equivalent, so this is the minimum
/// faithful shape: a label with -/+ affordances that disable at the range ends.
@Composable
internal fun StepperRow(
    label: String,
    canDecrease: Boolean,
    canIncrease: Boolean,
    onDecrease: () -> Unit,
    onIncrease: () -> Unit,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = VortXTheme.type.label.copy(color = colors.textSecondary))
        Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            StepperButton(symbol = "-", enabled = canDecrease, onClick = onDecrease, description = "Smaller")
            StepperButton(symbol = "+", enabled = canIncrease, onClick = onIncrease, description = "Larger")
        }
    }
}

@Composable
private fun StepperButton(symbol: String, enabled: Boolean, onClick: () -> Unit, description: String) {
    val colors = VortXTheme.colors
    Box(
        modifier = Modifier
            // VortXShapes.pill, not RoundedCornerShape(percent = 50): Radius.kt documents the 999.dp pill
            // precisely so a capsule stays a capsule at any height.
            .clip(VortXShapes.pill)
            .background(colors.surface3)
            .clickable(enabled = enabled, onClick = onClick, onClickLabel = description)
            .padding(horizontal = VortXTheme.spacing.sm, vertical = 2.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            symbol,
            style = VortXTheme.type.cardTitle.copy(
                color = if (enabled) colors.accent else colors.textTertiary,
            ),
        )
    }
}
