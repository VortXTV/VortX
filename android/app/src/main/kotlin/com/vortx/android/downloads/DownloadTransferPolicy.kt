package com.vortx.android.downloads

import com.vortx.android.model.DownloadState
import java.io.EOFException
import java.io.IOException
import java.net.ProtocolException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Pure transfer-integrity and retry decisions shared by [DownloadWorker] and [DownloadManager].
 */
object DownloadTransferPolicy {
    data class ContentRange(
        val start: Long,
        val endInclusive: Long,
        val totalBytes: Long?,
    )

    data class ReconciledProgress(
        val bytesTotal: Long,
        val bytesDone: Long,
    )

    private val contentRangePattern = Regex(
        pattern = """^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$""",
        option = RegexOption.IGNORE_CASE,
    )

    /**
     * WorkManager's runAttemptCount starts at zero. Counts 0, 1, and 2 may retry; count 3 is terminal.
     */
    const val MAX_RETRIES = 3

    /**
     * A declared response total is a contract, so the file must match it exactly. For chunked responses there is no
     * length contract to check, but an empty body still cannot be a completed media download.
     */
    fun hasCompleteLength(declaredBytes: Long, actualBytes: Long): Boolean =
        if (declaredBytes > 0) actualBytes == declaredBytes else actualBytes > 0

    /**
     * Keep an earlier total when a later response is chunked or otherwise omits a usable representation length.
     * This matters on resume: forgetting the earlier contract would let a short suffix turn a truncated file into a
     * successful download.
     */
    fun resolveExpectedTotal(responseTotal: Long, knownTotal: Long, isPartialResponse: Boolean): Long? {
        val normalizedKnown = knownTotal.coerceAtLeast(0)
        if (
            isPartialResponse &&
            responseTotal > 0 &&
            normalizedKnown > 0 &&
            responseTotal != normalizedKnown
        ) {
            return null
        }
        if (isPartialResponse && responseTotal <= 0 && normalizedKnown <= 0) return null
        if (isPartialResponse && normalizedKnown > 0) return normalizedKnown
        return if (responseTotal > 0) responseTotal else normalizedKnown
    }

    /**
     * Reconcile durable representation size with the actual partial-file offset before storage validation. Null means
     * the response cannot prove a safe continuation.
     */
    fun reconcileProgress(
        responseTotal: Long,
        knownTotal: Long,
        isPartialResponse: Boolean,
        startAt: Long,
    ): ReconciledProgress? {
        val total = resolveExpectedTotal(responseTotal, knownTotal, isPartialResponse) ?: return null
        val done = startAt.coerceAtLeast(0)
        if (total > 0 && done > total) return null
        return ReconciledProgress(bytesTotal = total, bytesDone = done)
    }

    /**
     * Parse and validate the Content-Range contract for a 206 response. A resumed body is safe to append only when
     * the server starts at the exact byte requested; accepting an earlier or later start corrupts the partial file.
     */
    fun contentRangeForResume(value: String?, requestedOffset: Long): ContentRange? {
        if (value == null || requestedOffset < 0) return null
        val match = contentRangePattern.matchEntire(value) ?: return null
        val start = match.groupValues[1].toLongOrNull() ?: return null
        val endInclusive = match.groupValues[2].toLongOrNull() ?: return null
        val totalToken = match.groupValues[3]
        val totalBytes = if (totalToken == "*") null else totalToken.toLongOrNull() ?: return null
        if (start != requestedOffset || endInclusive < start) return null
        if (totalBytes != null && (totalBytes <= 0 || endInclusive >= totalBytes)) return null
        if (endInclusive - start == Long.MAX_VALUE) return null
        return ContentRange(start, endInclusive, totalBytes)
    }

    /**
     * A Content-Length on 206 describes only that response body, never the whole representation. Content-Range's
     * explicit trailing total is authoritative; "*" stays unknown so a previously known record total can survive.
     */
    fun representationTotal(contentRange: ContentRange?, contentLength: Long): Long =
        contentRange?.totalBytes ?: if (contentRange == null) contentLength.coerceAtLeast(0) else 0

    fun shouldFinalizeLocalPartial(knownTotal: Long, partialBytes: Long): Boolean =
        knownTotal > 0 && partialBytes == knownTotal

    fun expectedRangeBodyLength(contentRange: ContentRange): Long =
        contentRange.endInclusive - contentRange.start + 1

    fun hasExactRangeBodyLength(contentRange: ContentRange, actualBytes: Long): Boolean =
        actualBytes == expectedRangeBodyLength(contentRange)

    fun bytesDoneForResponse(restartingFromZero: Boolean, previousBytesDone: Long): Long =
        if (restartingFromZero) 0 else previousBytesDone.coerceAtLeast(0)

    /**
     * Only a strong HTTP entity tag can prove that a Range suffix belongs to the same representation as the saved
     * prefix. Weak validators and malformed unquoted values are deliberately rejected.
     */
    fun strongETag(value: String?): String? {
        val normalized = value?.trim()?.takeIf { it.length >= 2 } ?: return null
        if (normalized.startsWith("W/", ignoreCase = true)) return null
        return normalized.takeIf { it.first() == '"' && it.last() == '"' }
    }

