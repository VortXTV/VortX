package com.vortx.android.ui.viewmodel

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.backup.accountfiles.AccountBackupBytes
import com.vortx.android.backup.accountfiles.AccountBackupCopyKind
import com.vortx.android.backup.accountfiles.AccountBackupDocuments
import com.vortx.android.sync.AccountFileRepairFailure
import com.vortx.android.sync.AccountFileRepairReason
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.profilepicker.PickerToolsAccounts
import com.vortx.android.ui.profilepicker.PickerToolsActionGrant
import com.vortx.android.ui.profilepicker.PickerToolsBackupPreparer
import com.vortx.android.ui.profilepicker.PickerToolsDestinationRequest
import com.vortx.android.ui.profilepicker.PickerToolsException
import com.vortx.android.ui.profilepicker.PickerToolsFailure
import com.vortx.android.ui.profilepicker.PickerToolsPreparedBackup
import com.vortx.android.ui.profilepicker.PickerToolsRepairExport
import com.vortx.android.ui.profilepicker.PickerToolsRepairInputRequest
import com.vortx.android.ui.profilepicker.PickerToolsRepairPreparer
import com.vortx.android.ui.profilepicker.PickerToolsSelectedBackup
import com.vortx.android.ui.profilepicker.PickerToolsSaveReceipt
import com.vortx.android.ui.profilepicker.PickerToolsWorkGate
import com.vortx.android.ui.profilepicker.ProfilePickerToolsController
import com.vortx.android.ui.screens.shareDiagnosticLog
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf

internal class ManagerPickerToolsAccounts(private val manager: VortXSyncManager) : PickerToolsAccounts {
    override val authorityRevision: Long get() = manager.pickerAuthorityRevision.value
    override val sessionMarker: Any get() = manager.sessionUiState.value
    override val changes: Flow<Unit> = combine(manager.pickerAuthorityRevision, manager.sessionUiState) { _, _ -> Unit }
    override fun capture(): PickerAccountSnapshot? = manager.capturePickerAccountSnapshot()
    override fun isCurrent(original: PickerAccountSnapshot): Boolean = manager.isPickerAccountCurrent(original)
    override suspend fun download(original: PickerAccountSnapshot): ByteArray = manager.downloadAccountBackupFile(original)
}
private object UnavailablePickerToolsAccounts : PickerToolsAccounts {
    override val authorityRevision = 0L
    override val sessionMarker: Any = Unit
    override val changes = flowOf(Unit)
    override fun capture(): PickerAccountSnapshot? = null
    override fun isCurrent(original: PickerAccountSnapshot) = false
    override suspend fun download(original: PickerAccountSnapshot): ByteArray = throw PickerToolsException(PickerToolsFailure.SAVE_FAILED)
}
private class SafPickerToolsBackup(val bytes: AccountBackupBytes,
    val kind: AccountBackupCopyKind = AccountBackupCopyKind.ACCOUNT) : PickerToolsPreparedBackup {
    override val byteCount get() = bytes.byteCount
    override val sha256 get() = bytes.sha256
    override fun close() = bytes.close()
    override fun toString() = "SafPickerToolsBackup"
}
private fun AccountFileRepairFailure.toPickerRefusal() = PickerToolsException(when (reason) {
    AccountFileRepairReason.BUSY -> PickerToolsFailure.REPAIR_BUSY
    AccountFileRepairReason.ALREADY_REPAIRED -> PickerToolsFailure.ALREADY_REPAIRED
    AccountFileRepairReason.OWNER_UNAVAILABLE -> PickerToolsFailure.REPAIR_OWNER_UNAVAILABLE
    AccountFileRepairReason.ACCOUNT_UNSUPPORTED -> PickerToolsFailure.REPAIR_ACCOUNT_UNSUPPORTED
    AccountFileRepairReason.EXPIRED -> PickerToolsFailure.REPAIR_EXPIRED
    AccountFileRepairReason.INVALID_FILE -> PickerToolsFailure.INVALID_REPAIR_FILE
})

