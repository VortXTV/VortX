package com.vortx.android.downloads

import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [DownloadQueuePolicy]: the pure core of the offline-download QUEUE state machine and STORAGE
 * accounting. These run on a plain JVM (no emulator, no Robolectric) precisely because the policy is framework-free
 * and depends only on the Android-free [DownloadRecord] value type, which is the whole reason the logic was pulled
 * out of the [DownloadManager] / [DownloadStore] singletons (both of which are welded to Context / WorkManager /
 * StatFs / SharedPreferences and cannot be exercised here).
 *
 * Coverage targets the two areas the manager most easily gets subtly wrong:
 *  - the concurrency-cap gate + the reorderable queued drain order (the "queue state machine"), and
 *  - the resumed-transfer shortfall math + the per-folder recorded-size sum (the "storage accounting"),
 * including the specific regressions their inline predecessors were written to avoid (the double-counted resume
 * false-fail, the unplaced-id ordering, the at-the-end reorder no-op).
 */
class DownloadQueuePolicyTest {

    private val range = 1..5

    private fun rec(
        id: String,
        state: DownloadState = DownloadState.QUEUED,
        addedAt: Long = 0L,
        bytesDone: Long = 0L,
        bytesTotal: Long = 0L,
    ): DownloadRecord = DownloadRecord(
        id = id,
        contentId = "series-1",
        videoId = "video-$id",
        type = "movie",
        name = "Title $id",
        remoteURL = "https://example.test/$id",
        localFilename = "$id.mp4",
        state = state,
        addedAt = addedAt,
        bytesDone = bytesDone,
        bytesTotal = bytesTotal,
    )

    // MARK: clampConcurrency

    @Test
    fun `clampConcurrency pins a value below the range to the lower bound`() {
        assertEquals(1, DownloadQueuePolicy.clampConcurrency(0, range))
        assertEquals(1, DownloadQueuePolicy.clampConcurrency(-7, range))
    }

    @Test
    fun `clampConcurrency pins a value above the range to the upper bound`() {
        assertEquals(5, DownloadQueuePolicy.clampConcurrency(6, range))
        assertEquals(5, DownloadQueuePolicy.clampConcurrency(999, range))
    }

    @Test
    fun `clampConcurrency leaves an in-range value untouched`() {
        assertEquals(1, DownloadQueuePolicy.clampConcurrency(1, range))
        assertEquals(3, DownloadQueuePolicy.clampConcurrency(3, range))
        assertEquals(5, DownloadQueuePolicy.clampConcurrency(5, range))
    }

    // MARK: canStartNow (the cap gate)

    @Test
    fun `canStartNow is true only while strictly fewer than cap transfers are live`() {
        assertTrue(DownloadQueuePolicy.canStartNow(activeCount = 0, cap = 2))
        assertTrue(DownloadQueuePolicy.canStartNow(activeCount = 1, cap = 2))
    }

    @Test
    fun `canStartNow is false at and past the cap`() {
        assertFalse(DownloadQueuePolicy.canStartNow(activeCount = 2, cap = 2))
        // Defensive: an over-count (should never happen) must still gate, not wrap into "free slot".
        assertFalse(DownloadQueuePolicy.canStartNow(activeCount = 3, cap = 2))
    }

    // MARK: orderedQueued (reorderable drain order)

    @Test
    fun `orderedQueued keeps only queued records`() {
        val records = listOf(
            rec("a", state = DownloadState.DOWNLOADING),
            rec("b", state = DownloadState.QUEUED),
            rec("c", state = DownloadState.COMPLETED),
            rec("d", state = DownloadState.PAUSED),
            rec("e", state = DownloadState.QUEUED),
            rec("f", state = DownloadState.FAILED),
        )
        val ids = DownloadQueuePolicy.orderedQueued(records, order = emptyList()).map { it.id }
        assertEquals(listOf("b", "e"), ids)
    }

    @Test
    fun `orderedQueued with no explicit order drains oldest addedAt first`() {
        val records = listOf(
            rec("young", state = DownloadState.QUEUED, addedAt = 300),
            rec("old", state = DownloadState.QUEUED, addedAt = 100),
            rec("mid", state = DownloadState.QUEUED, addedAt = 200),
        )
        val ids = DownloadQueuePolicy.orderedQueued(records, order = emptyList()).map { it.id }
        assertEquals(listOf("old", "mid", "young"), ids)
    }

    @Test
    fun `orderedQueued honours the explicit order ahead of addedAt`() {
        val records = listOf(
            rec("a", state = DownloadState.QUEUED, addedAt = 100),
            rec("b", state = DownloadState.QUEUED, addedAt = 200),
            rec("c", state = DownloadState.QUEUED, addedAt = 300),
        )
        // User dragged c to the front and a to the back.
        val ids = DownloadQueuePolicy.orderedQueued(records, order = listOf("c", "b", "a")).map { it.id }
        assertEquals(listOf("c", "b", "a"), ids)
    }

    @Test
    fun `orderedQueued places explicitly-ordered ids ahead of unplaced ones, unplaced by addedAt`() {
        val records = listOf(
            rec("placedLate", state = DownloadState.QUEUED, addedAt = 10),
            rec("unplacedYoung", state = DownloadState.QUEUED, addedAt = 400),
            rec("placedEarly", state = DownloadState.QUEUED, addedAt = 20),
            rec("unplacedOld", state = DownloadState.QUEUED, addedAt = 300),
        )
        // Only two ids are placed; the two unplaced ids must follow, in addedAt order.
        val ids = DownloadQueuePolicy.orderedQueued(records, order = listOf("placedEarly", "placedLate")).map { it.id }
        assertEquals(listOf("placedEarly", "placedLate", "unplacedOld", "unplacedYoung"), ids)
    }