    /** A partial without a durable strong validator must restart from zero instead of risking mixed media bytes. */
    fun resumeOffset(partialBytes: Long, representationETag: String?): Long =
        if (partialBytes > 0 && strongETag(representationETag) != null) partialBytes else 0L

    /** A 206 suffix is appendable only when its strong validator exactly matches the persisted prefix validator. */
    fun canAppendRange(
        requestedOffset: Long,
        persistedETag: String?,
        responseETag: String?,
    ): Boolean {
        if (requestedOffset <= 0) return false
        val persisted = strongETag(persistedETag) ?: return false
        return strongETag(responseETag) == persisted
    }

    /** WorkManager may retry only while the record still represents an active user-authorized transfer. */
    fun mayRetryRecord(state: DownloadState): Boolean = state == DownloadState.DOWNLOADING

    /**
     * WorkManager persists runAttemptCount with the work row, so this one-write retry ceiling survives process death.
     * A user resume creates a fresh generation and WorkRequest whose attempt count starts at zero again.
     */
    fun canRetryWrite(runAttemptCount: Int): Boolean = runAttemptCount == 0

    /**
     * Retry only failures that can plausibly recover without changing the source. The partial file remains the resume
     * token, so each retry continues with a Range request instead of redownloading the completed prefix.
     */
    fun shouldRetry(cause: Throwable, runAttemptCount: Int): Boolean {
        if (runAttemptCount >= MAX_RETRIES) return false

        var cursor: Throwable? = cause
        var depth = 0
        while (cursor != null && depth < 8) {
            when (cursor) {
                is DownloadHttpStatusException -> {
                    return cursor.statusCode == 408 ||
                        cursor.statusCode == 425 ||
                        cursor.statusCode == 429 ||
                        cursor.statusCode in 500..599
                }
                is EOFException,
                is ProtocolException,
                is SocketTimeoutException,
                is SocketException,
                is UnknownHostException,
                -> return true
            }
            cursor = cursor.cause
            depth++
        }
        return false
    }
}

/** Pure legal state transitions used while DownloadManager holds its lifecycle lock. */
internal object DownloadTransferStatePolicy {
    fun mayResume(state: DownloadState): Boolean =
        state == DownloadState.PAUSED || state == DownloadState.FAILED

    fun owns(
        recordGeneration: String?,
        activeGeneration: String?,
        requestedGeneration: String,
    ): Boolean =
        recordGeneration == requestedGeneration && activeGeneration == requestedGeneration

    fun claim(
        state: DownloadState,
        recordGeneration: String?,
        requestedGeneration: String,
    ): DownloadState? = when {
        recordGeneration != requestedGeneration -> null
        state == DownloadState.QUEUED || state == DownloadState.DOWNLOADING -> DownloadState.DOWNLOADING
        else -> null
    }

    fun pause(state: DownloadState): DownloadState? = when (state) {
        DownloadState.QUEUED,
        DownloadState.DOWNLOADING,
        -> DownloadState.PAUSED
        DownloadState.PAUSED,
        DownloadState.COMPLETED,
        DownloadState.FAILED,
        -> null
    }

    fun complete(
        state: DownloadState,
        recordGeneration: String?,
        activeGeneration: String?,
        requestedGeneration: String,
        onAuthorized: () -> Unit = {},
    ): DownloadState? =
        if (
            state == DownloadState.DOWNLOADING &&
            owns(recordGeneration, activeGeneration, requestedGeneration)
        ) {
            onAuthorized()
            DownloadState.COMPLETED
        } else {
            null
    }
}

/**
 * Immediate scheduling outcome returned to a caller that still owns DownloadManager's lifecycle lock.
 *
 * WorkManager can also fail its asynchronous enqueue operation after [STARTED] is returned. That path drains the
 * queue from the operation callback itself. [freesSlot] therefore describes only a failure completed synchronously
 * before [DownloadManager.startTransfer] returns.
 */
internal enum class DownloadTransferStartResult(val freesSlot: Boolean) {
    STARTED(false),
    PREFLIGHT_FAILED(true),
    ENQUEUE_FAILED(true),
    NOT_STARTED(false),
}

/** Framework-free snapshot of one WorkManager row for generation-safe reconciliation decisions. */
internal data class DownloadWorkSnapshot(
    val id: String,
    val generation: String?,
    val isFinished: Boolean,
)

internal object DownloadReconciliationPolicy {
    fun hasLiveGeneration(
        generation: String?,
        work: List<DownloadWorkSnapshot>,
    ): Boolean = work.any { !it.isFinished && it.generation == generation }

    /**
     * Return only unfinished work belonging to the snapshotted generation. A replacement generation is never
     * selected, even if it shares the same record-wide unique-work name.
     */
    fun cancellableWorkIds(
        generation: String?,
        work: List<DownloadWorkSnapshot>,
    ): List<String> = work.filter { !it.isFinished && it.generation == generation }.map { it.id }
}

/** An HTTP response whose status, rather than its body transport, rejected the download. */
class DownloadHttpStatusException(
    val statusCode: Int,
    statusText: String,
) : IOException("HTTP $statusCode ${statusText.trim()}".trim())
