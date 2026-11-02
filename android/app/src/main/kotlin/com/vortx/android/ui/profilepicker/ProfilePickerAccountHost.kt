package com.vortx.android.ui.profilepicker

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.PickerSignOutResult
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.viewmodel.ReplacingViewModelStoreOwner
import com.vortx.android.ui.viewmodel.VortXAccountViewModel

class ProfilePickerAccountControl(val label: String, val onClick: () -> Unit)

/** No roster/failure fallback grants pre-profile diagnostic access. Staging re-reads this policy. */
internal fun pickerDiagnosticExportAllowed(profiles: List<UserProfile>?): Boolean =
    !profiles.isNullOrEmpty() && profiles.none { it.hasPin }
internal fun currentPickerDiagnosticExportAllowed(): Boolean = runCatching {
    ContinueWatchingOwnerGate.serialized { pickerDiagnosticExportAllowed(ProfileStore.sharedOrNull()?.profiles) }
}.getOrDefault(false)

/** Activity-retained holder owns exactly one current-manager model; no secret enters saved state. */
internal class PickerAccountModelHolder : ViewModel() {
    private var current: VortXSyncManager? = null
    private var store = ReplacingViewModelStoreOwner()
    fun model(manager: VortXSyncManager?): VortXAccountViewModel? {
        if (current !== manager) { store.clear(); store = ReplacingViewModelStoreOwner(); current = manager }
        manager ?: return null
        return ViewModelProvider(store, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = VortXAccountViewModel(manager) as T
        })[VortXAccountViewModel::class.java]
    }
    override fun onCleared() { store.clear(); super.onCleared() }
}
@Composable
internal fun rememberPickerAccountModel(manager: VortXSyncManager?): VortXAccountViewModel? {
    val holder: PickerAccountModelHolder = viewModel(key = "pre-profile-vortx-account-holder", factory = remember {
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = PickerAccountModelHolder() as T
        }
    })
    return holder.model(manager)
}

/** The VM owns pending completion. Back cannot discard an unsaved code or unresolved account choice. */
@Composable
internal fun ProfilePickerAccountHost(
    syncManager: VortXSyncManager?,
    model: VortXAccountViewModel?,
    retirePickerUi: () -> Unit,
    diagnosticAdmission: () -> Boolean,
    accountScreen: @Composable (VortXAccountViewModel, () -> Unit, () -> Unit, () -> Boolean, String?) -> Unit,
    picker: @Composable (ProfilePickerAccountControl?) -> Unit,
) {
    if (syncManager == null || model == null) { picker(null); return }
    val state by syncManager.sessionUiState.collectAsStateWithLifecycle()
    val open by model.pickerPresentationOpen.collectAsStateWithLifecycle()
    val dismissalNotice by model.pickerDismissalNotice.collectAsStateWithLifecycle()
    var confirmation by remember(syncManager) { mutableStateOf<PickerAccountSnapshot?>(null) }
    var pickerGeneration by remember(syncManager) { mutableStateOf(0L) }
    var status by remember(syncManager) { mutableStateOf<String?>(null) }
    fun closeForm() { model.requestClosePickerPresentation() }
    fun requestSignOut() {
        val original = syncManager.capturePickerAccountSnapshot()
        if (original?.account != null) confirmation = original
        else status = "The account changed. Open this action again."
    }
    fun requestAccount() {
        if (model.hasPendingPickerCompletion()) model.openPickerPresentation()
        else if (syncManager.capturePickerAccountSnapshot()?.account != null) requestSignOut()
        else model.openPickerPresentation()
    }
    if (open) {
        BackHandler { closeForm() }
        accountScreen(model, ::closeForm, ::requestSignOut, diagnosticAdmission, dismissalNotice)
    } else {
        Box(Modifier.fillMaxSize()) { key(pickerGeneration) {
            picker(ProfilePickerAccountControl(
                if (state is VortXSyncManager.SessionUiState.SignedIn) "Sign out" else if (state == VortXSyncManager.SessionUiState.SignedOut) "Sign in" else "Account",
                ::requestAccount))
        } }
    }
    status?.let { message -> AlertDialog(onDismissRequest = { status = null }, title = { Text("Account") },
        text = { Text(message) }, confirmButton = { TextButton(onClick = { status = null }) { Text("OK") } }) }
    confirmation?.let { original ->
        AlertDialog(onDismissRequest = { confirmation = null }, title = { Text("Sign out?") },
            text = { Text("Sign out of ${original.account?.email?.takeIf { it.isNotBlank() } ?: original.account?.username ?: "this account"} on this device? Your account data will stay in your account.") },
            dismissButton = { TextButton(onClick = { confirmation = null }) { Text("Cancel") } },
            confirmButton = { TextButton(onClick = {
                val result = model.signOut(original) {
                    confirmation = null
                    model.retirePickerPresentationForSignOut()
                    pickerGeneration++
                    retirePickerUi()
                }
                confirmation = null
                model.resumePickerCompletionIfCurrent()
                status = when (result) {
                    PickerSignOutResult.SIGNED_OUT -> null
                    PickerSignOutResult.STALE -> "The account changed. Open Sign out again."
                    PickerSignOutResult.STORAGE_UNAVAILABLE -> "Secure storage is unavailable. Your VortX session was not changed. Please try again."
                }
            }) { Text("Sign out") } })
    }
}
