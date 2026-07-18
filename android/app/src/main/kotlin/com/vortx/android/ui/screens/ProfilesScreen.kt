package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

/// Settings > Profiles: the "Who's watching?" switcher plus create / rename / delete, the Android port of
/// the Apple `ProfilePickerView` + `ProfileEditorView` (`app/SourcesShared/ProfilesView.swift`).
///
/// WHY THIS SCREEN EXISTS: the whole multi-profile subsystem ([ProfileStore], the per-profile watch overlay,
/// the Kids source guard, per-profile source ranking) was wired end to end but UNREACHABLE — nothing in
/// `ui/` could switch the active profile, so it was permanently stuck on the owner. This is the missing entry
/// point and only that: it calls [ProfileStore.select] / [ProfileStore.add] / [ProfileStore.update] /
/// [ProfileStore.remove] and holds NO profile logic of its own. Every guarantee (owner singleton, union-merge,
/// tombstones, the never-poison overlay split) stays in the store.
///
/// NEVER-POISON: switching to a non-owner profile only moves the active selection + swaps in that profile's
/// private overlay ([ProfileStore.select] -> `overlay.activate`); it never reads or writes the account
/// library (`EngineStremioRepository.overlayProfiles()` gates every watch path). The picker just changes who
/// is active; the engine/library/Home refresh themselves off the switch listener + `onRebuildBoard` seam the
/// store already fires.
///
/// STORE OBSERVABILITY: [ProfileStore] mirrors Apple's `@Published` fields with plain main-thread fields (no
/// Flow), so this screen bumps a local [refresh] counter after every mutation to re-read `profiles` /
/// `activeID` — the same "wrap a non-observable singleton" pattern the rest of `ui/` uses for such stores.
///
/// SCOPE, honestly: a new profile is created as a SHARED profile (its own private watch history, synced
/// through the account). Binding a profile to its OWN separate VortX/Stremio account is deferred — the
/// per-profile token/engine-session switch is not wired on Android yet, so [ProfileStore.select] returning
/// `SwitchAccount` / `NeedsSignIn` (only reachable for an own-account profile synced in from Apple) is
/// surfaced as a note rather than silently half-switching the session.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfilesScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val store = ProfileStore.sharedOrNull()
    if (store == null) {
        // Fail-soft: before ProfileStore.init (or if it failed) there is no roster to manage. Mirror the
        // fail-soft boundary the rest of the app uses rather than crash the Settings surface.
        ProfilesUnavailable(onBack, modifier)
        return
    }

    // Bumped after any store mutation to force a fresh read of the plain (non-observable) store fields.
    var refresh by remember { mutableStateOf(0) }
    val roster = remember(refresh) { store.profiles }
    val activeId = remember(refresh) { store.activeID }

    // The editor overlay (null = closed). Carries the profile being edited and whether it is brand-new; a new
    // draft is minted here so Save can route to add() vs update().
    var editorProfile by remember { mutableStateOf<UserProfile?>(null) }
    var editorIsNew by remember { mutableStateOf(false) }
    // The PIN gate for switching INTO a locked profile (Apple `ProfilePickerView.pick` -> PinGateOverlay).
    var pinTarget by remember { mutableStateOf<UserProfile?>(null) }
    // The last account-switch note, shown inline (see the SCOPE note in the header doc).
    var status by remember { mutableStateOf<String?>(null) }

    fun commitSwitch(profile: UserProfile) {
        status = null
        // select() applies the profile's theme/filters, fires the reload + rebuild seams, and swaps the watch
        // overlay — the account library is never touched. Its outcome tells the account layer what is left.
        when (val outcome = store.select(profile)) {
            ProfileStore.SwitchOutcome.SameAccount -> Unit
            is ProfileStore.SwitchOutcome.SwitchAccount ->
                status = "Now watching as ${profile.name}. This profile has its own VortX account; " +
                    "per-profile sign-in isn't wired on Android yet, so it keeps the current session."
            ProfileStore.SwitchOutcome.NeedsSignIn ->
                status = "Now watching as ${profile.name}. This profile has its own account; signing into a " +
                    "separate account per profile isn't available on Android yet."
        }
        refresh++
    }

    val editing = editorProfile
    if (editing != null) {
        ProfileEditor(
            store = store,
            original = editing,
            isNew = editorIsNew,
            onDone = { editorProfile = null; refresh++ },
            onCancel = { editorProfile = null },
            modifier = modifier,
        )
        return
    }

    Box(modifier = modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Profiles", style = VortXTheme.type.cardTitle) },
                    navigationIcon = {
                        IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
                    },
                )
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(VortXTheme.spacing.edge)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                SettingsSection(
                    title = "Who's watching",
                    footer = "Each profile keeps its own Continue Watching, library, and source ranking. A " +
                        "Kids profile hides adult and fake sources. Set a PIN to gate switching into a profile.",
                ) {
                    roster.forEach { profile ->
                        ProfileRow(
                            profile = profile,
                            isActive = profile.id == activeId,
                            onClick = {
                                if (profile.id == activeId) {
                                    // Editing is only allowed from within the profile itself (Apple's
                                    // isLocked guardrail); the active row therefore opens its own editor.
                                    editorProfile = profile
                                    editorIsNew = false
                                } else if (profile.hasPin) {
                                    pinTarget = profile   // gate the switch on the PIN
                                } else {
                                    commitSwitch(profile)
                                }
                            },
                        )
                    }
                    AddProfileRow(onClick = {
                        editorProfile = UserProfile(
                            name = "",
                            avatar = "🎬",
                            accentID = store.active?.accentID ?: "ember",
                        )
                        editorIsNew = true
                    })
                }

                status?.let { message ->
                    Text(
                        message,
                        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                        modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
                    )
                }
            }
        }

        pinTarget?.let { target ->
            PinGateOverlay(
                profile = target,
                onUnlock = { pinTarget = null; commitSwitch(target) },
                onCancel = { pinTarget = null },
            )
        }
    }
}

