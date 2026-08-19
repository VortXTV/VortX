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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXTheme

/// The cold-launch "Who's watching?" picker (ACC-3), the Android port of Apple `ProfilePickerView` shown as
/// a launch `fullScreenCover` (`app/SourcesShared/ProfilesView.swift`). Gated by the caller on
/// [ProfileStore.needsPicker] (more than one profile AND not yet picked this launch), so it appears once per
/// cold start only when there is a real choice.
///
/// It holds NO profile logic: tapping a profile calls [ProfileStore.select] (through the same PIN gate the
/// Settings switcher uses), which applies that profile's theme/filters, swaps in its private watch overlay,
/// and fires the engine reload + Home-rebuild seams. The never-poison split lives entirely in the store; this
/// is only the launch entry point. [onDone] dismisses the picker (the caller stops rendering it).
@Composable
fun WhosWatchingScreen(onDone: () -> Unit, modifier: Modifier = Modifier) {
    val store = ProfileStore.sharedOrNull()
    if (store == null || store.profiles.size <= 1) {
        // Fail-soft: nothing to pick. Dismiss immediately rather than showing an empty picker.
        onDone()
        return
    }

    val roster = remember { store.profiles }
    val activeId = remember { store.activeID }
    var pinTarget by remember { mutableStateOf<UserProfile?>(null) }

    fun choose(profile: UserProfile) {
        // select() marks pickedThisLaunch, applies the profile, and swaps its overlay. We ignore the
        // account-switch outcome here (per-profile own-account sign-in is not wired on Android yet); the
        // Settings switcher surfaces that note, and the launch picker just gets you watching.
        store.select(profile)
        onDone()
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(VortXTheme.colors.canvas),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(VortXTheme.spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl, Alignment.CenterVertically),
        ) {
            Text(
                "Who's watching?",
                style = VortXTheme.type.screenTitle,
                textAlign = TextAlign.Center,
            )
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg, Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
            ) {
                roster.forEach { profile ->
                    ProfileChoice(
                        profile = profile,
                        isActive = profile.id == activeId,
                        onClick = {
                            // Switching INTO a locked profile passes the PIN gate; the currently-active
                            // profile is already unlocked, so it (and any unlocked profile) selects directly.
                            if (profile.hasPin && profile.id != activeId) pinTarget = profile else choose(profile)
                        },
                    )
                }
            }
        }

        pinTarget?.let { target ->
            PinGate(
                profile = target,
                onUnlock = { pinTarget = null; choose(target) },
                onCancel = { pinTarget = null },
            )
        }
    }
}

/// One large, tappable profile tile: an accent disc with the avatar (a lock badge when PIN-gated), the name,
/// and a Kids marker. Sized for a 10-foot glance as well as touch.
@Composable
private fun ProfileChoice(profile: UserProfile, isActive: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    val accent = VortXAccents.byId(profile.accentID).base
    Column(
        modifier = Modifier
            .width(120.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = VortXTheme.spacing.sm),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Box(
                modifier = Modifier
                    .size(96.dp)
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
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(colors.surface3),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        com.vortx.android.ui.theme.VortXIcons.lock,
                        contentDescription = null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
        Text(
            profile.name.ifBlank { "Profile" },
            style = VortXTheme.type.cardTitle.copy(
                fontWeight = FontWeight.SemiBold,
                color = if (isActive) colors.textPrimary else colors.textSecondary,
            ),
            textAlign = TextAlign.Center,
        )
        if (profile.isKids) {
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.accentSoft)
                    .padding(horizontal = VortXTheme.spacing.xs, vertical = 2.dp),
            ) {
                Text("Kids", style = VortXTheme.type.eyebrow.copy(color = colors.accent))
            }
        }
    }
}

/// The 4-digit gate for switching into a locked profile from the launch picker, the same check the Settings
/// switcher uses ([UserProfile.pinMatches]), so the stored salted hash never leaves the store.
@Composable
private fun PinGate(profile: UserProfile, onUnlock: () -> Unit, onCancel: () -> Unit) {
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
                .clickable(enabled = false, onClick = {}) // swallow taps so the panel does not dismiss itself
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
