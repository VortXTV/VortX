package com.vortx.android.sync

import com.vortx.android.VortXApplication
import com.vortx.android.engine.VortxAccountScope

/** The application side of the manager's Restore reservation. Construction does not acquire a
 * writer, open a store or publish picker authority. Only the paused recovery route may use it. */
internal class ApplicationAccountFileRestoreExclusion(
    private val application: VortXApplication,
    private val manager: VortXSyncManager,
) : AccountFileRestoreExternalExclusion {
    override suspend fun withReservation(
        original: AccountFileRestoreExternalExclusion.Owner,
        requireOriginal: () -> Unit,
        operation: suspend (AccountFileRestoreExternalExclusion.Reservation) -> Unit,
    ) {
        requireOriginal()
        if (application.syncManager !== manager) refuse(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
        val gateway = application.nativeStreamingAccounts()
        fun requirePausedOwner() {
            requireOriginal()
            if (application.syncManager !== manager || !manager.isPickerFileRecoveryOwnerCurrent(original, gateway))
                refuse(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
        }

        requirePausedOwner()
        val result = ApplicationRestoreNativeProfileWitnesses.withHeld(
            application, manager, original, ::requirePausedOwner,
        ) { nativeProfile ->
            NativeSettingsFence.withRestoreFlatSettingsExclusion(original.account, ::requirePausedOwner) { flat ->
                val held = Held(original, nativeProfile, flat, ::requirePausedOwner)
                held.requireCurrent(original)
                operation(held)
            } ?: refuse(AccountFileRestoreTransaction.Reason.BUSY)
        }
        if (result == null) refuse(AccountFileRestoreTransaction.Reason.BUSY)
    }

    private class Held(
        private val original: AccountFileRestoreExternalExclusion.Owner,
        private val nativeProfile: ApplicationRestoreNativeProfileWitnesses,
        private val flat: NativeSettingsFence.HeldRestoreFlatSettings,
        private val requirePausedOwner: () -> Unit,
    ) : AccountFileRestoreExternalExclusion.Reservation {
        override fun requireCurrent(original: AccountFileRestoreExternalExclusion.Owner) {
            if (original !== this.original) refuse(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
            requirePausedOwner()
            nativeProfile.requireCurrent(original)
            flat.requireCurrent(original.account)
            requirePausedOwner()
        }

        override fun requireLocalAbsence(original: AccountFileRestoreExternalExclusion.Owner, scope: VortxAccountScope) {
            requireCurrent(original)
            nativeProfile.requireAbsenceOnWorker(original, scope)
            requireCurrent(original)
        }
    }

    private companion object {
        fun refuse(reason: AccountFileRestoreTransaction.Reason): Nothing =
            throw AccountFileRestoreTransaction.Refusal(reason)
    }
}