/// One profile in the switcher: an accent disc with the avatar (lock badge when PIN-gated), the name with a
/// Kids badge, and a status line. The active profile carries a check and opens its editor on tap; every other
/// profile switches on tap (through the PIN gate when locked).
@Composable
private fun ProfileRow(profile: UserProfile, isActive: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    val marks = buildList {
        if (isActive) add("Active")
        if (profile.isKids) add("Kids")
        if (profile.hasPin) add("Locked")
    }
    val subtitle = (marks + (if (isActive) "tap to edit" else "tap to switch")).joinToString("  ·  ")
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProfileDisc(profile)
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text(
                    profile.name.ifBlank { "Profile" },
                    style = VortXTheme.type.cardTitle.copy(fontWeight = FontWeight.SemiBold),
                )
                if (profile.isKids) KidsBadge()
            }
            Text(subtitle, style = VortXTheme.type.label.copy(color = colors.textTertiary))
        }
        when {
            isActive -> Icon(VortXIcons.checkmarkCircle, contentDescription = "Active profile", tint = colors.accent)
            profile.hasPin -> Icon(VortXIcons.lock, contentDescription = "Locked", tint = colors.textTertiary)
        }
    }
}

/// The accent-tinted avatar disc. The color is the profile's OWN accent ([UserProfile.accentID]) resolved
/// through the shared [VortXAccents] table, so the picker reads the same per-profile color the Apple picker
/// paints. A PIN-gated profile carries a small lock badge at the corner.
@Composable
private fun ProfileDisc(profile: UserProfile) {
    val accent = VortXAccents.byId(profile.accentID).base
    Box(contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(52.dp)
                .clip(CircleShape)
                .background(accent.copy(alpha = 0.26f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(profile.avatar, style = VortXTheme.type.sectionTitle)
        }
        if (profile.hasPin) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(20.dp)
                    .clip(CircleShape)
                    .background(VortXTheme.colors.surface3),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    VortXIcons.lock,
                    contentDescription = null,
                    tint = VortXTheme.colors.textSecondary,
                    modifier = Modifier.size(12.dp),
                )
            }
        }
    }
}

