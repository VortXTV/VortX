package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// The 10-foot "Who's watching?" launch gate: the couch analogue of the phone
/// [com.vortx.android.ui.screens.WhosWatchingScreen], shown once per cold launch when the device holds more
/// than one profile. It drives the EXACT SAME [ProfileStore] the phone gate drives, so a couch pick and a
/// phone pick move the same active-profile state, apply the same theme/filters, and swap in the same private
/// watch overlay -- the account library is never touched (the never-poison split lives inside the store).
///
/// Gating mirrors the phone and Apple TV exactly: [ProfileStore.needsPicker] is `profiles.size > 1 &&
/// !pickedThisLaunch`, and `pickedThisLaunch` is a transient in-memory flag that resets every cold start, so
/// the picker shows once when there is a real choice and never on a single-profile install. This screen is
/// fail-soft: with no store or a single profile it dismisses itself immediately (the host should only mount it
/// when the gate is owed, but the guard keeps it safe if mounted anyway).
///
/// A PIN-protected profile that is not already active prompts for its PIN through a D-pad numeric keypad before
/// switching (a TV has no reliable soft keyboard), so a Kids remote cannot walk into a locked parent profile.
/// [UserProfile.pinMatches] does the check, so the salted hash never leaves the store.
///
/// Add and Edit use the same native capture/commit admission and editor as TV Settings.
@Composable
fun TvWhosWatching(onDone: () -> Unit, modifier: Modifier = Modifier) {
    val gateway = rememberTvProfileGateway()
    if (gateway == null || gateway.read().profiles.isEmpty()) {
        LaunchedEffect(Unit) { onDone() }
        return
    }
    TvProfilePicker(gateway, onDone, modifier)
}

@Composable
internal fun TvProfilePicker(gateway: TvProfileGateway, onDone: () -> Unit, modifier: Modifier = Modifier) {
    var refresh by remember { mutableStateOf(0) }
    @Suppress("UNUSED_VARIABLE") val redraw = refresh
    val roster = gateway.read().profiles
    val activeId = gateway.read().activeID
    var pinTarget by remember { mutableStateOf<Pair<UserProfile, TvProfileGateway.Admission>?>(null) }
    var manage by remember { mutableStateOf<String?>(null) }
    var restore by remember { mutableStateOf<String?>(activeId) }
    var message by remember { mutableStateOf<String?>(null) }
    val focus = remember { mutableMapOf<String, FocusRequester>() }
    val rowState = rememberLazyListState()
    fun requester(key: String) = focus.getOrPut(key) { FocusRequester() }
    fun commit(profile: UserProfile, captured: TvProfileGateway.Admission) {
        message = gateway.select(profile, captured)
        pinTarget = null
        if (message == null) onDone() else refresh++
    }
    BackHandler {
        roster.find { it.id == activeId }?.let { profile ->
            gateway.capture(profile, selection = true)?.let { commit(profile, it) }
        }
    }
    manage?.let { route ->
        TvProfileManagement(gateway, onBack = { manage = null; restore = route; refresh++ }, modifier = modifier,
            startAdding = route == "add", startEditing = route == "edit", returnAfterEditor = true)
        return
    }

    Box(modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        Column(
            modifier = Modifier.fillMaxSize().padding(TvDimens.edge).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = "Who's watching?",
                style = VortXTheme.type.hero,
                textAlign = TextAlign.Center,
            )
            LazyRow(
                state = rowState,
                horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap, Alignment.CenterHorizontally),
                contentPadding = PaddingValues(horizontal = TvDimens.edge),
                modifier = Modifier.fillMaxWidth(),
            ) {
                itemsIndexed(roster, key = { _, p -> p.id }) { _, profile ->
                    TvWhosWatchingTile(
                        profile = profile,
                        isActive = profile.id == activeId,
                        focusRequester = requester(profile.id),
                        onClick = {
                            restore = profile.id
                            val captured = gateway.capture(profile, selection = true)
                            if (captured == null) message = "The profile changed. Open it again before switching."
                            else if (profile.hasPin && profile.id != activeId) pinTarget = profile to captured
                            else commit(profile, captured)
                        },
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.fillMaxWidth()) {
                TvProfileButton("Add profile", modifier = Modifier.weight(1f).focusRequester(requester("add")).testTag("tv-picker-add"), onClick = { manage = "add" })
                TvProfileButton("Edit active profile", modifier = Modifier.weight(1f).focusRequester(requester("edit")).testTag("tv-picker-edit"), onClick = { manage = "edit" })
            }
            message?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) }
        }

        pinTarget?.let { (target, captured) ->
            TvWhosWatchingPinGate(
                profile = target,
                onUnlock = { commit(target, captured) },
                onCancel = { pinTarget = null; refresh++ },
            )
        }
    }

    LaunchedEffect(restore, refresh, pinTarget) {
        if (pinTarget == null) {
            val index = roster.indexOfFirst { it.id == restore }
            if (index >= 0) rowState.scrollToItem(index)
            withFrameNanos { }
            restore?.let { runCatching { requester(it).requestFocus() } }
        }
    }
}

