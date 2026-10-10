package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.BuildConfig
import com.vortx.android.VortXApplication
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.ProfileSelectionRequest
import com.vortx.android.profile.UserProfile
import com.vortx.android.profile.captureProfileSelection
import com.vortx.android.ui.profilepicker.ProfilePickerCinematicBackdrop
import com.vortx.android.ui.profilepicker.ProfilePickerLayoutPolicy
import com.vortx.android.ui.profilepicker.rememberProfilePickerLifecycleActive
import com.vortx.android.ui.profilepicker.rememberProfilePickerMovie
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.rememberReducedMotion
import com.vortx.android.ui.viewmodel.NativeStreamingAccountViewModel
import kotlinx.coroutines.CancellationException

/// The cold-launch "Who's watching?" picker (ACC-3), the Android port of Apple `ProfilePickerView` shown as
/// a launch `fullScreenCover` (`app/SourcesShared/ProfilesView.swift`). Gated by the caller on
/// [ProfileStore.needsPicker] (more than one profile, or a pending account handoff), so it appears once per
/// cold start and remains mounted until the host verifies a cross-account selection.
///
/// The public Cinemeta artwork is deliberately independent of [ProfileStore]: it is a bounded Family-movie
/// preview and never reads the active viewer's history, add-ons, or account. Selecting a profile remains the
/// store's responsibility; this screen keeps the picker open when selection/admission fails and lets
/// CancellationException propagate to the caller. Every PIN-bearing profile, including the active profile,
/// passes through the gate before selection or editing.
@Composable
fun WhosWatchingScreen(
    onDone: () -> Unit,
    onSelected: (ProfileSelectionRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val store = ProfileStore.sharedOrNull()
    if (store == null) {
        LaunchedEffect(store) { onDone() }
        return
    }
    if (store.profiles.size <= 1 && !store.selectionPending) {
        LaunchedEffect(store) { onDone() }
        return
    }

    // ProfileStore owns plain roster fields for the comparison path and publishes active-profile changes for
    // native projection. Read the roster/active id on every recomposition; never freeze a launch-time copy.
    val activeProjection by store.activeProfile.collectAsState()
    val roster = store.profiles
    val activeId = activeProjection?.id ?: store.activeID
    // The native picker is still a ProfileStore surface, but its selection request must carry a live native
    // admission witness. Keep this model scoped to the picker so the host can consume the request without
    // borrowing an optional owner/session from the Settings screen.
    val nativeModel: NativeStreamingAccountViewModel? = if (BuildConfig.NATIVE_ENGINE_ENABLED) {
        val app = LocalContext.current.applicationContext as? VortXApplication
        val accounts = remember(app) { runCatching { app?.nativeStreamingAccounts() }.getOrNull() }
        if (accounts == null) null else viewModel(
            key = "profile-picker-selection",
            factory = NativeStreamingAccountViewModel.Creator(accounts),
        )
    } else null
    DisposableEffect(nativeModel) { onDispose { nativeModel?.close() } }
    val lifecycleActive = rememberProfilePickerLifecycleActive()
    val reducedMotion = rememberReducedMotion()
    var pinTarget by remember { mutableStateOf<PickerPinRequest?>(null) }
    var editorRequest by remember { mutableStateOf<PickerEditorRequest?>(null) }
    var pickerError by remember { mutableStateOf<String?>(null) }
    var rosterRevision by remember { mutableStateOf(0) }
    @Suppress("UNUSED_VARIABLE") val rosterRedraw = rosterRevision

    fun requestPin(profile: UserProfile, purpose: PickerPinPurpose): PickerPinRequest =
        ContinueWatchingOwnerGate.serialized { revision ->
            PickerPinRequest(
                profile = profile,
                purpose = purpose,
                roster = store.profiles,
                ownerRevision = revision,
            )
        }

    fun choose(profile: UserProfile, expected: PickerPinRequest? = null) {
        // A PIN gate may suspend this callback while sync/editor work replaces the live list. ProfileStore's
        // selection is serialized under the same owner gate, so the delayed path carries and rechecks the
        // exact list/profile witness before entering the store; an ABA replacement is a retry, never an
        // implicit admission.
        val outcome = try {
            ContinueWatchingOwnerGate.serialized { revision ->
                if (expected != null) {
                    check(revision == expected.ownerRevision)
                    check(store.profiles === expected.roster)
                    val current = store.profiles.firstOrNull { it.id == expected.profile.id }
                    check(current === expected.profile && current == expected.profile)
                } else {
                    check(store.profiles === roster)
                }
                val current = store.profiles.firstOrNull { it.id == profile.id }
                check(current === profile && current == profile)
                store.select(profile)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Native publication/admission errors are not a successful selection. Leave the launch picker
            // mounted so the viewer can retry or choose another profile.
            pickerError = "Couldn't open this profile. Tap it to try again."
            return
        }
        // The host owns account-session handoff and dismissal. Always report the witness captured from the
        // same selection transaction so a legacy SwitchAccount token or NeedsSignIn state cannot be replaced
        // by a synthetic picker message or an ABA-prone roster re-read.
        val request = try {
            val nativeAdmission = if (BuildConfig.NATIVE_ENGINE_ENABLED) {
                val selected = checkNotNull(store.active) { "Choose the profile again." }
                val captured = checkNotNull(nativeModel?.captureSelection(selected)) { "Choose the profile again." }
                { nativeModel?.commitEditor(captured) {} == true }
            } else null
            captureProfileSelection(store, profile, outcome, nativeAdmission = nativeAdmission)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            pickerError = "This profile changed before its account session was ready. Try again."
            return
        }
        onSelected(request)
    }

    fun openEditor(profile: UserProfile, isNew: Boolean) {
        pickerError = null
        editorRequest = PickerEditorRequest(profile, isNew)
    }

    fun openActiveEditor() {
        val active = store.profiles.firstOrNull { it.id == store.activeID }
        if (active == null) {
            pickerError = "The active profile is unavailable. Try again."
            return
        }
        if (active.hasPin) {
            pinTarget = requestPin(active, PickerPinPurpose.Edit)
        } else {
            openEditor(active, isNew = false)
        }
    }

    val editing = editorRequest
    if (editing != null) {
        ProfilePickerEditorRoute(
            store = store,
            original = editing.profile,
            isNew = editing.isNew,
            onDone = { editorRequest = null; rosterRevision++ },
            onCancel = { editorRequest = null },
            modifier = modifier,
        )
        return
    }

    val artworkVisible = lifecycleActive && pinTarget == null
    val movie = rememberProfilePickerMovie(visible = artworkVisible, reducedMotion = reducedMotion)

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val isPhone = LocalConfiguration.current.smallestScreenWidthDp < 600
        val largeText = androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.25f
        val layout = remember(maxWidth, largeText, isPhone) {
            ProfilePickerLayoutPolicy(widthDp = maxWidth.value, largeText = largeText, isPhone = isPhone)
        }
        ProfilePickerCinematicBackdrop(movie = movie, reducedMotion = reducedMotion, modifier = Modifier.fillMaxSize())

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = layout.horizontalInsetDp.dp)
                .height(maxHeight),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Top,
        ) {
            if (layout.isPhone) {
                // Preserve Apple's established phone composition: the picker sits lower over the readable
                // bottom fade, while tablet/desktop surfaces use true centered populated rows.
                Spacer(Modifier.height(maxOf(40.dp, maxHeight * 0.34f)))
            } else {
                Spacer(Modifier.weight(1f))
            }
            movie?.let {
                Text(
                    text = it.name,
                    style = VortXTheme.type.label.copy(color = Color.White.copy(alpha = 0.88f)),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            }
            Text(
                text = "Who's watching?",
                style = (if (layout.isWide) VortXTheme.type.hero else VortXTheme.type.screenTitle)
                    .copy(color = Color.White),
                textAlign = TextAlign.Center,
            )
            val tiles = buildList<PhonePickerTile> {
                roster.forEach { add(PhonePickerTile.Profile(it)) }
                add(PhonePickerTile.Action("add", "Add"))
                add(PhonePickerTile.Action("edit", "Edit"))
            }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 24.dp, bottom = 20.dp),
                verticalArrangement = Arrangement.spacedBy(layout.spacingDp.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                layout.rows(tiles.size).forEach { row ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(
                            layout.spacingDp.dp,
                            Alignment.CenterHorizontally,
                        ),
                        verticalAlignment = Alignment.Top,
                    ) {
                        row.forEach { index ->
                            when (val tile = tiles[index]) {
                                is PhonePickerTile.Profile -> {
                                    val profile = tile.profile
                                    ProfileChoice(
                                        profile = profile,
                                        isActive = profile.id == activeId,
                                        sideDp = layout.avatarSideDp,
                                        onClick = {
                                            if (profile.hasPin) {
                                                pinTarget = requestPin(profile, PickerPinPurpose.Select)
                                            } else choose(profile)
                                        },
                                    )
                                }
                                is PhonePickerTile.Action -> ProfilePickerActionTile(
                                    action = tile,
                                    sideDp = layout.avatarSideDp,
                                    onClick = {
                                        if (tile.key == "add") {
                                            openEditor(
                                                UserProfile(
                                                    name = "",
                                                    avatar = "🎬",
                                                    accentID = store.active?.accentID ?: "ember",
                                                ),
                                                isNew = true,
                                            )
                                        } else {
                                            openActiveEditor()
                                        }
                                    },
                                )
                            }
                        }
                    }
                }
            }
            pickerError?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.label.copy(color = Color.White),
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color.Black.copy(alpha = 0.58f))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
            if (!layout.isPhone) Spacer(Modifier.weight(1f))
        }

        pinTarget?.let { target ->
            PinGate(
                profile = target.profile,
                onUnlock = {
                    pinTarget = null
                    if (target.purpose == PickerPinPurpose.Edit) {
                        val current = ContinueWatchingOwnerGate.serialized { revision ->
                            if (revision != target.ownerRevision || store.profiles !== target.roster ||
                                store.activeID != target.profile.id) null
                            else store.profiles.firstOrNull { it.id == target.profile.id }
                                ?.takeIf { it === target.profile && it == target.profile }
                        }
                        if (current == null) {
                            pickerError = "The profile changed. Open it again before editing."
                        }
                        else openEditor(current, isNew = false)
                    } else choose(target.profile, target)
                },
                onCancel = { pinTarget = null },
            )
        }
    }
}

