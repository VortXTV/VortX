package com.vortx.android.ui.profilepicker

import android.net.Uri
import com.vortx.android.backup.accountfiles.AccountBackupBytes
import com.vortx.android.backup.accountfiles.AccountBackupDocuments
import com.vortx.android.sync.AccountFileRestoreExternalExclusion
import com.vortx.android.sync.AccountFileRestoreTransaction
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.VortXSyncManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** One SAF selection owned by the original rendered Tools action. A future controller must hold
 * the existing shared work slot while choosing, confirming and draining the actual submit. */
internal class PickerToolsRestoreSelection private constructor(
    private val manager: VortXSyncManager,
    private val grant: PickerToolsActionGrant,
    private val owner: PickerAccountSnapshot,
    private val routeCurrent: () -> Boolean,
    selected: AccountBackupBytes,
) : Closeable {
    val byteCount = selected.byteCount
    private val source = AtomicReference<AccountBackupBytes?>(selected)
    private val retired = AtomicBoolean(false)

    /** Called only after explicit confirmation by the exact controller operation that chose the file.
     * The full app-owned exclusion remains mandatory. The native/profile component cannot supply it. */
    suspend fun confirm(
        originalGrant: PickerToolsActionGrant,
        external: AccountFileRestoreExternalExclusion,
    ): AccountFileRestoreTransaction.Result {
        currentCoroutineContext().ensureActive()
        if (originalGrant !== grant || !isCurrent()) retireResult()
        val bytes = source.getAndSet(null) ?: retireResult()
        return bytes.use {
            if (!isCurrent()) retireResult()
            val raw = bytes.copyBytes()
            try {
                val result = manager.restoreAccountBackupFile(owner, raw, ::isCurrent, external)
                currentCoroutineContext().ensureActive()
                if (!isCurrent()) retireResult()
                result
            } finally { raw.fill(0) }
        }
    }

    private fun isCurrent(): Boolean =
        !retired.get() && routeCurrent() && manager.isPickerAccountCurrent(owner)

    override fun close() {
        retired.set(true)
        source.getAndSet(null)?.close()
    }

    companion object {
        suspend fun read(
            documents: AccountBackupDocuments,
            uri: Uri,
            manager: VortXSyncManager,
            grant: PickerToolsActionGrant,
            routeCurrent: () -> Boolean,
        ): PickerToolsRestoreSelection {
            val owner = grant.original?.takeIf { it.account != null } ?: retireResult()
            fun isCurrent() = routeCurrent() && manager.isPickerAccountCurrent(owner)
            if (!isCurrent()) retireResult()
            val selected = documents.read(uri, ::isCurrent)
            try {
                currentCoroutineContext().ensureActive()
                if (!isCurrent()) retireResult()
                return PickerToolsRestoreSelection(manager, grant, owner, routeCurrent, selected)
            } catch (failure: Throwable) {
                selected.close()
                throw failure
            }
        }

        private fun retireResult(): Nothing = throw CancellationException("Account file restore selection retired")
    }
}
