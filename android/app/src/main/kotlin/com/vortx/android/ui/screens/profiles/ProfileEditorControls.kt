package com.vortx.android.ui.screens.profiles

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.screens.SettingsSection
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXTheme
import java.text.BreakIterator

/**
 * The Apple-parity profile-management controls that complete the Android profile EDITOR: a custom-avatar
 * field, a per-profile accent picker, and a per-profile background (OLED) picker. These are the pieces the
 * initial Android editor (`ProfilesScreen.ProfileEditor`) did not yet carry; they port the matching sections
 * of Apple `ProfileEditorView` (`app/SourcesShared/ProfilesView.swift`): its custom-avatar `TextField`, its
 * `ProfileAccentPicker`, and its `ProfileBackgroundPicker`.
 *
 * They live in a NEW file (and package) on purpose: the profile CRUD backing ([com.vortx.android.profile.ProfileStore])
 * and the switcher/editor host ([com.vortx.android.ui.screens.ProfilesScreen]) already exist, so the only
 * hook into the editor is calling these composables and folding `accentID` / `oled` into the saved draft.
 *
 * SAME-KEY: these controls only ever write the roster fields Apple/web already carry, `accentID` and `oled`
 * (`UserProfile`), plus the avatar string. The per-profile accent list is [VortXAccents.curated], value-for-value
 * with Apple `ThemeManager.accents`, so a color picked here reads identically on every surface. No control here
 * touches watch history, the overlay, or any account/library schema.
 *
 * PRESENTATION ONLY: each composable is stateless-with-callbacks. The editor holds the draft and decides when
 * to persist through the store, so the store stays the single source of truth (the same discipline the shared
 * Settings controls in `SettingsControls.kt` follow).
 */

/**
 * Apple's custom-avatar rule (`ProfileEditorView`'s `customAvatar` `onChange`): take the FIRST grapheme of
 * what the user typed and, when it is a letter, show it uppercased; leave an emoji (or anything whose uppercase
 * form is a different length, e.g. `ß` -> `SS`) exactly as typed. Returns null for empty input so the caller
 * leaves the current avatar untouched.
 *
 * [BreakIterator] gives the first user-perceived character (a surrogate-pair emoji, a ZWJ sequence, a letter +
 * combining mark) rather than the first UTF-16 unit, matching Swift's `String.first` (a `Character`). The
 * length guard uses the locale-independent [String.uppercase] so the result is stable across devices.
 */
internal fun normalizeCustomAvatar(input: String): String? {
    if (input.isEmpty()) return null
    val boundaries = BreakIterator.getCharacterInstance()
    boundaries.setText(input)
    val end = boundaries.following(0)
    if (end == BreakIterator.DONE) return null
    val grapheme = input.substring(0, end)
    // A single letter uppercases to the same length; an emoji is unchanged by uppercasing; a letter that
    // EXPANDS (ß -> SS) changes length and is kept as typed. This is Apple's `.count == uppercased().count`.
    return if (grapheme.length == grapheme.uppercase().length) grapheme.uppercase() else grapheme
}

/**
 * "Or type your own" avatar entry: a free-text field (any emoji or a letter) with a live preview disc, the
 * touch port of Apple's custom-avatar row. The field text is hoisted so tapping a grid emoji can clear it
 * (mirroring Apple setting `customAvatar = ""` on a grid pick). Each keystroke maps through
 * [normalizeCustomAvatar]; a non-null result becomes the draft avatar.
 */
@Composable
internal fun ProfileCustomAvatarField(
    text: String,
    currentAvatar: String,
    onTextChange: (String) -> Unit,
    onAvatarPicked: (String) -> Unit,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = { raw ->
                onTextChange(raw)
                normalizeCustomAvatar(raw)?.let(onAvatarPicked)
            },
            singleLine = true,
            placeholder = { Text("Or type your own: any emoji or a letter", style = VortXTheme.type.body) },
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.accent,
                unfocusedBorderColor = colors.hairline,
                cursorColor = colors.accent,
            ),
            modifier = Modifier.weight(1f),
        )
        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(colors.surface2),
            contentAlignment = Alignment.Center,
        ) {
            Text(currentAvatar, style = VortXTheme.type.sectionTitle)
        }
    }
}

/**
 * Per-profile accent picker: the profile's own [com.vortx.android.profile.UserProfile.accentID], the Android
 * port of Apple `ProfileAccentPicker`. Renders the shared [VortXAccents.curated] roster as labeled [Chip]s
 * tinted with each accent, identical to the app-wide Appearance accent picker, so the profile keeps its own
 * color and it reads the same on every surface. Applied live when this is the active profile (the shells
 * derive their accent from `activeProfile.accentID`).
 */
@Composable
internal fun ProfileAccentSection(selectedId: String, onSelect: (String) -> Unit) {
    SettingsSection(
        title = "Accent",
        footer = "This profile's color for selection, focus, progress, and primary actions. It follows the " +
            "profile across your devices.",
    ) {
        FlowRow(
            modifier = Modifier.padding(VortXTheme.spacing.sm),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            VortXAccents.curated.forEach { accent ->
                Chip(
                    label = accent.label,
                    selected = selectedId == accent.id,
                    onClick = { onSelect(accent.id) },
                    modifier = Modifier.heightIn(min = 48.dp),
                    accent = accent.base,
                    accentText = accent.bright,
                )
            }
        }
    }
}

/**
 * Per-profile background picker: the profile's own [com.vortx.android.profile.UserProfile.oled] flag, the
 * Android port of Apple `ProfileBackgroundPicker` (its Warm / OLED Black chip pair). Applied live when this is
 * the active profile (the shells derive `oled` from `activeProfile.oled`).
 */
@Composable
internal fun ProfileBackgroundSection(oled: Boolean, onOled: (Boolean) -> Unit) {
    SettingsSection(
        title = "Background",
        footer = "OLED Black uses true black for the canvas and neutral dark surfaces.",
    ) {
        Row(
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            Chip(label = "Warm", selected = !oled, onClick = { onOled(false) }, modifier = Modifier.heightIn(min = 48.dp))
            Chip(label = "OLED Black", selected = oled, onClick = { onOled(true) }, modifier = Modifier.heightIn(min = 48.dp))
        }
    }
}