    @Test
    fun `orderedQueued ignores order ids that are not queued`() {
        val records = listOf(
            rec("q", state = DownloadState.QUEUED, addedAt = 100),
        )
        // "gone" is in the persisted order but has no queued record; it must simply not appear.
        val ids = DownloadQueuePolicy.orderedQueued(records, order = listOf("gone", "q")).map { it.id }
        assertEquals(listOf("q"), ids)
    }

    // MARK: reorder

    @Test
    fun `reorder moves an id one place earlier`() {
        assertEquals(
            listOf("a", "c", "b", "d"),
            DownloadQueuePolicy.reorder(listOf("a", "b", "c", "d"), id = "c", delta = -1),
        )
    }

    @Test
    fun `reorder moves an id one place later`() {
        assertEquals(
            listOf("a", "c", "b", "d"),
            DownloadQueuePolicy.reorder(listOf("a", "b", "c", "d"), id = "b", delta = +1),
        )
    }

    @Test
    fun `reorder returns null moving the first item earlier`() {
        assertNull(DownloadQueuePolicy.reorder(listOf("a", "b", "c"), id = "a", delta = -1))
    }

    @Test
    fun `reorder returns null moving the last item later`() {
        assertNull(DownloadQueuePolicy.reorder(listOf("a", "b", "c"), id = "c", delta = +1))
    }

    @Test
    fun `reorder returns null for an id that is not present`() {
        assertNull(DownloadQueuePolicy.reorder(listOf("a", "b", "c"), id = "z", delta = -1))
    }

    @Test
    fun `reorder does not mutate its input`() {
        val original = listOf("a", "b", "c")
        DownloadQueuePolicy.reorder(original, id = "a", delta = +1)
        assertEquals(listOf("a", "b", "c"), original)
    }

    // MARK: hasStorageShortfall (the resumed-transfer math)

    @Test
    fun `hasStorageShortfall allows an unknown size through`() {
        // Every fresh download and every torrent starts with bytesTotal == 0; the worker re-checks later.
        assertFalse(DownloadQueuePolicy.hasStorageShortfall(bytesTotal = 0, bytesDone = 0, freeBytes = 1, marginBytes = 0))
    }

    @Test
    fun `hasStorageShortfall allows a completed transfer through`() {
        // bytesDone >= bytesTotal means nothing remains to write, so it can never short the volume.
        assertFalse(
            DownloadQueuePolicy.hasStorageShortfall(
                bytesTotal = 1_000, bytesDone = 1_000, freeBytes = 0, marginBytes = 0,
            ),
        )
    }

    @Test
    fun `hasStorageShortfall is true when the remaining bytes plus margin exceed free space`() {
        // remaining = 1000, margin = 200, need 1200 but only 1199 free.
        assertTrue(
            DownloadQueuePolicy.hasStorageShortfall(
                bytesTotal = 1_000, bytesDone = 0, freeBytes = 1_199, marginBytes = 200,
            ),
        )
    }

    @Test
    fun `hasStorageShortfall is false when free space exactly covers remaining plus margin`() {
        // Boundary: free == remaining + margin is NOT a shortfall (strict less-than).
        assertFalse(
            DownloadQueuePolicy.hasStorageShortfall(
                bytesTotal = 1_000, bytesDone = 0, freeBytes = 1_200, marginBytes = 200,
            ),
        )
    }

    @Test
    fun `hasStorageShortfall weighs only remaining bytes on a nearly-complete resume`() {
        // The regression guard: a 10 GB title 99 percent done has ~100 MB left. With ~150 MB free it must NOT
        // false-fail as "not enough storage" (the double-count bug), because the 9.9 GB already written is on disk.
        val tenGB = 10L * 1024 * 1024 * 1024
        val ninetyNinePercent = (tenGB * 99) / 100
        val hundredFiftyMB = 150L * 1024 * 1024
        assertFalse(
            DownloadQueuePolicy.hasStorageShortfall(
                bytesTotal = tenGB, bytesDone = ninetyNinePercent, freeBytes = hundredFiftyMB, marginBytes = 0,
            ),
        )
        // Naive `free < total` would have compared 150 MB against 10 GB and wrongly failed it; assert that the
        // FULL-size comparison really would have been a shortfall, so this test pins the difference, not a tautology.
        assertTrue(hundredFiftyMB < tenGB)
    }

    // MARK: recordedSizeBytes (per-folder accounting)

    @Test
    fun `recordedSizeBytes of no records is zero`() {
        assertEquals(0L, DownloadQueuePolicy.recordedSizeBytes(emptyList()))
    }

    @Test
    fun `recordedSizeBytes sums the larger of done or total per record`() {
        val records = listOf(
            rec("done", bytesDone = 500, bytesTotal = 500),      // completed: 500
            rec("inflight", bytesDone = 120, bytesTotal = 800),  // downloading: total wins -> 800
            rec("unsized", bytesDone = 300, bytesTotal = 0),     // no declared total: done wins -> 300
        )
        assertEquals(1_600L, DownloadQueuePolicy.recordedSizeBytes(records))
    }
}