/// A small "Kids" pill beside a Kids profile's name (the explicit badge the picker calls for).
@Composable
private fun KidsBadge() {
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

/// The "Add profile" row at the foot of the roster (Apple `AddProfileCard`).
@Composable
private fun AddProfileRow(onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(52.dp)
                .clip(CircleShape)
                .background(colors.surface2),
            contentAlignment = Alignment.Center,
        ) {
            Icon(VortXIcons.add, contentDescription = null, tint = colors.textSecondary)
        }
        Text("Add profile", style = VortXTheme.type.cardTitle.copy(color = colors.textSecondary))
    }
}

/// Create or rename a profile: name, avatar, an optional Kids flag (non-owner only), and an optional 4-digit
/// PIN. Works on a local draft; nothing persists until Save routes to [ProfileStore.add] (new) or
/// [ProfileStore.update] (existing). Delete (existing, non-owner, more than one profile) calls
/// [ProfileStore.remove]. Mirrors Apple `ProfileEditorView.save` / its Delete confirmation.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProfileEditor(
    store: ProfileStore,
    original: UserProfile,
    isNew: Boolean,
    onDone: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var name by remember { mutableStateOf(original.name) }
    var avatar by remember { mutableStateOf(original.avatar) }
    var isKids by remember { mutableStateOf(original.isKids) }
    // The PIN field only ever takes a NEW pin (stored pins are salted hashes, never shown). Empty + no
    // explicit remove = keep the existing pin, exactly like Apple's editor.
    var pinText by remember { mutableStateOf("") }
    var removePin by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    val canSave = name.trim().isNotEmpty() && (pinText.isEmpty() || pinText.length == 4)
    val canDelete = !isNew && !original.isOwner && store.profiles.size > 1

    fun save() {
        val trimmed = name.trim()
        var draft = original.copy(
            name = trimmed,
            avatar = avatar,
            // The owner is the account's main profile; it can never be a Kids profile (guarded here as well
            // as by hiding the row below).
            isKids = if (original.isOwner) false else isKids,
        )
        draft = when {
            removePin -> draft.copy(pin = null)
            pinText.isNotEmpty() -> draft.copy(pin = UserProfile.pinHash(pinText, draft.id))
            else -> draft
        }
        if (isNew) store.add(draft) else store.update(draft)
        onDone()
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = {
                    Text(if (isNew) "New profile" else "Edit ${original.name}", style = VortXTheme.type.cardTitle)
                },
                navigationIcon = {
                    IconButton(onClick = onCancel) { Icon(VortXIcons.close, contentDescription = "Cancel") }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(VortXTheme.spacing.edge)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            SettingsSection(title = "Name", footer = null) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    singleLine = true,
                    placeholder = { Text("Name", style = VortXTheme.type.body) },
                    colors = editorFieldColors(),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
                )
            }

            SettingsSection(title = "Avatar", footer = null) {
                FlowRow(
                    modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    AVATARS.forEach { emoji ->
                        Chip(label = emoji, selected = emoji == avatar, onClick = { avatar = emoji })
                    }
                }
            }

            if (!original.isOwner) {
                SettingsSection(
                    title = "Kids",
                    footer = if (isKids) {
                        "Hides adult and CAM/fake sources from this profile. For a full lock, set a PIN on " +
                            "your own profile so it can't be opened from here."
                    } else {
                        null
                    },
                ) {
                    ToggleRow(
                        label = "Kids profile",
                        detail = "Parental content guard for this profile.",
                        checked = isKids,
                        onCheckedChange = { isKids = it },
                    )
                }
            } else {
                Text(
                    "The main profile. It uses your account's own watch history, like before profiles existed.",
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                    modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
                )
            }

            SettingsSection(
                title = "PIN",
                footer = "A parental gate, not a password. It is needed to switch INTO this profile.",
            ) {
                OutlinedTextField(
                    value = pinText,
                    onValueChange = {
                        pinText = it.filter(Char::isDigit).take(4)
                        removePin = false
                    },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    placeholder = {
                        Text(
                            if (original.hasPin) "PIN set. Enter a new one to change it" else "4 digits, empty for none",
                            style = VortXTheme.type.body,
                        )
                    },
                    colors = editorFieldColors(),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
                )
                if (original.hasPin && !removePin) {
                    Row(modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs)) {
                        Chip(label = "Remove PIN", selected = false, onClick = { removePin = true; pinText = "" })
                    }
                } else if (removePin) {
                    Text(
                        "PIN will be removed on Save.",
                        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                        modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
                    )
                }
            }

            EditorButton(label = "Save", enabled = canSave, prominent = true, onClick = { save() })
            if (canDelete) {
                if (!confirmDelete) {
                    EditorButton(
                        label = "Delete profile",
                        enabled = true,
                        prominent = false,
                        destructive = true,
                        onClick = { confirmDelete = true },
                    )
                } else {
                    Text(
                        "Delete ${original.name}? Its settings and this-profile history are removed.",
                        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                        modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                        EditorButton(
                            label = "Delete",
                            enabled = true,
                            prominent = false,
                            destructive = true,
                            modifier = Modifier.weight(1f),
                            onClick = { store.remove(original); onDone() },
                        )
                        EditorButton(
                            label = "Keep",
                            enabled = true,
                            prominent = false,
                            modifier = Modifier.weight(1f),
                            onClick = { confirmDelete = false },
                        )
                    }
                }
            }
        }
    }
}