/// One focusable profile card in the launch grid: an accent disc holding the avatar (its
/// [UserProfile.accentID] color), the name below, a Kids pill, and a corner badge -- a check when active, a
/// lock when PIN-gated. Focus lights the accent ring and scales the card, the 10-foot "where will the D-pad
/// go" signal. Mirrors the phone `ProfileChoice` and the Apple TV `ProfileCardContent`.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvWhosWatchingTile(
    profile: UserProfile,
    isActive: Boolean,
    onClick: () -> Unit,
    focusRequester: FocusRequester?,
) {
    val colors = VortXTheme.colors
    val accent = VortXAccents.byId(profile.accentID).base
    Surface(
        onClick = onClick,
        modifier = Modifier
            .width(200.dp)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface2,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(TvDimens.focusBorder, colors.accentBright),
                shape = VortXShapes.card,
            ),
        ),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = VortXTheme.spacing.lg, horizontal = VortXTheme.spacing.md),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Box(
                    modifier = Modifier
                        .size(120.dp)
                        .clip(CircleShape)
                        .background(accent.copy(alpha = if (isActive) 0.40f else 0.24f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(profile.avatar, style = VortXTheme.type.hero)
                }
                if (profile.hasPin) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .size(34.dp)
                            .clip(CircleShape)
                            .background(colors.surface1),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            VortXIcons.lock,
                            contentDescription = "Locked",
                            tint = colors.textSecondary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                } else if (isActive) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .size(34.dp)
                            .clip(CircleShape)
                            .background(colors.surface1),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            VortXIcons.checkmarkCircle,
                            contentDescription = "Active profile",
                            tint = colors.accent,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
            Text(
                text = profile.name.ifBlank { "Profile" },
                style = VortXTheme.type.cardTitle.copy(
                    color = if (isActive) colors.textPrimary else colors.textSecondary,
                ),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
            if (profile.isKids) {
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(colors.accentSoft)
                        .padding(horizontal = VortXTheme.spacing.sm, vertical = 2.dp),
                ) {
                    Text("Kids", style = VortXTheme.type.eyebrow.copy(color = colors.accent))
                }
            }
        }
    }
}

/// A 10-foot PIN gate for the launch picker: a dimmed scrim over a panel with the entered digits and a
/// D-pad-focusable numeric keypad. A TV has no reliable soft keyboard, so entry is a grid of digit keys.
/// [UserProfile.pinMatches] does the check, so the salted hash never leaves the store. Unlock enables at four
/// digits. Back dismisses the gate and returns focus to its invoking profile. Shared by TV Settings and
/// the launch picker, so both profile paths use the same remote gate.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvWhosWatchingPinGate(profile: UserProfile, onUnlock: () -> Unit, onCancel: () -> Unit) {
    val colors = VortXTheme.colors
    var input by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    val firstKeyFocus = remember { FocusRequester() }
    BackHandler { onCancel() }
    Dialog(onDismissRequest = onCancel) { Box(
        modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(24.dp))
                .background(colors.surface1)
                .padding(VortXTheme.spacing.lg)
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Enter PIN for ${profile.name}", style = VortXTheme.type.sectionTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(
                text = if (input.isEmpty()) "----" else "•".repeat(input.length).padEnd(4, '-'),
                style = VortXTheme.type.hero.copy(color = colors.textPrimary),
            )
            if (wrong) Text("Wrong PIN", style = VortXTheme.type.label.copy(color = colors.danger))
            val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"))
            rows.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    row.forEach { digit ->
                        TvPinKey(label = digit, modifier = if (digit == "1") Modifier.focusRequester(firstKeyFocus) else Modifier, onClick = {
                            if (input.length < 4) { input += digit; wrong = false }
                        })
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                TvPinKey(label = "Del", onClick = { input = input.dropLast(1); wrong = false })
                TvPinKey(label = "0", onClick = { if (input.length < 4) { input += "0"; wrong = false } })
                TvPinKey(label = "Cancel", onClick = onCancel)
            }
            TvPinKey(
                label = "Unlock",
                wide = true,
                enabled = input.length == 4,
                onClick = { if (profile.pinMatches(input)) onUnlock() else wrong = true },
            )
        }
    } }
    LaunchedEffect(Unit) { withFrameNanos { }; runCatching { firstKeyFocus.requestFocus() } }
}

/// One focusable keypad key for [TvWhosWatchingPinGate]. A disabled key (Unlock before four digits) is a dim,
/// inert surface so the D-pad skips it until it becomes usable.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvPinKey(label: String, onClick: () -> Unit, enabled: Boolean = true, wide: Boolean = false, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.then(if (wide) Modifier.fillMaxWidth() else Modifier.size(width = 76.dp, height = 56.dp)),
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
            Text(label, style = VortXTheme.type.body)
        }
    }
}
