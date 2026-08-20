package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.Surface
import com.vortx.android.ui.screens.VortXAccountContent
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.VortXAccountViewModel

/// The 10-foot Backup and Restore surface, the Android TV analogue of Apple
/// `app/SourcesTV/BackupExportView.swift` + `BackupImportView.swift`. On a TV there is no D-pad-friendly file
/// picker, so, exactly like the Apple TV, backup and restore ARE the VortX account QR pairing: this screen
/// reuses the SAME [VortXAccountContent] joiner the Account route drives (over the app-process
/// `VortXSyncManager`), which shows a scannable QR plus the short human-typable code the viewer enters at
/// vortx.tv/approve on a signed-in phone or browser. Signing this TV in seeds the account from this device
/// (export) or, when the account already holds data, restores that data onto this device (restore); the
/// conflict is reconciled by the sync manager exactly as it is on Apple. The ~1 MB settings blob rides HTTPS
/// through the sync doc; the QR only ever carries the pairing code plus an ephemeral public key, never a token
/// (the account token lives only in the secure store and is never placed in a backup). When already signed in,
/// the joiner instead shows the account summary with Sync now, the manual push-and-pull the phone drives.
///
/// It forks NO auth or backup path and sees no credential: every token touch stays inside
/// [VortXAccountViewModel] and the sync manager's secure store. [vortxViewModel] is null when the process could
/// not stand up a `VortXSyncManager` (a preview or a wiring failure); the screen then shows an honest note
/// instead of a dead panel.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvBackupRestoreScreen(
    vortxViewModel: VortXAccountViewModel?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler { onBack() }
    val colors = VortXTheme.colors
    val backFocus = remember { FocusRequester() }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        TvBackupBackButton(onClick = onBack, focusRequester = backFocus)
        Column(
            modifier = Modifier.widthIn(max = TvDimens.formMaxWidth),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Backup and restore", style = VortXTheme.type.sectionTitle)
            Text(
                "Back up and restore this TV by signing it into your VortX account. Scan the code below, or " +
                    "enter it at vortx.tv/approve, on a phone or browser already signed in to VortX. Your " +
                    "profiles, add-ons, library, and settings are stored in your account, end-to-end " +
                    "encrypted, and restored on any device you sign in. Nothing is written to a file and your " +
                    "account token never leaves this device.",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
            if (vortxViewModel != null) {
                VortXAccountContent(vortxViewModel, modifier = Modifier.fillMaxWidth())
            } else {
                Text(
                    "Backup to your account is unavailable right now. Try again after the app has finished " +
                        "starting up.",
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )
            }
        }
    }

    LaunchedEffect(Unit) {
        runCatching { backFocus.requestFocus() }
    }
}

/// A focusable 10-foot Back affordance for the reused-phone-screen TV routes that render no back button of
/// their own. The whole surface is one D-pad target; focus lights the accent ring, matching the settings rows.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvBackupBackButton(onClick: () -> Unit, focusRequester: FocusRequester? = null) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier
            .width(180.dp)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface2,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(VortXIcons.back, contentDescription = null, tint = LocalContentColor.current)
            Spacer(Modifier.width(VortXTheme.spacing.xs))
            Text(
                "Back",
                style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold),
                color = LocalContentColor.current,
            )
        }
    }
}