/// A full-width editor button, styled from the theme rather than a stock Material button so Save/Delete read
/// as VortX. `prominent` fills with the accent; `destructive` tints the label with the danger color.
@Composable
private fun EditorButton(
    label: String,
    enabled: Boolean,
    prominent: Boolean,
    modifier: Modifier = Modifier,
    destructive: Boolean = false,
    onClick: () -> Unit,
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
        destructive -> colors.danger
        else -> colors.textPrimary
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(CircleShape)
            .background(container)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(vertical = VortXTheme.spacing.sm),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = VortXTheme.type.body.copy(color = labelColor, fontWeight = FontWeight.SemiBold))
    }
}

/// Centered 4-digit gate over a dimmed picker: the touch analogue of Apple `PinGateOverlay`. The caller
/// decides what unlocking means (here: commit the switch). [UserProfile.pinMatches] does the check, so the
/// stored salted hash never leaves the store.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PinGateOverlay(profile: UserProfile, onUnlock: () -> Unit, onCancel: () -> Unit) {
    val colors = VortXTheme.colors
    var input by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.72f))
            .clickable(role = Role.Button, onClick = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .background(colors.surface1)
                // Swallow taps on the panel so a tap inside it does not dismiss via the scrim above.
                .clickable(enabled = false, onClick = {})
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
                colors = editorFieldColors(),
            )
            if (wrong) {
                Text("Wrong PIN", style = VortXTheme.type.label.copy(color = colors.danger))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                EditorButton(
                    label = "Unlock",
                    enabled = input.length == 4,
                    prominent = true,
                    modifier = Modifier.weight(1f),
                    onClick = { if (profile.pinMatches(input)) onUnlock() else wrong = true },
                )
                EditorButton(
                    label = "Cancel",
                    enabled = true,
                    prominent = false,
                    modifier = Modifier.weight(1f),
                    onClick = onCancel,
                )
            }
        }
    }
}

/// Fallback when the store is not up: the Profiles surface stays reachable but reports honestly, matching the
/// fail-soft boundary the rest of the app uses (an engine/store problem degrades, never crashes).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProfilesUnavailable(onBack: () -> Unit, modifier: Modifier) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Profiles", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding).padding(VortXTheme.spacing.edge)) {
            Text(
                "Profiles are not available right now.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            )
        }
    }
}

@Composable
private fun editorFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = VortXTheme.colors.accent,
    unfocusedBorderColor = VortXTheme.colors.hairline,
    cursorColor = VortXTheme.colors.accent,
)

/// The avatar palette, byte-for-byte with Apple `ProfileEditorView.avatars` so a profile's emoji reads the
/// same on every surface.
private val AVATARS = listOf(
    "🍿", "🎬", "👑", "🦊", "🐼", "🚀", "🌊", "🔥",
    "🎮", "🐉", "👻", "🤖", "🎧", "🌸", "🦁", "⚡️",
)