private sealed interface PhonePickerTile {
    data class Profile(val profile: UserProfile) : PhonePickerTile
    data class Action(val key: String, val label: String) : PhonePickerTile
}

private enum class PickerPinPurpose { Select, Edit }

private data class PickerPinRequest(
    val profile: UserProfile,
    val purpose: PickerPinPurpose,
    val roster: List<UserProfile>,
    val ownerRevision: Long,
)

private data class PickerEditorRequest(val profile: UserProfile, val isNew: Boolean)

@Composable
private fun ProfilePickerActionTile(
    action: PhonePickerTile.Action,
    sideDp: Float,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    val shape = RoundedCornerShape((sideDp * 0.23f).dp)
    Column(
        modifier = Modifier
            .width(sideDp.dp)
            .clip(shape)
            .clickable(role = Role.Button, onClick = onClick)
            .testTag("profile-picker-${action.key}")
            .padding(bottom = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(sideDp.dp)
                .clip(shape)
                .background(Color.White.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (action.key == "add") VortXIcons.add else VortXIcons.edit,
                contentDescription = action.label,
                tint = colors.textSecondary,
                modifier = Modifier.size((sideDp * 0.36f).dp),
            )
        }
        Text(
            text = action.label,
            style = VortXTheme.type.cardTitle.copy(color = Color.White),
            textAlign = TextAlign.Center,
            maxLines = 2,
        )
    }
}

