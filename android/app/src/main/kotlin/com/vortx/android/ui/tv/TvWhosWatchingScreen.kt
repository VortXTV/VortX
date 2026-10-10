package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.ProfileSelectionRequest
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.profilepicker.ProfilePickerCinematicBackdrop
import com.vortx.android.ui.profilepicker.ProfilePickerLayoutPolicy
import com.vortx.android.ui.profilepicker.rememberProfilePickerLifecycleActive
import com.vortx.android.ui.profilepicker.rememberProfilePickerMovie
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.rememberReducedMotion
import kotlinx.coroutines.CancellationException

/// The 10-foot "Who's watching?" launch gate: the couch analogue of the phone
/// [com.vortx.android.ui.screens.WhosWatchingScreen], shown once per cold launch when the device holds more
/// than one profile. It drives the EXACT SAME [ProfileStore] the phone gate drives, so a couch pick and a
/// phone pick move the same active-profile state, apply the same theme/filters, and swap in the same private
/// watch overlay -- the account library is never touched (the never-poison split lives inside the store).
///
/// Gating mirrors the phone and Apple TV exactly: [ProfileStore.needsPicker] is true for a real roster choice
/// or an account handoff still awaiting host verification. `pickedThisLaunch` is a transient in-memory flag
/// that resets every cold start; a pending handoff deliberately keeps the picker mounted even when only one
/// profile remains. This screen is fail-soft: with no gateway or no pending choice it dismisses itself.
///
/// Every PIN-protected profile, including the already-active profile when Back is used, prompts for its PIN
/// through a D-pad numeric keypad before selection (a TV has no reliable soft keyboard), so a Kids remote
/// cannot bypass a locked profile.
/// [UserProfile.pinMatches] does the check, so the salted hash never leaves the store.
///
/// Add and Edit use the same native capture/commit admission and editor as TV Settings.
@Composable
fun TvWhosWatching(
    onDone: () -> Unit,
    onSelected: (ProfileSelectionRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val gateway = rememberTvProfileGateway()
    if (gateway == null) {
        LaunchedEffect(Unit) { onDone() }
        return
    }
    val snapshot = gateway.read()
    if (snapshot.profiles.size <= 1 && !snapshot.selectionPending) {
        LaunchedEffect(Unit) { onDone() }
        return
    }
    TvProfilePicker(gateway, onDone, onSelected, modifier)
}

@Composable
internal fun TvProfilePicker(
    gateway: TvProfileGateway,
    onDone: () -> Unit,
    onSelected: (ProfileSelectionRequest) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    var refresh by remember { mutableStateOf(0) }
    @Suppress("UNUSED_VARIABLE") val redraw = refresh
    val roster = gateway.read().profiles
    val activeId = gateway.read().activeID
    var pinTarget by remember { mutableStateOf<TvPendingPinAction?>(null) }
    var managementRequest by remember { mutableStateOf<TvManagementRequest?>(null) }
    var restore by remember { mutableStateOf<String?>(activeId) }
    var pickerError by remember { mutableStateOf<String?>(null) }
    val focus = remember { mutableMapOf<String, FocusRequester>() }
    fun requester(key: String) = focus.getOrPut(key) { FocusRequester() }
    fun commit(profile: UserProfile, captured: TvProfileGateway.Admission) {
        val result = try {
            gateway.select(profile, captured)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            pinTarget = null
            pickerError = "Couldn't open this profile. Tap it to try again."
            refresh++
            return
        }
        result.exceptionOrNull()?.let { failure ->
            if (failure is CancellationException) throw failure
        }
        if (result.isSuccess) {
            pinTarget = null
            pickerError = null
            // The host owns account-session handoff and dismissal. The gateway returns the exact
            // ProfileStore outcome plus its selection witness; do not downgrade it to SameAccount.
            onSelected(checkNotNull(result.getOrNull()))
        } else {
            pinTarget = null
            pickerError = "Couldn't open this profile. Try again."
            refresh++
        }
    }
    fun choose(profile: UserProfile) {
        restore = profile.id
        val captured = gateway.capture(profile, selection = true)
        if (captured == null) {
            pickerError = "The profile changed. Open it again before switching."
        } else if (profile.hasPin) {
            pinTarget = TvPendingPinAction.Select(profile, captured)
        } else {
            commit(profile, captured)
        }
    }
    fun openEditAfterUnlock(expected: UserProfile, admission: TvProfileGateway.Admission) {
        // Unlocking proves the PIN for the pre-gate snapshot only. First validate the captured no-op
        // selection admission under the gateway's owner fence; a same-value roster/account ABA must not
        // borrow the old unlock. This commit has an empty action and never selects or mutates a profile.
        if (!admission.commit { }) {
            pickerError = "The active profile changed. Open Edit again."
            restore = "edit"
            refresh++
            return
        }
        // Re-read both roster and active binding before opening the editor so a delete/replace cannot turn
        // this into an ABA edit even after the admission has been validated.
        val latest = gateway.read()
        val current = latest.profiles.firstOrNull { it.id == expected.id }
        if (current != expected || latest.activeID != expected.id) {
            pickerError = "The active profile changed. Open Edit again."
            restore = "edit"
            refresh++
            return
        }
        if (gateway.capture(current, adding = false) == null) {
            pickerError = "The profile changed. Open Edit again before editing."
            restore = "edit"
            refresh++
            return
        }
        managementRequest = TvManagementRequest.Edit(current.id)
        restore = "edit"
    }
    fun requestManagement(action: TvPickerTile.Action) {
        if (action.key == "add") {
            restore = "add"
            managementRequest = TvManagementRequest.Add
            return
        }
        val latest = gateway.read()
        val active = latest.profiles.firstOrNull { it.id == latest.activeID }
        if (active == null) {
            pickerError = "The active profile is unavailable. Try again."
            refresh++
            return
        }
        restore = "edit"
        val admission = gateway.capture(active, selection = true)
        if (admission == null) {
            pickerError = "The active profile changed. Open Edit again."
            refresh++
            return
        }
        if (active.hasPin) {
            pinTarget = TvPendingPinAction.Edit(active, admission)
        } else {
            openEditAfterUnlock(active, admission)
        }
    }
    BackHandler {
        roster.find { it.id == activeId }?.let { profile ->
            val captured = gateway.capture(profile, selection = true)
            if (captured == null) {
                pickerError = "The profile changed. Open it again before switching."
            } else if (profile.hasPin) {
                restore = profile.id
                pinTarget = TvPendingPinAction.Select(profile, captured)
            } else {
                commit(profile, captured)
            }
        }
    }
    managementRequest?.let { request ->
        TvProfileManagement(
            gateway,
            onBack = { managementRequest = null; restore = request.restoreKey; refresh++ },
            modifier = modifier,
            startAdding = request is TvManagementRequest.Add,
            startEditing = request is TvManagementRequest.Edit,
            returnAfterEditor = true,
        )
        return
    }

    val lifecycleActive = rememberProfilePickerLifecycleActive()
    val reducedMotion = rememberReducedMotion()
    val artworkVisible = lifecycleActive && pinTarget == null
    val movie = rememberProfilePickerMovie(visible = artworkVisible, reducedMotion = reducedMotion)

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val largeText = androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.25f
        val layout = remember(maxWidth, largeText) {
            ProfilePickerLayoutPolicy(widthDp = maxWidth.value, largeText = largeText, isTv = true)
        }
        ProfilePickerCinematicBackdrop(movie = movie, reducedMotion = reducedMotion, modifier = Modifier.fillMaxSize())
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = TvDimens.edge).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = movie?.name ?: "Who's watching?",
                style = VortXTheme.type.hero.copy(color = Color.White),
                textAlign = TextAlign.Center,
            )
            Text(
                text = "Who's watching?",
                style = VortXTheme.type.sectionTitle.copy(color = Color.White),
                textAlign = TextAlign.Center,
            )
            val tiles = buildList<TvPickerTile> {
                roster.forEach { add(TvPickerTile.Profile(it)) }
                add(TvPickerTile.Action("add", "Add profile"))
                add(TvPickerTile.Action("edit", "Edit active profile"))
            }
            Column(
                modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(layout.spacingDp.dp),
            ) {
                layout.rows(tiles.size).forEach { row ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(layout.spacingDp.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.Top,
                    ) {
                        row.forEach { index ->
                            when (val tile = tiles[index]) {
                                is TvPickerTile.Profile -> TvWhosWatchingTile(
                                    profile = tile.profile,
                                    isActive = tile.profile.id == activeId,
                                    tileWidthDp = layout.tileWidthDp,
                                    avatarSideDp = layout.avatarSideDp,
                                    focusRequester = requester(tile.profile.id),
                                    onClick = { choose(tile.profile) },
                                )
                                is TvPickerTile.Action -> TvPickerActionTile(
                                    action = tile,
                                    tileWidthDp = layout.tileWidthDp,
                                    avatarSideDp = layout.avatarSideDp,
                                    focusRequester = requester(tile.key),
                                    onClick = { requestManagement(tile) },
                                )
                            }
                        }
                    }
                }
            }
            pickerError?.let { Text(it, style = VortXTheme.type.label.copy(color = Color.White), textAlign = TextAlign.Center) }
        }

        pinTarget?.let { pending ->
            val target = when (pending) {
                is TvPendingPinAction.Select -> pending.profile
                is TvPendingPinAction.Edit -> pending.profile
            }
            TvWhosWatchingPinGate(
                profile = target,
                onUnlock = {
                    pinTarget = null
                    when (pending) {
                        is TvPendingPinAction.Select -> commit(pending.profile, pending.admission)
                        is TvPendingPinAction.Edit -> openEditAfterUnlock(pending.profile, pending.admission)
                    }
                },
                onCancel = { pinTarget = null; refresh++ },
            )
        }
    }

    LaunchedEffect(restore, refresh, pinTarget) {
        if (pinTarget == null) {
            withFrameNanos { }
            restore?.let { runCatching { requester(it).requestFocus() } }
        }
    }
}

