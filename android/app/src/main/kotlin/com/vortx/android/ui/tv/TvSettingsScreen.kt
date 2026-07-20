package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
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
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// TV Settings: a focusable 10-foot list surfacing the couch-relevant toggles PLUS the "Who's watching?"
/// profile switcher. Every playback control writes through the EXACT SAME store the phone Settings and the
/// player read -- [AudioOutputMode] (`stremiox.audioOutputMode`), [PerformanceMode] (`stremiox.performanceMode`),
/// [AutoAddLibrarySetting] (`stremiox.autoAddLibrary`) -- so a change from the couch and one on the phone are
/// the SAME value in the shared `vortx_settings` SharedPreferences. There are no TV-only settings keys.
///
/// PROFILE SWITCHING (this round): the roster is now focusable and switchable from the couch. Tapping a
/// profile calls [ProfileStore.select], which applies its theme/filters, fires the engine reload +
/// Home-rebuild seams, and swaps in that profile's private watch overlay -- the account library is never
/// touched (`EngineStremioRepository.overlayProfiles()` gates every watch path: the never-poison split). A
/// PIN-gated profile prompts for its PIN through a 10-foot numeric keypad before switching, so a Kids profile
/// cannot walk into a locked parent profile from the remote. [ProfileStore] exposes plain main-thread fields
/// (Apple's `@Published` analogue, no Flow), so this screen bumps a local counter after a switch to re-read
/// `profiles` / `activeID`.
///
/// SCOPE, honestly: this ships the primary 10-foot toggles a viewer changes from the couch plus profile
/// SWITCHING. Creating / renaming / deleting a profile stays on the phone/tablet app for now (text entry is a
/// touch job); the deep phone-only surfaces (Account sign-in, Add-ons, Integrations, Media servers, subtitle
/// styling, Sources ranking, Downloads, Library transfer) are likewise named at the foot of the list rather
/// than reproduced. Binding a profile to its own separate account is not wired on Android yet, so a
/// [ProfileStore.select] returning `SwitchAccount` / `NeedsSignIn` is surfaced as a note.
@Composable
fun TvSettingsScreen(modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext

    // Seed each control from its store once; write through on every change. There is no reactive prefs stream
    // in these modules and none is needed -- the values are read at player load, so a write-through keeps the
    // UI and the engine in step, exactly as the phone Playback screen does.
    var audioMode by remember { mutableStateOf(AudioOutputMode.current(appContext)) }
    var performance by remember { mutableStateOf(PerformanceMode.currentOverride(appContext)) }
    var autoAdd by remember { mutableStateOf(AutoAddLibrarySetting.isEnabled(appContext)) }

    val store = ProfileStore.sharedOrNull()
    // Bumped after a switch to force a fresh read of the plain (non-observable) store fields.
    var refresh by remember { mutableStateOf(0) }
    val roster = remember(refresh) { store?.profiles ?: emptyList() }
    val activeId = remember(refresh) { store?.activeID }
    var pinTarget by remember { mutableStateOf<UserProfile?>(null) }
    var status by remember { mutableStateOf<String?>(null) }

    fun commitSwitch(profile: UserProfile) {
        if (store == null) return
        status = null
        when (store.select(profile)) {
            ProfileStore.SwitchOutcome.SameAccount -> Unit
            is ProfileStore.SwitchOutcome.SwitchAccount ->
                status = "Now watching as ${profile.name}. Per-profile sign-in isn't wired on Android yet, " +
                    "so this profile keeps the current session."
            ProfileStore.SwitchOutcome.NeedsSignIn ->
                status = "Now watching as ${profile.name}. This profile has its own account; per-profile " +
                    "sign-in isn't available on Android yet."
        }
        refresh++
    }

    Box(modifier = modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
        ) {
            item { TvProfileHeader(store?.active) }

            if (roster.isNotEmpty()) {
                item {
                    TvSettingsSection("Who's watching") {
                        roster.forEach { profile ->
                            TvProfileRow(
                                profile = profile,
                                isActive = profile.id == activeId,
                                onClick = {
                                    when {
                                        profile.id == activeId -> Unit          // already active
                                        profile.hasPin -> pinTarget = profile    // gate the switch on the PIN
                                        else -> commitSwitch(profile)
                                    }
                                },
                            )
                        }
                    }
                }
            }

            status?.let { message ->
                item {
                    Text(
                        text = message,
                        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.xs),
                    )
                }
            }

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

        pinTarget?.let { target ->
            TvPinGate(
                profile = target,
                onUnlock = { pinTarget = null; commitSwitch(target) },
                onCancel = { pinTarget = null },
            )
        }
    }
}

