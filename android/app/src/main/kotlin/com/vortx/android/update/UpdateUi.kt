package com.vortx.android.update

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/**
 * The passive "update available" banner, shared by the phone Settings screen and the TV About section. Reads
 * [UpdateChecker.available] and renders nothing when up to date (or when the user dismissed this build), so a
 * caller places it unconditionally.
 *
 * Tapping it starts the SECURE pipeline ([UpdateChecker.prepareInstall]): the APK is downloaded into the
 * app-private cache and verified (size, SHA-256, package identity, pinned signer) BEFORE any installer is
 * involved. The banner never opens a URL itself; the hand-off happens through [UpdatePromptDialog] once the
 * artifact is [UpdateChecker.InstallPhase.Ready].
 */
@Composable
fun UpdateAvailableBanner(modifier: Modifier = Modifier) {
    val release by UpdateChecker.available.collectAsStateWithLifecycle()
    val phase by UpdateChecker.installPhase.collectAsStateWithLifecycle()
    val current = release ?: return
    val colors = VortXTheme.colors
    val context = LocalContext.current.applicationContext
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(VortXShapes.card)
            .background(colors.accentSoft)
            .clickable { UpdateChecker.prepareInstall(context) }
            .padding(horizontal = VortXTheme.spacing.md, vertical = VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(VortXIcons.download, contentDescription = null, tint = colors.accent)
        Column(modifier = Modifier.weight(1f)) {
            Text(
                "Update available",
                style = VortXTheme.type.cardTitle.copy(color = colors.textPrimary),
            )
            Text(
                versionLine(current),
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
        }
        Text(
            when {
                phase is UpdateChecker.InstallPhase.Downloading -> "${phasePercent(phase)}%"
                phase is UpdateChecker.InstallPhase.Ready -> "Install"
                else -> "Get"
            },
            style = VortXTheme.type.label.copy(
                color = colors.accent,
                fontWeight = FontWeight.SemiBold,
            ),
        )
    }
}

/**
 * Collects [UpdateChecker.prompt] and presents [UpdatePromptDialog] when a newer stable build has not yet
 * been surfaced this launch. Placed once at the app root so the popup floats above whatever screen is
 * showing. Mirrors Apple's `.sheet(item: UpdateChecker.shared.prompt)`.
 */
@Composable
fun UpdatePromptHost() {
    val prompt by UpdateChecker.prompt.collectAsStateWithLifecycle()
    prompt?.let { release ->
        UpdatePromptDialog(release = release)
    }
}

/**
 * The modal "an update is available" popup, shared verbatim by the phone shell and the TV shell.
 *
 * Button semantics (SEC-07):
 *  - the PRIMARY button starts the secure download/verify pipeline and flips to "Install now" only once the
 *    artifact is fully verified; it hands off to the system installer via FileProvider, never to a browser;
 *  - "Later" dismisses for THIS PROCESS ONLY (the reminder returns next launch);
 *  - "Skip this version" durably suppresses exactly this build until a newer one ships.
 */
@Composable
fun UpdatePromptDialog(release: UpdateChecker.Release) {
    val colors = VortXTheme.colors
    val context = LocalContext.current.applicationContext
    val phase by UpdateChecker.installPhase.collectAsStateWithLifecycle()
    Dialog(onDismissRequest = { UpdateChecker.later() }) {
        Column(
            modifier = Modifier
                .clip(VortXShapes.card)
                .background(colors.surface1)
                .padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                VortXIcons.download,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.padding(bottom = VortXTheme.spacing.xs),
            )
            Text(
                "Update available",
                style = VortXTheme.type.sectionTitle.copy(color = colors.textPrimary),
            )
            Text(
                if (release.name.isBlank()) versionLine(release) else "${release.name}  ·  ${versionLine(release)}",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
            if (release.notes.isNotBlank()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 220.dp)
                        .clip(VortXShapes.card)
                        .background(colors.surface2)
                        .verticalScroll(rememberScrollState())
                        .padding(VortXTheme.spacing.sm),
                ) {
                    Text(release.notes, style = VortXTheme.type.body.copy(color = colors.textSecondary))
                }
            }
            when (val state = phase) {
                is UpdateChecker.InstallPhase.Failed -> Text(
                    state.reason,
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                )
                is UpdateChecker.InstallPhase.Downloading -> Text(
                    "Downloading update… ${statePercent(state)}%",
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                )
                else -> Unit
            }
            val ready = phase is UpdateChecker.InstallPhase.Ready
            Button(
                onClick = {
                    when {
                        ready -> UpdateChecker.launchInstall(context)
                        phase !is UpdateChecker.InstallPhase.Downloading -> UpdateChecker.prepareInstall(context)
                        else -> Unit // a download is already in flight; wait for its terminal phase
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = phase !is UpdateChecker.InstallPhase.Downloading || ready,
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.accent,
                    contentColor = colors.onAccent,
                ),
            ) {
                Text(
                    when {
                        ready -> "Install now"
                        phase is UpdateChecker.InstallPhase.Downloading -> "Downloading…"
                        else -> "Get the update"
                    },
                    style = VortXTheme.type.cardTitle,
                )
            }
            TextButton(onClick = { UpdateChecker.later() }, modifier = Modifier.fillMaxWidth()) {
                Text("Later", style = VortXTheme.type.label.copy(color = colors.textPrimary))
            }
            TextButton(onClick = { UpdateChecker.skipVersion(context) }, modifier = Modifier.fillMaxWidth()) {
                Text("Skip this version", style = VortXTheme.type.label.copy(color = colors.textSecondary))
            }
        }
    }
}

private fun versionLine(release: UpdateChecker.Release): String {
    val version = if (release.version.isBlank()) "" else "Version ${release.version}"
    val build = "build ${release.build}"
    return if (version.isBlank()) build else "$version ($build)"
}

/** Percent for the banner label; clamped defensively so a zero/odd total can never divide by zero. */
private fun phasePercent(phase: UpdateChecker.InstallPhase): Int = when (phase) {
    is UpdateChecker.InstallPhase.Downloading ->
        if (phase.total > 0) ((phase.received * 100) / phase.total).toInt().coerceIn(0, 100) else 0
    is UpdateChecker.InstallPhase.Ready -> 100
    else -> 0
}

private fun statePercent(state: UpdateChecker.InstallPhase.Downloading): Int =
    if (state.total > 0) ((state.received * 100) / state.total).toInt().coerceIn(0, 100) else 0