private sealed interface TvPickerTile {
    data class Profile(val profile: UserProfile) : TvPickerTile
    data class Action(val key: String, val label: String) : TvPickerTile
}

private sealed interface TvPendingPinAction {
    data class Select(val profile: UserProfile, val admission: TvProfileGateway.Admission) : TvPendingPinAction
    data class Edit(val profile: UserProfile, val admission: TvProfileGateway.Admission) : TvPendingPinAction
}

private sealed interface TvManagementRequest {
    val restoreKey: String

    data object Add : TvManagementRequest {
        override val restoreKey: String = "add"
    }

    data class Edit(val profileId: String) : TvManagementRequest {
        override val restoreKey: String = "edit"
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
    tileWidthDp: Float,
    avatarSideDp: Float,
    onClick: () -> Unit,
    focusRequester: FocusRequester?,
) {
    val colors = VortXTheme.colors
    val accent = VortXAccents.byId(profile.accentID).base
    Surface(
        onClick = onClick,
        modifier = Modifier
            .width(tileWidthDp.dp)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .testTag("tv-picker-${profile.id}"),
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
                        .size(avatarSideDp.dp)
                        .clip(VortXShapes.card)
                        .background(
                            androidx.compose.ui.graphics.Brush.linearGradient(
                                listOf(accent, accent.copy(alpha = if (isActive) 0.72f else 0.48f)),
                            ),
                        ),
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

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvPickerActionTile(
    action: TvPickerTile.Action,
    tileWidthDp: Float,
    avatarSideDp: Float,
    focusRequester: FocusRequester?,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier
            .width(tileWidthDp.dp)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .testTag("tv-picker-${action.key}"),
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
            Box(
                modifier = Modifier
                    .size(avatarSideDp.dp)
                    .clip(VortXShapes.card)
                    .background(colors.surface2),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (action.key == "add") VortXIcons.add else VortXIcons.edit,
                    contentDescription = action.label,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(avatarSideDp.dp * 0.36f),
                )
            }
            Text(
                action.label,
                style = VortXTheme.type.cardTitle,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
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