/// The active profile, shown large above the switcher (avatar + name + a Kids marker), so "who is watching"
/// is legible at ten feet and the Kids badge confirms the content guard is engaged.
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

/// One focusable profile in the switcher, the tv-Surface 10-foot analogue of the phone profile row: an
/// accent disc with the avatar (its [UserProfile.accentID] color), the name with a Kids badge, and a trailing
/// check (active) or lock (PIN-gated). The whole row is the D-pad target.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvProfileRow(profile: UserProfile, isActive: Boolean, onClick: () -> Unit) {
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
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(VortXAccents.byId(profile.accentID).base.copy(alpha = 0.26f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(profile.avatar, style = VortXTheme.type.cardTitle)
            }
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            ) {
                Text(
                    text = profile.name.ifBlank { "Profile" },
                    style = VortXTheme.type.body.copy(
                        color = if (isActive) colors.textPrimary else colors.textSecondary,
                        fontWeight = if (isActive) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (profile.isKids) TvKidsBadge()
            }
            Spacer(Modifier.width(VortXTheme.spacing.sm))
            when {
                isActive -> Icon(VortXIcons.checkmarkCircle, contentDescription = "Active profile", tint = colors.accent)
                profile.hasPin -> Icon(VortXIcons.lock, contentDescription = "Locked", tint = colors.textTertiary)
            }
        }
    }
}

/// A small "Kids" pill beside a Kids profile's name (the explicit badge at 10 feet).
@Composable
private fun TvKidsBadge() {
    val colors = VortXTheme.colors
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(colors.accentSoft)
            .padding(horizontal = VortXTheme.spacing.xs, vertical = 2.dp),
    ) {
        Text("Kids", style = VortXTheme.type.eyebrow.copy(color = colors.accent))
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

/// A 10-foot PIN gate: a dimmed scrim over a panel with the entered digits and a focusable numeric keypad,
/// the couch analogue of the phone `PinGateOverlay`. A TV has no reliable soft keyboard, so entry is a grid
/// of D-pad-focusable digit keys. [UserProfile.pinMatches] does the check, so the salted hash never leaves the
/// store. Unlock only enables at 4 digits.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvPinGate(profile: UserProfile, onUnlock: () -> Unit, onCancel: () -> Unit) {
    val colors = VortXTheme.colors
    var input by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    Box(
        modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(24.dp))
                .background(colors.surface1)
                .padding(VortXTheme.spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Enter PIN for ${profile.name}", style = VortXTheme.type.sectionTitle)
            Text(
                text = if (input.isEmpty()) "----" else "•".repeat(input.length).padEnd(4, '-'),
                style = VortXTheme.type.hero.copy(color = colors.textPrimary),
            )
            if (wrong) Text("Wrong PIN", style = VortXTheme.type.label.copy(color = colors.danger))
            // 1-9 in a 3x3, then Delete / 0 / Cancel across the bottom.
            val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"))
            rows.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    row.forEach { digit ->
                        TvKeypadKey(label = digit, onClick = {
                            if (input.length < 4) { input += digit; wrong = false }
                        })
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                TvKeypadKey(label = "Del", onClick = { input = input.dropLast(1); wrong = false })
                TvKeypadKey(label = "0", onClick = { if (input.length < 4) { input += "0"; wrong = false } })
                TvKeypadKey(label = "Cancel", onClick = onCancel)
            }
            TvKeypadKey(
                label = "Unlock",
                wide = true,
                enabled = input.length == 4,
                onClick = { if (profile.pinMatches(input)) onUnlock() else wrong = true },
            )
        }
    }
}

/// One focusable keypad key for [TvPinGate]. A disabled key (Unlock before 4 digits) is a dim,
/// non-focusable/inert surface so the D-pad skips it until it becomes usable.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvKeypadKey(label: String, onClick: () -> Unit, enabled: Boolean = true, wide: Boolean = false) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = if (wide) Modifier.fillMaxWidth() else Modifier.size(width = 76.dp, height = 56.dp),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (enabled) colors.surface2 else colors.surface1,
            contentColor = if (enabled) colors.textPrimary else colors.textTertiary,
            focusedContainerColor = colors.accent,
            focusedContentColor = colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Box(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(label, style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold))
        }
    }
}

/// An honest pointer to what is NOT here: the deep settings surfaces that stay on the phone/tablet app for
/// now. Named rather than hidden, so a tester knows where to reach them.
@Composable
private fun TvSettingsFootnote() {
    Text(
        text = "Creating, renaming, and deleting profiles, plus account, add-ons, integrations, media " +
            "servers, subtitle styling, source ranking, and downloads, are managed in the VortX phone and " +
            "tablet app.",
        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
        modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.sm),
    )
}
