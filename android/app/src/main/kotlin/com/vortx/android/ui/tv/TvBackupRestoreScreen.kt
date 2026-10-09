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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
import com.vortx.android.sync.AccountTransferDirection
import com.vortx.android.sync.AccountTransferChoice
import com.vortx.android.sync.AccountTransferStage

/// Explicit transfer direction, with QR approval only when signed out. Account conflicts require a choice;
/// the controller retains the authenticated owner through the check and transfer.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvBackupRestoreScreen(
    vortxViewModel: VortXAccountViewModel?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val transfer = vortxViewModel?.transferState?.collectAsStateWithLifecycle()?.value
    fun back() {
        if (transfer != null && transfer.stage != AccountTransferStage.IDLE) vortxViewModel?.cancelTransfer()
        else onBack()
    }
    BackHandler { back() }
    DisposableEffect(vortxViewModel) { onDispose { vortxViewModel?.cancelTransfer() } }
    val colors = VortXTheme.colors
    val backFocus = remember { FocusRequester() }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        TvBackupBackButton(onClick = ::back, focusRequester = backFocus)
        Column(
            modifier = Modifier.widthIn(max = TvDimens.formMaxWidth),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Backup and restore", style = VortXTheme.type.sectionTitle)
            Text(
                "Save this TV's profiles, add-ons, library, and settings to your encrypted VortX account, " +
                    "or bring saved account data onto this TV. Choose a direction before approving a sign-in code.",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
            if (vortxViewModel != null && transfer != null) {
                when (transfer.stage) {
                    AccountTransferStage.IDLE -> {
                        TvTransferButton("Back up this TV", { vortxViewModel.beginTransfer(AccountTransferDirection.BACKUP) })
                        TvTransferButton("Restore from account", { vortxViewModel.beginTransfer(AccountTransferDirection.RESTORE) })
                    }
                    AccountTransferStage.SIGN_IN -> CompositionLocalProvider(LocalTvProfilePresentation provides true) {
                        VortXAccountContent(vortxViewModel, Modifier.fillMaxWidth(), transferOnly = true)
                    }
                    AccountTransferStage.CHECKING -> Text("Checking saved account data…", style = VortXTheme.type.body)
                    AccountTransferStage.RUNNING -> Text("Transferring data…", style = VortXTheme.type.body)
                    AccountTransferStage.CHOOSE -> {
                        Text("This account already has saved data", style = VortXTheme.type.cardTitle)
                        transfer.message?.let { Text(it, style = VortXTheme.type.body.copy(color = colors.danger)) }
                        Text("Use account data restores saved data here. Merge both applies the shared account merge rules. " +
                            "Neither action replaces another account's private data.", style = VortXTheme.type.body)
                        if (!transfer.canKeepDevice) Text("Keep this device is unavailable: no local data is mounted for this account yet. " +
                            "Choose Restore or Merge, or return to Account to sign out.", style = VortXTheme.type.body)
                        val choices = if (transfer.direction == AccountTransferDirection.BACKUP)
                            listOf(AccountTransferChoice.KEEP_DEVICE, AccountTransferChoice.MERGE, AccountTransferChoice.USE_ACCOUNT)
                        else listOf(AccountTransferChoice.USE_ACCOUNT, AccountTransferChoice.MERGE, AccountTransferChoice.KEEP_DEVICE)
                        choices.filter { it != AccountTransferChoice.KEEP_DEVICE || transfer.canKeepDevice }.forEach { choice ->
                            TvTransferButton(when (choice) {
                                AccountTransferChoice.KEEP_DEVICE -> "Keep this device"
                                AccountTransferChoice.USE_ACCOUNT -> "Use account data"
                                AccountTransferChoice.MERGE -> "Merge both"
                            }, { vortxViewModel.chooseTransfer(choice) })
                        }
                    }
                    AccountTransferStage.COMPLETE, AccountTransferStage.FAILED -> {
                        transfer.message?.let { Text(it, style = VortXTheme.type.body) }
                        if (transfer.stage == AccountTransferStage.FAILED) {
                            TvTransferButton("Try again", { transfer.direction?.let(vortxViewModel::beginTransfer) })
                        }
                        TvTransferButton("Done", vortxViewModel::cancelTransfer)
                    }
                }
            } else {
                Text(
                    "Backup to your account is unavailable right now. Try again after the app has finished " +
                        "starting up.",
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )
            }
        }
    }

    LaunchedEffect(transfer?.stage) {
        withFrameNanos { }
        backFocus.requestFocus()
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvTransferButton(label: String, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(containerColor = colors.surface2,
            contentColor = colors.textPrimary, focusedContainerColor = colors.surface3),
        border = ClickableSurfaceDefaults.border(focusedBorder = Border(BorderStroke(2.dp, colors.accentBright), shape = VortXShapes.control)),
    ) { Text(label, style = VortXTheme.type.body, modifier = Modifier.padding(18.dp)) }
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
