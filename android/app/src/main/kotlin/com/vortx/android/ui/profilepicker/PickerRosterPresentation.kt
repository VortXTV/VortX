package com.vortx.android.ui.profilepicker

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.VortXApplication
import com.vortx.android.profile.AdmittedPickerRoster
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.theme.VortXTheme

internal fun VortXApplication.isPickerRosterCurrent(manager: VortXSyncManager?, roster: AdmittedPickerRoster): Boolean =
    manager != null && syncManager === manager && manager.isPickerRosterOwner(roster.account) &&
        nativeStreamingAccounts().isPickerMountCurrent(roster.mount, roster.account) &&
        ProfileStore.sharedOrNull()?.pickerRoster?.value === roster

/** Observe both host projection and native mount completion/retirement without reading secure storage. */
@Composable
internal fun rememberAdmittedPickerRoster(
    app: VortXApplication?,
    store: ProfileStore?,
    manager: VortXSyncManager?,
    sessionUi: VortXSyncManager.SessionUiState?,
): AdmittedPickerRoster? {
    val native = remember(app, manager) { if (manager != null) app?.nativeStreamingAccounts() else null }
    val mountRevision = native?.changes?.collectAsStateWithLifecycle()?.value
    val roster = store?.pickerRoster?.collectAsStateWithLifecycle()?.value
    return remember(app, manager, sessionUi, mountRevision, roster) {
        roster?.takeIf { app?.isPickerRosterCurrent(manager, it) == true }
    }
}

@Composable
internal fun PickerProfilesUnavailable(isTv: Boolean, accountControl: ProfilePickerAccountControl?,
    toolsEntry: @Composable () -> Unit,
) {
    Box(Modifier.fillMaxSize().background(VortXTheme.colors.canvas).padding(if (isTv) 48.dp else 24.dp),
        contentAlignment = Alignment.Center) {
        Column(Modifier.widthIn(max = 680.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Profiles aren’t ready", style = VortXTheme.type.sectionTitle)
            Text("Open Tools for backup recovery, or check your account.", style = VortXTheme.type.body)
            toolsEntry()
            accountControl?.let { control ->
                control.onCheckAccount?.let { check ->
                    PickerToolsButton("Check account", isTv, true, Modifier.testTag("picker-check-account"), onClick = check)
                }
                PickerToolsButton(control.label, isTv, true, Modifier.testTag("picker-unavailable-account"),
                    onClick = control.onClick)
            }
        }
    }
}