/** Activity-owned, ephemeral only. It retains neither an Activity nor any SavedStateHandle/Bundle. */
internal class ProfilePickerToolsViewModel private constructor(
    private val documents: AccountBackupDocuments?,
    createController: (ProfilePickerToolsViewModel) -> ProfilePickerToolsController,
) : ViewModel() {
    val controller = createController(this)
    val state get() = controller.state
    constructor(manager: VortXSyncManager?, context: Context, workGate: PickerToolsWorkGate = PickerToolsWorkGate()) : this(
        AccountBackupDocuments(context.applicationContext),
        { model ->
            ProfilePickerToolsController(manager?.let(::ManagerPickerToolsAccounts) ?: UnavailablePickerToolsAccounts,
                PickerToolsBackupPreparer { bytes, current ->
                    SafPickerToolsBackup(checkNotNull(model.documents).prepare(bytes, current))
                }, model.viewModelScope, workGate, manager?.let { source ->
                    PickerToolsRepairPreparer { owner, bytes, current ->
                        val operation = try { source.prepareAccountBackupRepair(owner, bytes, current) }
                        catch (refusal: AccountFileRepairFailure) { throw refusal.toPickerRefusal() }
                        object : PickerToolsRepairExport {
                            override val profileCount get() = operation.profileCount
                            override val nativeSchema get() = operation.nativeSchema
                            override val byteCount get() = operation.byteCount
                            override val sha256 get() = operation.sha256
                            override fun remainingMillis() = operation.remainingMillis()
                            override fun canSave() = operation.canSave()
                            override fun take() = try { operation.take() }
                                catch (refusal: AccountFileRepairFailure) { throw refusal.toPickerRefusal() }
                            override fun close() = operation.close()
                        }
                    }
                })
        },
    )
    /** Test collaborator replaces I/O/transport only; the actual controller and route/slot logic remain. */
    internal constructor(controller: ProfilePickerToolsController) : this(null, { controller })
    fun repairInputReturned(request: PickerToolsRepairInputRequest, uri: Uri?) {
        if (uri == null) { controller.repairInputRefused(request); return }
        controller.repairInputReturned(request) { current ->
            val provider = checkNotNull(documents)
            val source = provider.read(uri, current)
            object : PickerToolsSelectedBackup {
                override fun copyBytes() = source.copyBytes()
                override suspend fun prepareRepairedCopy(bytes: ByteArray, isCurrent: () -> Boolean) =
                    SafPickerToolsBackup(provider.prepareRepairedCopy(bytes, source, isCurrent), AccountBackupCopyKind.REPAIRED)
                override fun close() = source.close()
            }
        }
    }
    fun destinationReturned(request: PickerToolsDestinationRequest, tree: Uri?) {
        if (tree == null) { controller.destinationRefused(request); return }
        controller.destinationReturned(request) { prepared, current ->
            val original = prepared as? SafPickerToolsBackup
                ?: throw PickerToolsException(PickerToolsFailure.WRONG_RECEIPT)
            val receipt = checkNotNull(documents).saveNewCopy(tree, original.bytes, kind = original.kind, isCurrent = current)
            PickerToolsSaveReceipt(receipt.byteCount, receipt.sha256)
        }
    }
    fun diagnostics(route: PickerToolsActionGrant, context: Context, requiredPolicy: () -> Boolean) {
        val applicationContext = context.applicationContext
        controller.diagnostics(route, requiredPolicy) { admission ->
            // Never use shareDiagnosticLog's permissive default on a picker route.
            shareDiagnosticLog(applicationContext, mayShare = admission)
        }
    }
    override fun onCleared() { controller.close(); super.onCleared() }
}

internal class PickerToolsModelHolder : ViewModel() {
    private var current: VortXSyncManager? = null
    private val workGate = PickerToolsWorkGate()
    private var store = ReplacingViewModelStoreOwner()
    fun model(manager: VortXSyncManager?, applicationContext: Context): ProfilePickerToolsViewModel {
        if (current !== manager) { store.clear(); store = ReplacingViewModelStoreOwner(); current = manager }
        return ViewModelProvider(store, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = ProfilePickerToolsViewModel(manager, applicationContext, workGate) as T
        })[ProfilePickerToolsViewModel::class.java]
    }
    override fun onCleared() { store.clear(); super.onCleared() }
}
@Composable
internal fun rememberPickerToolsModel(manager: VortXSyncManager?): ProfilePickerToolsViewModel {
    val applicationContext = LocalContext.current.applicationContext
    val holder: PickerToolsModelHolder = viewModel(key = "pre-profile-vortx-tools-holder", factory = remember {
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = PickerToolsModelHolder() as T
        }
    })
    return holder.model(manager, applicationContext)
}
