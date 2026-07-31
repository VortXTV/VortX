package com.vortx.android.downloads

import com.vortx.android.model.DownloadState
import java.io.EOFException
import java.net.ProtocolException
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadTransferPolicyTest {

    @Test
    fun `known response length must match the completed file exactly`() {
        assertTrue(DownloadTransferPolicy.hasCompleteLength(declaredBytes = 4_000, actualBytes = 4_000))
        assertFalse(DownloadTransferPolicy.hasCompleteLength(declaredBytes = 4_000, actualBytes = 3_999))
        assertFalse(DownloadTransferPolicy.hasCompleteLength(declaredBytes = 4_000, actualBytes = 4_001))
    }

    @Test
    fun `unknown response length accepts a nonempty completed file`() {
        assertTrue(DownloadTransferPolicy.hasCompleteLength(declaredBytes = 0, actualBytes = 1))
        assertTrue(DownloadTransferPolicy.hasCompleteLength(declaredBytes = -1, actualBytes = 9_000))
        assertFalse(DownloadTransferPolicy.hasCompleteLength(declaredBytes = 0, actualBytes = 0))
    }

    @Test
    fun `unknown resumed response length retains the previously known total`() {
        val expectedTotal = requireNotNull(
            DownloadTransferPolicy.resolveExpectedTotal(
                responseTotal = 0,
                knownTotal = 9_000,
                isPartialResponse = true,
            ),
        )

        assertEquals(9_000L, expectedTotal)
        assertFalse(DownloadTransferPolicy.hasCompleteLength(expectedTotal, actualBytes = 8_999))
        assertTrue(DownloadTransferPolicy.hasCompleteLength(expectedTotal, actualBytes = 9_000))
    }

    @Test
    fun `usable response total replaces the previously known total`() {
        assertEquals(
            10_000L,
            DownloadTransferPolicy.resolveExpectedTotal(
                responseTotal = 10_000,
                knownTotal = 9_000,
                isPartialResponse = false,
            ),
        )
    }

    @Test
    fun `resumed unknown range total keeps known representation total and ignores response length`() {
        val range = DownloadTransferPolicy.contentRangeForResume(
            value = "bytes 4000-4999/*",
            requestedOffset = 4_000,
        )
        val responseTotal = DownloadTransferPolicy.representationTotal(
            contentRange = range,
            contentLength = 1_000,
        )

        assertEquals(0L, responseTotal)
        assertEquals(
            9_000L,
            DownloadTransferPolicy.resolveExpectedTotal(
                responseTotal = responseTotal,
                knownTotal = 9_000,
                isPartialResponse = true,
            ),
        )
    }

    @Test
    fun `resumed explicit total must agree with the known representation total`() {
        val range = requireNotNull(
            DownloadTransferPolicy.contentRangeForResume(
                value = "bytes 4000-4999/10000",
                requestedOffset = 4_000,
            ),
        )
        assertNull(
            DownloadTransferPolicy.resolveExpectedTotal(
                responseTotal = DownloadTransferPolicy.representationTotal(range, contentLength = 1_000),
                knownTotal = 9_000,
                isPartialResponse = true,
            ),
        )
    }

    @Test
    fun `resumed transfer with no known or explicit total fails closed`() {
        assertNull(
            DownloadTransferPolicy.resolveExpectedTotal(
                responseTotal = 0,
                knownTotal = 0,
                isPartialResponse = true,
            ),
        )
    }

    @Test
    fun `multi gigabyte process death resume retains total and reconciles bytes done`() {
        val gib = 1_024L * 1_024L * 1_024L
        val total = 12 * gib
        val partial = 4 * gib
        val firstResponse = requireNotNull(
            DownloadTransferPolicy.reconcileProgress(
                responseTotal = total,
                knownTotal = 0,
                isPartialResponse = false,
                startAt = 0,
            ),
        )
        val starRange = requireNotNull(
            DownloadTransferPolicy.contentRangeForResume(
                value = "bytes $partial-${partial + gib - 1}/*",
                requestedOffset = partial,
            ),
        )
        val explicitRange = requireNotNull(
            DownloadTransferPolicy.contentRangeForResume(
                value = "bytes $partial-${partial + gib - 1}/$total",
                requestedOffset = partial,
            ),
        )
        val changedRange = requireNotNull(
            DownloadTransferPolicy.contentRangeForResume(
                value = "bytes $partial-${partial + gib - 1}/${total + 1}",
                requestedOffset = partial,
            ),
        )

        val resumedFromStar = requireNotNull(
            DownloadTransferPolicy.reconcileProgress(
                responseTotal = DownloadTransferPolicy.representationTotal(starRange, contentLength = gib),
                knownTotal = firstResponse.bytesTotal,
                isPartialResponse = true,
                startAt = partial,
            ),
        )
        val resumedFromExplicit = requireNotNull(
            DownloadTransferPolicy.reconcileProgress(
                responseTotal = DownloadTransferPolicy.representationTotal(explicitRange, contentLength = gib),
                knownTotal = firstResponse.bytesTotal,
                isPartialResponse = true,
                startAt = partial,
            ),
        )

        assertEquals(total, firstResponse.bytesTotal)
        assertEquals(total, resumedFromStar.bytesTotal)
        assertEquals(partial, resumedFromStar.bytesDone)
        assertEquals(total, resumedFromExplicit.bytesTotal)
        assertEquals(partial, resumedFromExplicit.bytesDone)
        assertNull(
            DownloadTransferPolicy.reconcileProgress(
                responseTotal = DownloadTransferPolicy.representationTotal(changedRange, contentLength = gib),
                knownTotal = firstResponse.bytesTotal,
                isPartialResponse = true,
                startAt = partial,
            ),
        )
    }

    @Test
    fun `offset zero partial response with unknown representation total fails closed`() {
        val hostileRange = requireNotNull(
            DownloadTransferPolicy.contentRangeForResume(
                value = "bytes 0-999/*",
                requestedOffset = 0,
            ),
        )

        assertNull(
            DownloadTransferPolicy.reconcileProgress(
                responseTotal = DownloadTransferPolicy.representationTotal(
                    hostileRange,
                    contentLength = 1_000,
                ),
                knownTotal = 0,
                isPartialResponse = true,
                startAt = 0,
            ),
        )
    }

    @Test
    fun `content range accepts the exact requested resume offset`() {
        val range = DownloadTransferPolicy.contentRangeForResume(
            value = "bytes 4000-8999/9000",
            requestedOffset = 4_000,
        )

        assertEquals(4_000L, range?.start)
        assertEquals(8_999L, range?.endInclusive)
        assertEquals(9_000L, range?.totalBytes)
    }

    @Test
    fun `content range rejects a mismatched resume offset`() {
        assertNull(
            DownloadTransferPolicy.contentRangeForResume(
                value = "bytes 3000-8999/9000",
                requestedOffset = 4_000,
            ),
        )
    }

    @Test
    fun `content range rejects malformed and internally inconsistent values`() {
        assertNull(DownloadTransferPolicy.contentRangeForResume("bytes nope", requestedOffset = 4_000))
        assertNull(DownloadTransferPolicy.contentRangeForResume("bytes 4000-3999/9000", requestedOffset = 4_000))
        assertNull(DownloadTransferPolicy.contentRangeForResume("bytes 4000-9000/9000", requestedOffset = 4_000))
        assertNull(
            DownloadTransferPolicy.contentRangeForResume(
                "bytes 4000-8999/999999999999999999999999",
                requestedOffset = 4_000,
            ),
        )
        assertNull(DownloadTransferPolicy.contentRangeForResume(null, requestedOffset = 4_000))
    }

    @Test
    fun `retry state policy preserves every resting state`() {
        assertTrue(DownloadTransferPolicy.mayRetryRecord(DownloadState.DOWNLOADING))
        assertFalse(DownloadTransferPolicy.mayRetryRecord(DownloadState.QUEUED))
        assertFalse(DownloadTransferPolicy.mayRetryRecord(DownloadState.PAUSED))
        assertFalse(DownloadTransferPolicy.mayRetryRecord(DownloadState.COMPLETED))
        assertFalse(DownloadTransferPolicy.mayRetryRecord(DownloadState.FAILED))
    }

    @Test
    fun `complete partial is finalized locally before another range request`() {
        assertTrue(DownloadTransferPolicy.shouldFinalizeLocalPartial(knownTotal = 9_000, partialBytes = 9_000))
        assertFalse(DownloadTransferPolicy.shouldFinalizeLocalPartial(knownTotal = 9_000, partialBytes = 8_999))
        assertFalse(DownloadTransferPolicy.shouldFinalizeLocalPartial(knownTotal = 0, partialBytes = 9_000))
    }

    @Test
    fun `range body extent rejects both short and overlong responses`() {
        val range = requireNotNull(
            DownloadTransferPolicy.contentRangeForResume(
                value = "bytes 4000-4999/9000",
                requestedOffset = 4_000,
            ),
        )

        assertTrue(DownloadTransferPolicy.hasExactRangeBodyLength(range, actualBytes = 1_000))
        assertFalse(DownloadTransferPolicy.hasExactRangeBodyLength(range, actualBytes = 999))
        assertFalse(DownloadTransferPolicy.hasExactRangeBodyLength(range, actualBytes = 1_001))
    }

    @Test
    fun `range ignored restart resets storage accounting to zero`() {
        assertFalse(
            DownloadQueuePolicy.hasStorageShortfall(
                bytesTotal = 9_000,
                bytesDone = 8_000,
                freeBytes = 8_999,
                marginBytes = 0,
            ),
        )
        val bytesDone = DownloadTransferPolicy.bytesDoneForResponse(
            restartingFromZero = true,
            previousBytesDone = 8_000,
        )

        assertEquals(0L, bytesDone)
        assertTrue(
            DownloadQueuePolicy.hasStorageShortfall(
                bytesTotal = 9_000,
                bytesDone = bytesDone,
                freeBytes = 8_999,
                marginBytes = 0,
            ),
        )
    }

    @Test
    fun `write retry budget allows only the initial durable work attempt`() {
        assertTrue(DownloadTransferPolicy.canRetryWrite(runAttemptCount = 0))
        assertFalse(DownloadTransferPolicy.canRetryWrite(runAttemptCount = 1))
        assertFalse(DownloadTransferPolicy.canRetryWrite(runAttemptCount = 2))
    }

    @Test
    fun `process recreation cannot regrant write retry within the same work generation`() {
        val persistedRunAttemptCount = 1

        assertFalse(DownloadTransferPolicy.canRetryWrite(persistedRunAttemptCount))
    }

    @Test
    fun `resume accepts only paused and failed records`() {
        assertTrue(DownloadTransferStatePolicy.mayResume(DownloadState.PAUSED))
        assertTrue(DownloadTransferStatePolicy.mayResume(DownloadState.FAILED))
        assertFalse(DownloadTransferStatePolicy.mayResume(DownloadState.QUEUED))
        assertFalse(DownloadTransferStatePolicy.mayResume(DownloadState.DOWNLOADING))
        assertFalse(DownloadTransferStatePolicy.mayResume(DownloadState.COMPLETED))
    }

    @Test
    fun `strong etag is required before a partial can issue range`() {
        assertEquals("\"v1\"", DownloadTransferPolicy.strongETag("\"v1\""))
        assertNull(DownloadTransferPolicy.strongETag("W/\"v1\""))
        assertNull(DownloadTransferPolicy.strongETag("v1"))
        assertNull(DownloadTransferPolicy.strongETag(null))
        assertEquals(
            4_096L,
            DownloadTransferPolicy.resumeOffset(partialBytes = 4_096, representationETag = "\"v1\""),
        )
        assertEquals(
            0L,
            DownloadTransferPolicy.resumeOffset(partialBytes = 4_096, representationETag = null),
        )
    }

    @Test
    fun `same length remote replacement cannot be appended`() {
        assertFalse(
            DownloadTransferPolicy.canAppendRange(
                requestedOffset = 4_096,
                persistedETag = "\"old\"",
                responseETag = "\"replacement\"",
            ),
        )
        assertFalse(
            DownloadTransferPolicy.canAppendRange(
                requestedOffset = 4_096,
                persistedETag = "\"old\"",
                responseETag = null,
            ),
        )
        assertTrue(
            DownloadTransferPolicy.canAppendRange(
                requestedOffset = 4_096,
                persistedETag = "\"same\"",
                responseETag = "\"same\"",
            ),
        )
    }

    @Test
    fun `stale reconciliation snapshot never selects replacement generation`() {
        val candidates = listOf(
            DownloadWorkSnapshot(id = "stale-a", generation = "generation-a", isFinished = false),
            DownloadWorkSnapshot(id = "replacement-b", generation = "generation-b", isFinished = false),
            DownloadWorkSnapshot(id = "finished-a", generation = "generation-a", isFinished = true),
        )

        assertEquals(
            listOf("stale-a"),
            DownloadReconciliationPolicy.cancellableWorkIds("generation-a", candidates),
        )
        assertFalse(DownloadReconciliationPolicy.hasLiveGeneration("missing", candidates))
    }

    @Test
    fun `legacy reconciliation cancellation excludes tagged replacement work`() {
        val candidates = listOf(
            DownloadWorkSnapshot(id = "legacy", generation = null, isFinished = false),
            DownloadWorkSnapshot(id = "replacement", generation = "generation-b", isFinished = false),
        )

        assertEquals(listOf("legacy"), DownloadReconciliationPolicy.cancellableWorkIds(null, candidates))
        assertEquals(
            "generation-b",
            DownloadWorker.generationFromTags(
                setOf("unrelated", DownloadWorker.generationTag("generation-b")),
            ),
        )
        assertNull(
            DownloadWorker.generationFromTags(
                setOf(
                    DownloadWorker.generationTag("generation-a"),
                    DownloadWorker.generationTag("generation-b"),
                ),
            ),
        )
    }

    @Test
    fun `transfer claim accepts only queued or downloading state`() {
        assertEquals(
            DownloadState.DOWNLOADING,
            DownloadTransferStatePolicy.claim(
                state = DownloadState.QUEUED,
                recordGeneration = "current",
                requestedGeneration = "current",
            ),
        )
        assertEquals(
            DownloadState.DOWNLOADING,
            DownloadTransferStatePolicy.claim(
                state = DownloadState.DOWNLOADING,
                recordGeneration = "current",
                requestedGeneration = "current",
            ),
        )
        assertNull(
            DownloadTransferStatePolicy.claim(
                DownloadState.DOWNLOADING,
                recordGeneration = "new",
                requestedGeneration = "old",
            ),
        )
        assertNull(DownloadTransferStatePolicy.claim(DownloadState.PAUSED, "current", "current"))
        assertNull(DownloadTransferStatePolicy.claim(DownloadState.FAILED, "current", "current"))
        assertNull(DownloadTransferStatePolicy.claim(DownloadState.COMPLETED, "current", "current"))
    }

    @Test
    fun `pause winning completion race remains paused`() {
        val paused = requireNotNull(DownloadTransferStatePolicy.pause(DownloadState.DOWNLOADING))

        assertEquals(DownloadState.PAUSED, paused)
        assertNull(
            DownloadTransferStatePolicy.complete(
                paused,
                recordGeneration = null,
                activeGeneration = null,
                requestedGeneration = "old",
            ),
        )
    }

    @Test
    fun `completion winning pause race remains completed`() {
        var finalizations = 0
        val completed = requireNotNull(
            DownloadTransferStatePolicy.complete(
                DownloadState.DOWNLOADING,
                recordGeneration = "current",
                activeGeneration = "current",
                requestedGeneration = "current",
                onAuthorized = { finalizations += 1 },
            ),
        )

        assertEquals(DownloadState.COMPLETED, completed)
        assertEquals(1, finalizations)
        assertNull(DownloadTransferStatePolicy.pause(completed))
    }

    @Test
    fun `inactive downloading record cannot be completed by a stale worker`() {
        assertNull(
            DownloadTransferStatePolicy.complete(
                DownloadState.DOWNLOADING,
                recordGeneration = "current",
                activeGeneration = null,
                requestedGeneration = "current",
            ),
        )
    }

    @Test
    fun `old worker callbacks cannot cross a pause resume generation boundary`() {
        val oldGeneration = "generation-before-pause"
        val newGeneration = "generation-after-resume"
        var newGenerationProgress = 4_096L

        val oldStillOwns = DownloadTransferStatePolicy.owns(
            recordGeneration = newGeneration,
            activeGeneration = newGeneration,
            requestedGeneration = oldGeneration,
        )
        if (oldStillOwns) newGenerationProgress = 999_999L

        assertFalse(oldStillOwns)
        assertEquals(4_096L, newGenerationProgress)
        assertNull(
            DownloadTransferStatePolicy.complete(
                DownloadState.DOWNLOADING,
                recordGeneration = newGeneration,
                activeGeneration = newGeneration,
                requestedGeneration = oldGeneration,
            ),
        )
    }

    @Test
    fun `old completion cannot run finalizer for the new generation`() {
        var finalized = false
        val completion = DownloadTransferStatePolicy.complete(
            DownloadState.DOWNLOADING,
            recordGeneration = "new",
            activeGeneration = "new",
            requestedGeneration = "old",
            onAuthorized = { finalized = true },
        )

        assertNull(completion)
        assertFalse(finalized)
    }

    @Test
    fun `delayed stale hydration cannot overwrite a live paused mutation`() {
        val gate = OneTimeHydrationGate()
        val loadEntered = CountDownLatch(1)
        val mutationAttempted = CountDownLatch(1)
        val allowLoadToPublish = CountDownLatch(1)
        var state = DownloadState.QUEUED

        val loader = thread {
            gate.hydrate {
                loadEntered.countDown()
                mutationAttempted.await()
                allowLoadToPublish.await()
                state = DownloadState.DOWNLOADING
            }
        }
        loadEntered.await()
        val mutator = thread {
            mutationAttempted.countDown()
            gate.withLock { state = DownloadState.PAUSED }
        }
        mutationAttempted.await()
        allowLoadToPublish.countDown()
        loader.join()
        mutator.join()

        assertEquals(DownloadState.PAUSED, state)
    }

    @Test
    fun `repeated hydration is a no op after live mutation`() {
        val gate = OneTimeHydrationGate()
        var loads = 0
        var state = DownloadState.QUEUED

        gate.hydrate {
            loads += 1
            state = DownloadState.DOWNLOADING
        }
        gate.withLock { state = DownloadState.PAUSED }
        gate.hydrate {
            loads += 1
            state = DownloadState.DOWNLOADING
        }

        assertEquals(1, loads)
        assertEquals(DownloadState.PAUSED, state)
    }

    @Test
    fun `live mutation cannot precede hydration`() {
        val gate = OneTimeHydrationGate()
        val failure = runCatching { gate.withLock { Unit } }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals("DownloadStore must hydrate before mutation", failure?.message)
    }

    @Test
    fun `transient transport failures retry within the bounded attempt budget`() {
        assertTrue(
            DownloadTransferPolicy.shouldRetry(
                SocketTimeoutException("read timed out"),
                runAttemptCount = 0,
            ),
        )
        assertTrue(
            DownloadTransferPolicy.shouldRetry(
                RuntimeException(EOFException("short body")),
                runAttemptCount = DownloadTransferPolicy.MAX_RETRIES - 1,
            ),
        )
        assertTrue(
            DownloadTransferPolicy.shouldRetry(
                ProtocolException("unexpected end of stream"),
                runAttemptCount = 0,
            ),
        )
    }

    @Test
    fun `transient transport failures stop retrying at the attempt ceiling`() {
        assertFalse(
            DownloadTransferPolicy.shouldRetry(
                SocketTimeoutException("read timed out"),
                runAttemptCount = DownloadTransferPolicy.MAX_RETRIES,
            ),
        )
    }

    @Test
    fun `retryable server status retries but permanent client status does not`() {
        assertTrue(
            DownloadTransferPolicy.shouldRetry(
                DownloadHttpStatusException(503, "unavailable"),
                runAttemptCount = 0,
            ),
        )
        assertTrue(
            DownloadTransferPolicy.shouldRetry(
                DownloadHttpStatusException(429, "rate limited"),
                runAttemptCount = 0,
            ),
        )
        assertFalse(
            DownloadTransferPolicy.shouldRetry(
                DownloadHttpStatusException(404, "not found"),
                runAttemptCount = 0,
            ),
        )
    }

    @Test
    fun `unrelated failures do not enter the network retry loop`() {
        assertFalse(
            DownloadTransferPolicy.shouldRetry(
                IllegalArgumentException("invalid source"),
                runAttemptCount = 0,
            ),
        )
    }
}
