package com.vortx.android.library

import kotlinx.coroutines.flow.Flow
import org.json.JSONObject

/**
 * Injected native account boundary. The implementation owns checkpointing and host Lamport clocks;
 * the store only submits one item's value or tombstone and waits for the durable acknowledgement.
 */
internal interface NativeWatchlistGateway {
    /**
     * Opaque, immutable admission captured before a coroutine is queued. Value equality must include
     * the account epoch, exact session identity, profile/binding epoch and native read revision, not
     * merely these display identities. A later account/profile cannot authorize an older operation.
     */
    interface Owner {
        val accountId: String
        val profileId: String
    }

    /** Detached `host.profiles[profileId].fields` registers, including retained null tombstones. */
    data class Snapshot(val owner: Owner, val registers: JSONObject)

    val changes: Flow<Unit>

    /** Failure is unavailable authority, never an empty list or permission to read a local ledger. */
    fun capture(): Result<Snapshot>

    /**
     * Atomically check the exact captured revision while holding native admission, then publish.
     * Called outside the store monitor; the callback acquires only that local monitor. This closes
     * capture-to-publication races even for ordinary same-profile host-register revision changes.
     */
    fun publishIfCurrent(expected: Owner, publication: () -> Unit): Boolean

    /**
     * Values are keyed by canonical Watchlist fields; the caller supplies no clocks. Never recapture
     * authority here. Atomically admit [expected], mint registers and checkpoint, then return the
     * detached acknowledged projection with its new read revision. Failed writes publish nothing.
     */
    suspend fun mutate(expected: Owner, changes: JSONObject): Result<Snapshot>
}
