package com.vortx.android.downloads

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadManagerOwnerClaimContractTest {

    @Test
    fun freshlyReloadedRecordIsOwnerCheckedInsideClaimBeforePublication() {
        val claim = manager()
            .substringAfter("internal fun claimTransfer(")
            .substringBefore("private fun failChangedOwnerLocked(")
        assertInOrder(
            claim,
            "synchronized(lock)",
            "val record = DownloadStore.record(id)",
            "requestedGeneration = generation",
            "readOwnerStatus = ::debridOwnerStatus",
            "OwnerChanged -> return rejectChangedOwnerLocked(record)",
            "OwnerUnavailable -> return deferOwnerReadLocked(record)",
            "activeGenerations[id] = generation",
        )
        val defer = manager().substringAfter("private fun deferOwnerReadLocked(")
            .substringBefore("private fun debridOwnerStatus(")
        assertInOrder(defer, "releaseSlotReservation", "return DownloadTransferAdmission.RETRY")
        assertFalse(defer.contains("DownloadStore."))
        assertFalse(defer.contains("cancelWork("))
    }

    @Test
    fun missingOwnerAfterPreflightOrBeforeCompletionSkipsMutationsAndRetriesSameWork() {
        val manager = manager()
        val guard = manager.substringAfter("private fun checkTransferAccessLocked(")
            .substringBefore("internal fun checkTransferAccess(")
        assertInOrder(
            guard,
            "ownsTransferLocked(record, generation)",
            "debridOwnerStatus(record)",
            "Status.CHANGED -> rejectChangedOwnerLocked(record)",
            "Status.UNAVAILABLE -> deferOwnerReadLocked(record)",
        )
        val write = manager.substringAfter("internal fun performTransferFileMutation(")
            .substringBefore("fun handleTransferProgress(")
        assertInOrder(write, "synchronized(lock)", "DownloadStore.record(id)", "checkTransferAccessLocked(record, generation)", "if (admission == DownloadTransferAdmission.AUTHORIZED) mutate()")

        val complete = manager.substringAfter("internal fun handleTransferComplete(")
            .substringBefore("fun handleTransferStopped(")
        assertInOrder(
            complete,
            "synchronized(lock)",
            "DownloadStore.record(id)",
            "checkTransferAccessLocked(current, generation)",
            "if (admission != DownloadTransferAdmission.AUTHORIZED) return admission",
            "onAuthorized = finalize",
            "DownloadStore.updateIf(",
        )
        val worker = readSource("DownloadWorker.kt")
        assertInOrder(
            worker,
            "when (DownloadManager.claimTransfer(id, generation))",
            "DownloadTransferAdmission.RETRY -> return@withContext Result.retry()",
            "val prepared = transfer(record, generation)",
            "DownloadManager.handleTransferComplete",
            "finalize(prepared.partFile, prepared.destination)",
            "}.requireAccess()",
            "catch (_: DownloadOwnerReadUnavailableException)",
            "Result.retry()",
        )
        assertFalse(worker.contains("handleDebridOwnerChanged("))
        assertFalse(worker.contains("isDebridOwnerCurrent("))
    }

    @Test
    fun confirmedChangeFailsOnlyTheExactObservedRow() {
        val fail = manager().substringAfter("private fun failChangedOwnerLocked(")
            .substringBefore("private fun rejectChangedOwnerLocked(")
        assertInOrder(
            fail,
            "predicate = { it == record }",
            "state = DownloadState.FAILED, transferGeneration = null",
            "?: return false",
            "releaseSlotReservation(record.id, record.transferGeneration)",
        )
    }

    @Test
    fun queuedUnknownDoesNotBlockDirectAndParkedUnknownKeepsItsDurableId() {
        val manager = manager()
        val drain = manager.substringAfter("private fun fillAvailableSlots()")
            .substringBefore("private fun afterSlotFreed()")
        assertInOrder(
            drain,
            "for (next in orderedQueuedRecords())",
            "Status.UNAVAILABLE -> continue",
            "Status.CURRENT -> Unit",
            "startTransfer(started)",
        )
        val replay = manager.substringAfter("fun retryDownloadsAwaitingUnlock()")
            .substringBefore("fun reconcileInFlight()")
        assertInOrder(
            replay,
            "synchronized(lock)",
            "for (id in awaitingUnlock.toList())",
            "val record = DownloadStore.record(id)",
            "resumeLocked(record, debridOwnerStatus(record))",
            "fillAvailableSlots()",
        )
        assertFalse(replay.contains("awaitingUnlock.clear()"))
        val resume = manager.substringAfter("private fun resumeLocked(")
            .substringBefore("fun cancel(")
        assertInOrder(
            resume,
            "Status.UNAVAILABLE ->",
            "awaitingUnlock.add(id)",
            "return",
            "requireDurable = id in awaitingUnlock",
            "?: return",
            "awaitingUnlock.remove(id)",
        )
        val store = readSource("DownloadStore.kt")
        assertInOrder(
            store.substringAfter("internal fun updateIf("),
            "if (requireDurable && !persistLocked(updatedRecords)) return@withLock null",
            "_records.value = updatedRecords",
        )
    }

    @Test
    fun workerAndReconcilerNeverReadAReplacementAsTheOldGeneration() {
        val reconcile = manager().substringAfter("fun reconcileInFlight()")
            .substringBefore("// MARK: Helpers")
        assertInOrder(
            reconcile,
            "current.transferGeneration != generation",
            "when (debridOwnerStatus(current))",
            "Status.UNAVAILABLE ->",
            "releaseSlotReservation(record.id, generation)",
            "return@synchronized false",
        )
        assertEquals(0, Regex("activeGenerations\\[record.id]").findAll(reconcile).count())
    }

    private fun assertInOrder(source: String, vararg anchors: String) {
        var next = 0
        for (anchor in anchors) {
            val found = source.indexOf(anchor, startIndex = next)
            assertTrue("Missing or out of order: $anchor", found >= 0)
            next = found + anchor.length
        }
    }

    private fun manager(): String = readSource("DownloadManager.kt")

    private fun readSource(name: String): String {
        val relative = "src/main/kotlin/com/vortx/android/downloads/$name"
        val candidates = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $name from ${File(".").absolutePath}")
    }
}
