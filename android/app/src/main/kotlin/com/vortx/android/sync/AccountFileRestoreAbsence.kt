package com.vortx.android.sync

import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.engine.VortxAccountScope
import kotlin.coroutines.cancellation.CancellationException

/** Combines distinct observations under the manager's original owner and mutation exclusion.
 * A successful observation does not reserve any store or grant permission to submit a Restore. */
internal object AccountFileRestoreAbsence {
    enum class Area {
        MANAGER, NATIVE, SYNC_BOOKKEEPING, DIRTY_SETTINGS, ROSTER_AND_OVERLAYS,
        LIBRARY_AND_ADDON_INTENTS, LIBRARY_PUBLICATION, ADDON_PUBLICATION, WATCHED_INTENTS,
        PROVIDER_VAULT, QUALIFIED_PROVIDER_STORAGE, EXTERNAL_PROVIDER_QUEUE,
    }

    data class Refusal(val area: Area, val presence: AccountFileLocalPresence)

    /** Every family is mandatory. Use UNAVAILABLE while a real, read-only witness is missing. */
    class Witnesses(
        val manager: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val native: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val syncBookkeeping: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val dirtySettings: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val rosterAndOverlays: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val libraryAndAddonIntents: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val libraryPublication: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val addonPublication: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val watchedIntents: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val providerVault: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val qualifiedProviderStorage: suspend (VortxAccountScope) -> AccountFileLocalPresence,
        val externalProviderQueue: suspend (VortxAccountScope) -> AccountFileLocalPresence,
    )

    suspend fun firstRefusal(scope: VortxAccountScope, witnesses: Witnesses,
                             checkCurrent: () -> Unit): Refusal? {
        val checks: List<Pair<Area, suspend (VortxAccountScope) -> AccountFileLocalPresence>> = listOf(
            Area.MANAGER to witnesses.manager,
            Area.NATIVE to witnesses.native,
            Area.SYNC_BOOKKEEPING to witnesses.syncBookkeeping,
            Area.DIRTY_SETTINGS to witnesses.dirtySettings,
            Area.ROSTER_AND_OVERLAYS to witnesses.rosterAndOverlays,
            Area.LIBRARY_AND_ADDON_INTENTS to witnesses.libraryAndAddonIntents,
            Area.LIBRARY_PUBLICATION to witnesses.libraryPublication,
            Area.ADDON_PUBLICATION to witnesses.addonPublication,
            Area.WATCHED_INTENTS to witnesses.watchedIntents,
            Area.PROVIDER_VAULT to witnesses.providerVault,
            Area.QUALIFIED_PROVIDER_STORAGE to witnesses.qualifiedProviderStorage,
            Area.EXTERNAL_PROVIDER_QUEUE to witnesses.externalProviderQueue,
        )
        for ((area, read) in checks) {
            checkCurrent()
            val presence = try {
                read(scope)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                AccountFileLocalPresence.UNAVAILABLE
            }
            checkCurrent()
            if (presence != AccountFileLocalPresence.ABSENT) return Refusal(area, presence)
        }
        return null
    }
}
