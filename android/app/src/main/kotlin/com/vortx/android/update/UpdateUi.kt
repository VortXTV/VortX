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
import androidx.compose.ui.platform.LocalUriHandler
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
 * caller places it unconditionally. Tapping it opens the install channel (the APK / AltStore source / the
 * releases page). Android is sideloaded, so this is a HAND-OFF to install, never an in-place overwrite.
 */
@Composable
fun UpdateAvailableBanner(modifier: Modifier = Modifier) {
    val release by UpdateChecker.available.collectAsStateWithLifecycle()
    val current = release ?: return
    val colors = VortXTheme.colors
    val uriHandler = LocalUriHandler.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(VortXShapes.card)
            .background(colors.accentSoft)
            .clickable { uriHandler.openUri(current.installUrl) }
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
            "Get",
            style = VortXTheme.type.label.copy(color = colors.accent, fontWeight = FontWeight.SemiBold),
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
    val appContext = LocalContext.current.applicationContext
    val prompt by UpdateChecker.prompt.collectAsStateWithLifecycle()
    prompt?.let { release ->
        UpdatePromptDialog(release = release, onDismiss = { UpdateChecker.dismissPrompt(appContext) })
    }
}

/**
 * The modal "an update is available" popup. "Get the update" opens the install channel then dismisses;
 * "Later" dismisses for this build this launch. The Android analogue of `UpdatePromptView.swift`.
 */
@Composable
fun UpdatePromptDialog(release: UpdateChecker.Release, onDismiss: () -> Unit) {
    val colors = VortXTheme.colors
    val uriHandler = LocalUriHandler.current
    Dialog(onDismissRequest = onDismiss) {
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
            Button(
                onClick = {
                    uriHandler.openUri(release.installUrl)
                    onDismiss()
                },
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.accent,
                    contentColor = colors.onAccent,
                ),
            ) {
                Text("Get the update", style = VortXTheme.type.cardTitle)
            }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                Text("Later", style = VortXTheme.type.label.copy(color = colors.textPrimary))
            }
        }
    }
}

private fun versionLine(release: UpdateChecker.Release): String {
    val version = if (release.version.isBlank()) "" else "Version ${release.version}"
    val build = "build ${release.build}"
    return if (version.isBlank()) build else "$version ($build)"
}
