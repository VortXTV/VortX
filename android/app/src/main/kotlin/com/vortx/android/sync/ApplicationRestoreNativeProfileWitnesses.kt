package com.vortx.android.sync

import com.vortx.android.VortXApplication
import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.engine.NativeAccountCoordinator
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.profile.ProfileStore
import java.util.concurrent.atomic.AtomicReference

/** The application's native slot and existing profile/tombstone evidence are two parts of Restore
 * admission. This type cannot be installed as the manager's complete external exclusion. */
internal class ApplicationRestoreNativeProfileWitnesses private constructor(
    private val original: AccountFileRestoreExternalExclusion.Owner,
    private val native: NativeAccountCoordinator.RestoreNativeExclusion,
    private val profileWriters: ProfileStore.HeldRestoreDirectExclusion,
    private val requireApplicationOwner: () -> Unit,
) {
    private class Bound(val scope: VortxAccountScope, val profile: ProfileStore.RestoreDirectState.Absent)
    private val bound = AtomicReference<Bound?>(null)

    /** Safe for transport checks. The two underlying issuer checks perform no disk or native I/O. */
    fun requireCurrent(owner: AccountFileRestoreExternalExclusion.Owner) {
        if (owner !== original) refuse(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
        requireApplicationOwner()
        val captured = bound.get()
        native.requireCurrent(owner.account, captured?.scope)
        profileWriters.requireCurrent(owner.account)
        captured?.profile?.requireCurrent(owner.account)
        requireApplicationOwner()
    }

    /** Existing-only worker reads. Never replace an earlier revoked observation with a fresh one. */
    fun requireAbsenceOnWorker(owner: AccountFileRestoreExternalExclusion.Owner, scope: VortxAccountScope) {
        requireCurrent(owner)
        when (native.inspectAbsenceOnWorker(owner.account, scope)) {
            AccountFileLocalPresence.ABSENT -> Unit
            AccountFileLocalPresence.PRESENT -> refuse(AccountFileRestoreTransaction.Reason.PENDING_LOCAL_CHANGES)
            AccountFileLocalPresence.UNAVAILABLE -> refuse(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
        }
        val observation = when (val state = profileWriters.inspectStateOnWorker(owner.account)) {
            is ProfileStore.RestoreDirectState.Absent -> state
            ProfileStore.RestoreDirectState.Present -> refuse(AccountFileRestoreTransaction.Reason.PENDING_LOCAL_CHANGES)
            ProfileStore.RestoreDirectState.Unavailable -> refuse(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
        }
        requireCurrent(owner)
        observation.requireCurrent(owner.account)
        bound.compareAndSet(null, Bound(scope, observation))
        if (bound.get()?.scope != scope) refuse(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
        requireCurrent(owner)
    }

    companion object {
        /** Only actual application owners issue this scoped capability. Never open a ProfileStore here. */
        suspend fun <T : Any> withHeld(
            application: VortXApplication,
            manager: VortXSyncManager,
            original: AccountFileRestoreExternalExclusion.Owner,
            requireOriginal: () -> Unit,
            operation: suspend (ApplicationRestoreNativeProfileWitnesses) -> T,
        ): T? {
            requireOriginal()
            val profiles = ProfileStore.sharedOrNull() ?: refuse(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
            fun requireApplicationOwner() {
                requireOriginal()
                if (application.syncManager !== manager || ProfileStore.sharedOrNull() !== profiles)
                    refuse(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
            }
            requireApplicationOwner()
            return application.nativeStreamingAccounts().withRestoreNativeExclusion(original.account, ::requireApplicationOwner) { native ->
                profiles.withRestoreDirectExclusion(original.account, ::requireApplicationOwner) { profileWriters ->
                    operation(ApplicationRestoreNativeProfileWitnesses(original, native, profileWriters, ::requireApplicationOwner))
                } ?: refuse(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE)
            }
        }

        private fun refuse(reason: AccountFileRestoreTransaction.Reason): Nothing =
            throw AccountFileRestoreTransaction.Refusal(reason)
    }
}
