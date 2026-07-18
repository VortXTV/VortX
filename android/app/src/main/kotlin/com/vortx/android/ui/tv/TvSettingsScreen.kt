package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.player.AudioOutputMode
import com.vortx.android.player.AutoAddLibrarySetting
import com.vortx.android.player.PerformanceMode
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// TV Settings: a focusable 10-foot list surfacing the couch-relevant toggles. Every control writes through
/// the EXACT SAME store the phone Settings and the player read -- [AudioOutputMode] (`stremiox.audioOutputMode`),
/// [PerformanceMode] (`stremiox.performanceMode`), [AutoAddLibrarySetting] (`stremiox.autoAddLibrary`) -- so a
/// change made from the couch and one made on the phone are the SAME value in the shared `vortx_settings`
/// SharedPreferences. There are no TV-only settings keys; settings parity across surfaces is preserved by
/// reusing the stores rather than restating them.
///
/// SCOPE, honestly: this ships the primary 10-foot toggles the phone Playback screen carries that a viewer
/// actually changes from the couch (audio output, performance, auto-add-to-Library). The deep phone-only
/// surfaces -- Account sign-in, Add-ons, Integrations (Trakt/SIMKL), Media servers, the full subtitle-style
/// editor, per-language track order, streaming cache, skip-provider, Sources ranking/filters, Downloads,
/// Library export/import -- are NOT reproduced here yet and are named as such at the foot of the list.
/// Profile SWITCHING is deferred (the active profile is shown read-only): a switch of an own-account profile
/// needs the account/token flow, which is not a 10-foot control yet. The active profile is still honored
/// everywhere by construction, because every reused ViewModel reads it.
@Composable
fun TvSettingsScreen(modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext

    // Seed each control from its store once; write through on every change. There is no reactive prefs stream
    // in these modules and none is needed -- the values are read at player load, so a write-through keeps the
    // UI and the engine in step, exactly as the phone Playback screen does.
    var audioMode by remember { mutableStateOf(AudioOutputMode.current(appContext)) }
    var performance by remember { mutableStateOf(PerformanceMode.currentOverride(appContext)) }
    var autoAdd by remember { mutableStateOf(AutoAddLibrarySetting.isEnabled(appContext)) }

    val profile = ProfileStore.sharedOrNull()?.active

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
    ) {
        item { TvProfileHeader(profile) }

        item {
            TvSettingsSection("Library") {
                TvToggleRow(
                    label = "Auto-add watched to Library",
                    detail = "Adds a title once about a minute has played. A title you remove by hand stays removed.",
                    checked = autoAdd,
                    onToggle = {
                        val next = !autoAdd
                        autoAdd = next
                        AutoAddLibrarySetting.setEnabled(appContext, next)
                    },
                )
            }
        }

        item {
            TvSettingsSection("Audio output") {
                AudioOutputMode.entries.forEach { mode ->
                    TvOptionRow(
                        label = mode.label,
                        detail = mode.detail,
                        selected = mode == audioMode,
                        onClick = {
                            audioMode = mode
                            AudioOutputMode.setCurrent(appContext, mode)
                        },
                    )
                }
            }
        }

        item {
            TvSettingsSection("Performance") {
                PerformanceMode.Override.entries.forEach { option ->
                    TvOptionRow(
                        label = option.label,
                        detail = null,
                        selected = option == performance,
                        onClick = {
                            performance = option
                            PerformanceMode.setOverride(appContext, option)
                        },
                    )
                }
            }
        }

        item { TvSettingsFootnote() }
    }
}

/// The active profile, shown read-only (avatar + name + a Kids marker). Switching from the couch is a later
/// item; this makes "who is watching" legible now, and the Kids badge confirms the content guard is engaged.
@Composable
private fun TvProfileHeader(profile: UserProfile?) {
    val colors = VortXTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(text = profile?.avatar ?: "🍿", style = VortXTheme.type.hero)
        Spacer(Modifier.width(VortXTheme.spacing.md))
        Column {
            Text(text = profile?.name ?: "VortX", style = VortXTheme.type.sectionTitle)
            Text(
                text = if (profile?.isKids == true) "Kids profile · active" else "Active profile",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
        }
    }
}

/// A titled group: the eyebrow header over a stack of focusable rows. The 10-foot analogue of the phone
/// `SettingsSection`, minus the glass card (the rows carry their own focus surface here).
@Composable
private fun TvSettingsSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(
            text = title.uppercase(),
            style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.textTertiary),
            modifier = Modifier.padding(start = VortXTheme.spacing.xs),
        )
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) { content() }
    }
}

/// One focusable radio option, the tv-Surface 10-foot analogue of the phone `OptionRow`. The [RadioButton]
/// is a pure indicator (onClick = null); the whole row is the target, so the D-pad selects it in one press
/// and a focus ring makes the target unambiguous from the couch. Carries the store's own [detail] copy.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvOptionRow(label: String, detail: String?, selected: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
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
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Column {
                Text(
                    text = label,
                    style = VortXTheme.type.body.copy(
                        color = if (selected) colors.textPrimary else colors.textSecondary,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                )
                if (detail != null) {
                    Text(
                        text = detail,
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/// One focusable on/off row, the tv-Surface 10-foot analogue of the phone `ToggleRow`. The [Switch] is a
/// pure indicator; the row is the target.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvToggleRow(label: String, detail: String?, checked: Boolean, onToggle: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onToggle,
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = label,
                    style = VortXTheme.type.body.copy(
                        color = if (checked) colors.textPrimary else colors.textSecondary,
                        fontWeight = if (checked) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                )
                if (detail != null) {
                    Text(
                        text = detail,
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.width(VortXTheme.spacing.md))
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
}

/// An honest pointer to what is NOT here: the deep settings surfaces that stay on the phone/tablet app for
/// now. Named rather than hidden, so a tester knows where to reach them.
@Composable
private fun TvSettingsFootnote() {
    Text(
        text = "Account, add-ons, integrations, media servers, subtitle styling, source ranking, and " +
            "downloads are managed in the VortX phone and tablet app.",
        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
        modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.sm),
    )
}