/// One responsive rounded profile tile. Its avatar face is intentionally a rounded rectangle rather than a
/// circle, matching Apple's cinematic picker while retaining a large touch target on compact windows.
@Composable
private fun ProfileChoice(
    profile: UserProfile,
    isActive: Boolean,
    sideDp: Float,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    val accent = VortXAccents.byId(profile.accentID).base
    val shape = RoundedCornerShape((sideDp * 0.23f).dp)
    Column(
        modifier = Modifier
            .width(sideDp.dp)
            .clip(shape)
            .clickable(role = Role.Button, onClick = onClick)
            .testTag("profile-picker-${profile.id}")
            .padding(bottom = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(sideDp.dp)
                .clip(shape)
                .background(Brush.linearGradient(listOf(accent, accent.copy(alpha = 0.48f)))),
            contentAlignment = Alignment.Center,
        ) {
            Text(profile.avatar, style = VortXTheme.type.hero)
            when {
                profile.hasPin -> PickerBadge(VortXIcons.lock, "Locked", colors.surface1, colors.textSecondary)
                isActive -> PickerBadge(VortXIcons.checkmarkCircle, "Active profile", Color.Black.copy(alpha = 0.72f), colors.accentBright)
            }
        }
        Text(
            text = profile.name.ifBlank { "Profile" },
            style = VortXTheme.type.cardTitle.copy(
                color = if (isActive) Color.White else Color.White.copy(alpha = 0.82f),
                fontWeight = FontWeight.SemiBold,
            ),
            textAlign = TextAlign.Center,
            maxLines = 2,
        )
        if (profile.isKids) {
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.accentSoft)
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            ) {
                Text("Kids", style = VortXTheme.type.eyebrow.copy(color = colors.accentBright))
            }
        }
    }
}

