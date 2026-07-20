package com.vortx.android.downloads

import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState

/**
 * The pure, framework-free decisions behind the offline-download QUEUE state machine and STORAGE accounting.
 *
 * Every function here is a total function of its arguments: no [android.content.Context], no WorkManager, no
 * [android.os.StatFs], no SharedPreferences, no clock, no I/O, no logging. [DownloadManager] and [DownloadStore]
 * own all of that (the live index StateFlow, the WorkManager enqueue, the StatFs read, the prefs) and DELEGATE the
 * arithmetic + ordering here. That split is deliberate: the parts that are easy to get subtly wrong -- the
 * concurrency-cap gate, the reorder bounds, the queued drain order, the resumed-transfer storage math, the
 * per-folder size sum -- become unit-testable on a plain JVM with no emulator, because they depend on nothing but
 * their inputs and the [DownloadRecord] value type (itself Android-free).
 *
 * Apple keeps the same logic inline in `DownloadManager.swift`; pulling it into one named, side-effect-free place is
 * what makes it verifiable here without changing any behaviour. Each function below documents the exact invariant it
 * encodes so the manager's call site reads as a statement of intent rather than an ad-hoc expression.
 */
internal object DownloadQueuePolicy {

    // MARK: Concurrency cap

    /** Clamp a user-chosen concurrency cap into the allowed [range]. Mirrors Apple's `clampConcurrency`. */
    fun clampConcurrency(value: Int, range: IntRange): Int = value.coerceIn(range)

    /**
     * True when a new transfer may start right now: strictly fewer than [cap] transfers are already live. This is the
     * one gate every start path funnels through (create, resume, queue drain, cap raise), so keeping it here means
     * the cap can never be enforced with an off-by-one at one site and a `>=` at another.
     */
    fun canStartNow(activeCount: Int, cap: Int): Boolean = activeCount < cap

    // MARK: Queue drain order (reorderable)

    /**
     * The QUEUED records in the exact order they will start: explicit [order] first (a user reorder), then `addedAt`
     * for any id not yet placed in [order]. Filters [records] to [DownloadState.QUEUED] itself, so the caller can
     * pass the whole index. An id present in [order] but no longer queued is simply absent from the result (the
     * filter drops it), which is why the manager can leave stale ids in the persisted order without harm.
     *
     * ORDERING RULE (identical to Apple's `orderedQueuedRecords`): an item WITH an explicit rank precedes one
     * WITHOUT (an unplaced id is treated as rank `Int.MAX_VALUE`); among placed items, lower rank first; ties (only
     * possible among unplaced items, since ranks are unique list indices) break by earliest `addedAt`.
     */
    fun orderedQueued(records: List<DownloadRecord>, order: List<String>): List<DownloadRecord> {
        val rank = order.withIndex().associate { (index, id) -> id to index }
        return records
            .filter { it.state == DownloadState.QUEUED }
            .sortedWith(compareBy({ rank[it.id] ?: Int.MAX_VALUE }, { it.addedAt }))
    }

    /**
     * Move [id] one place earlier ([delta] = -1) or later ([delta] = +1) within [ids], returning the new order, or
     * null when there is nothing to do: [id] is not present, or it is already at the end it is being moved toward
     * (the swap target is out of bounds). Returning null (rather than an unchanged copy) lets the caller skip the
     * persist + publish entirely on a no-op, matching Apple's `reorderQueued` guard.
     *
     * Kept general over [delta] rather than hard-coding +/-1 so a future multi-step move needs no new policy; the
     * bounds check ([to] in indices) makes any delta safe.
     */
    fun reorder(ids: List<String>, id: String, delta: Int): List<String>? {
        val from = ids.indexOf(id)
        if (from < 0) return null
        val to = from + delta
        if (to !in ids.indices) return null
        val mutable = ids.toMutableList()
        java.util.Collections.swap(mutable, from, to)
        return mutable
    }

    // MARK: Storage accounting

    /**
     * True when the volume cannot hold what still has to be written, so the transfer should fail EARLY with a clear
     * message instead of running a full multi-GB download that ends in an opaque write error. The manager supplies
     * [freeBytes] (the StatFs read) and the [marginBytes] headroom; this holds the rule.
     *
     * Only a HARD shortfall is a shortfall:
     *  - an UNKNOWN size ([bytesTotal] <= 0, which is every fresh download and every torrent) is allowed through: the
     *    worker re-checks once a real Content-Length is known;
     *  - only the REMAINING bytes ([bytesTotal] - [bytesDone]) are weighed, never the full size, so a nearly-complete
     *    resume whose downloaded bytes already occupy the volume is not double-counted and false-failed as "not enough
     *    storage" with ample free space (the exact bug Apple fixed, and the reason a naive `free < total` is wrong).
     */
    fun hasStorageShortfall(bytesTotal: Long, bytesDone: Long, freeBytes: Long, marginBytes: Long): Boolean {
        if (bytesTotal <= 0) return false
        val remaining = (bytesTotal - bytesDone).coerceAtLeast(0)
        if (remaining == 0L) return false
        return freeBytes < remaining + marginBytes
    }

    /**
     * Recorded byte total for a set of records: the larger of done/total per record, summed. Reads the INDEX values
     * only (no filesystem stat), so it is cheap enough to call while rendering a grouped list. `max(done, total)`
     * (not `total`) means an in-flight item still contributes the bytes it has actually pulled, and a completed item
     * whose recorded total lagged its final bytes still reports honestly. Feeds [DownloadStore.recordedSize].
     */
    fun recordedSizeBytes(records: List<DownloadRecord>): Long =
        records.sumOf { maxOf(it.bytesDone, it.bytesTotal) }
}