@Composable
private fun PickerBadge(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    background: Color,
    tint: Color,
) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .clip(CircleShape)
            .background(background)
            .padding(6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = description, tint = tint, modifier = Modifier.fillMaxSize())
    }
}

/// The 4-digit gate for switching into a locked profile from the launch picker. The salted hash stays in
/// [UserProfile]; this overlay only owns transient input and never persists a PIN.
@Composable
private fun PinGate(profile: UserProfile, onUnlock: () -> Unit, onCancel: () -> Unit) {
    val colors = VortXTheme.colors
    var input by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.78f))
            .clickable(role = Role.Button, onClick = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .background(colors.surface1)
                .clickable(onClick = {}) // consume panel taps so they cannot bubble to the outside cancel scrim
                .padding(VortXTheme.spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Enter PIN for ${profile.name}", style = VortXTheme.type.sectionTitle)
            OutlinedTextField(
                value = input,
                onValueChange = { input = it.filter(Char::isDigit).take(4); wrong = false },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                placeholder = { Text("PIN", style = VortXTheme.type.body) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    unfocusedBorderColor = colors.hairline,
                    cursorColor = colors.accent,
                ),
            )
            if (wrong) Text("Wrong PIN", style = VortXTheme.type.label.copy(color = colors.danger))
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                GateButton(
                    label = "Unlock",
                    enabled = input.length == 4,
                    prominent = true,
                    onClick = { if (profile.pinMatches(input)) onUnlock() else wrong = true },
                    modifier = Modifier.weight(1f),
                )
                GateButton(
                    label = "Cancel",
                    enabled = true,
                    prominent = false,
                    onClick = onCancel,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun GateButton(
    label: String,
    enabled: Boolean,
    prominent: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    val container = when {
        !enabled -> colors.surface2
        prominent -> colors.accent
        else -> colors.surface3
    }
    val labelColor = when {
        !enabled -> colors.textTertiary
        prominent -> colors.onAccent
        else -> colors.textPrimary
    }
    Box(
        modifier = modifier
            .clip(CircleShape)
            .background(container)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(vertical = VortXTheme.spacing.sm, horizontal = VortXTheme.spacing.lg),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = VortXTheme.type.body.copy(color = labelColor, fontWeight = FontWeight.SemiBold))
    }
}
