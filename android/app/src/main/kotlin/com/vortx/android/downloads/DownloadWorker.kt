package com.vortx.android.downloads

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.vortx.android.model.DownloadRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.EOFException
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.ProtocolException
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * The file-writing core for one offline download: GET an http(s) URL to a local file, resumably.
 *
 * This is the Android stand-in for Apple's `URLSessionDownloadTask` + its delegate callbacks
 * (`didWriteData` / `didFinishDownloadingTo` / `didCompleteWithError`), which is why the manager's terminal-state
 * logic is called from here rather than living here.
 *
 * RESUME is the one place Android is structurally STRONGER than the Apple original, and the port deliberately keeps
 * the advantage instead of imitating the weaker mechanism. Apple pauses by asking URLSession for an opaque
 * `resumeData` blob and stashes it in an in-memory dictionary -- so a process death loses it and the transfer
 * restarts from zero. Here the partial file plus its persisted strong ETag form the resume state: a matching
 * `If-Range` response may append, while a missing or changed validator restarts from zero. That survives process
 * death, app kill, and reboot without combining bytes from two representations.
 *
 * TRANSPORT: [HttpURLConnection], matching the house convention for network code in this module
 * (`library/PlayedLinkLibrary.kt` etc.) and adding no HTTP dependency. OkHttp is on the classpath only as Coil's
 * transitive image fetcher; depending on it from here would couple the download subsystem to an image library's
 * dependency graph.
 */
class DownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "downloads"
        private const val KEY_RECORD_ID = "recordId"
        private const val KEY_TRANSFER_GENERATION = "transferGeneration"
        private const val GENERATION_TAG_PREFIX = "vortx-download-generation:"

        private const val CONNECT_TIMEOUT_MS = 30_000
        private const val READ_TIMEOUT_MS = 60_000
        private const val BUFFER_BYTES = 64 * 1024

        /** Apple's progress throttle, unchanged: forward a tick at most every ~0.5s AND ~8 MB per record. */
        private const val PROGRESS_MIN_INTERVAL_MS = 500L
        private const val PROGRESS_MIN_BYTES = 8_000_000L

        fun request(recordId: String, generation: String) = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(
                workDataOf(
                    KEY_RECORD_ID to recordId,
                    KEY_TRANSFER_GENERATION to generation,
                ),
            )
            .addTag(generationTag(generation))
            // No network CONSTRAINT: Apple's sessions set `allowsCellularAccess = true` and start regardless of the
            // connection type, so a constraint would silently diverge from that. A dead network surfaces as a normal
            // transfer failure and the record parks resumable, which is the same outcome, honestly reported.
            //
            // Not expedited either: WorkManager's expedited quota is designed for SHORT user-visible bursts, and a
            // multi-GB media transfer is the opposite of that. This is a long-running foreground-service worker, which
            // is the category the platform actually intends for it.
            //
            // LINEAR backoff, not the EXPONENTIAL default: Result.retry() is used for the one-shot write repair and
            // bounded transient-network recovery. Both want to resume promptly while the condition may still be
            // clearing, not after a doubling wait.
            .setBackoffCriteria(BackoffPolicy.LINEAR, RETRY_BACKOFF_SECONDS, TimeUnit.SECONDS)
            .build()

        fun generationTag(generation: String): String = "$GENERATION_TAG_PREFIX$generation"

        fun generationFromTags(tags: Set<String>): String? {
            val generations = tags.mapNotNull { tag ->
                tag.takeIf { it.startsWith(GENERATION_TAG_PREFIX) }
                    ?.removePrefix(GENERATION_TAG_PREFIX)
                    ?.takeIf { it.isNotEmpty() }
            }
            return generations.singleOrNull()
        }

        /** WorkManager clamps any backoff below 10s to 10s, so this is the real floor rather than a wish. */
        private const val RETRY_BACKOFF_SECONDS = 10L
    }

    private val recordId: String? get() = inputData.getString(KEY_RECORD_ID)
    private val transferGeneration: String? get() = inputData.getString(KEY_TRANSFER_GENERATION)

    override suspend fun getForegroundInfo(): ForegroundInfo {
        val record = recordId?.let { DownloadStore.record(it) }
        return foregroundInfo(record?.displayTitle.orEmpty(), record?.fractionComplete ?: -1.0)
    }

    private fun foregroundInfo(title: String, fraction: Double): ForegroundInfo {
        val id = DownloadNotifications.notificationId(recordId.orEmpty())
        val notification = DownloadNotifications.progress(applicationContext, title, fraction)
        // API 34+ requires an explicit foreground-service type; `dataSync` is the documented type for a
        // user-initiated file transfer, and it must match the type declared on WorkManager's own service in the
        // manifest.
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(id, notification)
        }
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        // Defensive: a worker can be revived by WorkManager into a fresh process. Application.onCreate runs first and
        // inits both, but that init is wrapped in runCatching (it must never break app start), so a failure there
        // would otherwise leave this worker driving an un-hydrated store and a context-less manager.
        DownloadStore.init(applicationContext)
        DownloadManager.init(applicationContext)
        val id = recordId ?: return@withContext Result.failure()
        val generation = transferGeneration ?: return@withContext Result.success()
        val queuedRecord = DownloadStore.record(id) ?: return@withContext Result.success()
        if (!DownloadManager.isDebridOwnerCurrent(queuedRecord)) {
            DownloadManager.handleDebridOwnerChanged(id, generation)
            return@withContext Result.success()
        }
        if (!DownloadManager.claimTransfer(id, generation)) return@withContext Result.success()
        val record = DownloadStore.record(id) ?: run {
            DownloadManager.handleTransferStopped(id, generation)
            return@withContext Result.success()
        }

        runCatching { setForeground(foregroundInfo(record.displayTitle, record.fractionComplete)) }
            .onFailure { Log.w(TAG, "could not enter foreground for ${record.id}", it) }

        try {
            val prepared = transfer(record, generation)
            // Cancellation between the last byte and here would otherwise report a completion for a transfer the user
            // just paused. isStopped is the authoritative check.
            if (isStopped) {
                DownloadManager.handleTransferStopped(id, generation)
                return@withContext Result.success()
            }
            ensureDebridOwner(record)
            DownloadManager.handleTransferComplete(id, generation, prepared.completedBytes) {
                ensureDebridOwner(record)
                finalize(prepared.partFile, prepared.destination)
            }
            Result.success()
        } catch (_: StaleTransferGenerationException) {
            Result.success()
        } catch (_: StaleDebridOwnerException) {
            DownloadManager.handleDebridOwnerChanged(id, generation)
            Result.success()
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            // pause() / cancel() cancelled the work, or WorkManager reclaimed it. The partial file stays on disk and
            // a Range resume continues from it. Apple's analogue is the `NSURLErrorCancelled` branch it deliberately
            // ignores because pause() already recorded the state.
            DownloadManager.handleTransferStopped(id, generation)
            throw cancellation
        } catch (error: Throwable) {
            if (isStopped) {
                DownloadManager.handleTransferStopped(id, generation)
                return@withContext Result.success()
            }
            // The manager owns the ladder (locked write -> park, full volume -> hard fail, other write -> retry once
            // then park, transient transport -> bounded retry, anything else -> fail honestly) because only it holds
            // the retry budget and the parked set.
            // The worker only executes the verdict. RETRY re-runs THIS work through WorkManager's own backoff, which
            // is the one restart mechanism that does not collide with the unique work name this worker still holds.
            when (DownloadManager.handleTransferFailure(id, generation, error, runAttemptCount)) {
                DownloadManager.FailureVerdict.RETRY -> Result.retry()
                DownloadManager.FailureVerdict.TERMINAL -> Result.failure()
                DownloadManager.FailureVerdict.IGNORED -> Result.success()
            }
        }
    }

    /**
     * The transfer itself. Appends to the record's `.part` file and renames onto the real filename at the end.
     *
     * @throws DownloadWriteException when the failure was OURS to write (so [DownloadManager] can route it into the
     * park / self-heal ladder, the #132 path) rather than the network's.
     */
    private suspend fun transfer(record: DownloadRecord, generation: String): PreparedDownload {
        val partFile = DownloadStore.partFileFor(record)
        val destination = DownloadStore.fileFor(record)
        ensureOwnsTransfer(record.id, generation)
        ensureDebridOwner(record)

        // Directory creation is a WRITE, and it is the first write that fails when the user is locked. Typing it as a
        // DownloadWriteException is what routes a Direct-Boot start into the park ladder instead of an opaque failure.
        try {
            DownloadStore.ensureDownloadsDirectoryExists()
        } catch (error: Throwable) {
            throw DownloadWriteException("Could not create the Downloads folder", error)
        }

        var existing = if (partFile.isFile) partFile.length() else 0L
        if (DownloadTransferPolicy.shouldFinalizeLocalPartial(record.bytesTotal, existing)) {
            if (!isStopped) {
                ensureOwnsTransfer(record.id, generation)
                validateCompletedPartial(record.id, generation, partFile)
            }
            return PreparedDownload(partFile, destination, existing)
        }

        var knownTotal = if (existing > 0) record.bytesTotal else 0L
        var requestETag = DownloadTransferPolicy.strongETag(record.representationETag)
        var requestedOffset = DownloadTransferPolicy.resumeOffset(existing, requestETag)
        if (existing > 0 && requestedOffset == 0L) {
            Log.w(TAG, "partial has no strong validator for ${record.id}; restarting from 0")
            resetPartialForFullRestart(record.id, generation, partFile)
            existing = 0L
            knownTotal = 0L
            requestETag = null
        }

        var connection: HttpURLConnection? = null
        while (connection == null) {
            ensureDebridOwner(record)
            val candidate = openConnection(
                record = record,
                offset = requestedOffset,
                ifRangeETag = requestETag?.takeIf { requestedOffset > 0 },
            )
            val status = try {
                candidate.responseCode
            } catch (error: Throwable) {
                runCatching { candidate.disconnect() }
                throw error
            }
            ensureDebridOwner(record)
            if (status !in 200..299) {
                val failure = DownloadHttpStatusException(status, candidate.responseMessage.orEmpty())
                runCatching { candidate.disconnect() }
                throw failure
            }
            if (
                status == HttpURLConnection.HTTP_PARTIAL &&
                requestedOffset > 0 &&
                !DownloadTransferPolicy.canAppendRange(
                    requestedOffset = requestedOffset,
                    persistedETag = requestETag,
                    responseETag = candidate.getHeaderField("ETag"),
                )
            ) {
                Log.w(TAG, "resume validator mismatch for ${record.id}; restarting from 0")
                runCatching { candidate.disconnect() }
                resetPartialForFullRestart(record.id, generation, partFile)
                existing = 0L
                knownTotal = 0L
                requestedOffset = 0L
                requestETag = null
                continue
            }
            connection = candidate
        }

        val activeConnection = requireNotNull(connection)
        var declaredTotal = 0L
        try {
            val status = activeConnection.responseCode

            val responseRange = if (status == HttpURLConnection.HTTP_PARTIAL) {
                val rawRange = activeConnection.getHeaderField("Content-Range")
                DownloadTransferPolicy.contentRangeForResume(rawRange, requestedOffset = requestedOffset)
                    ?: throw ProtocolException(
                        "Resume response did not start at the requested byte $requestedOffset",
                    )
            } else {
                null
            }

            // A server that ignores Range answers 200 with the WHOLE body. Appending that onto our partial would
            // silently corrupt the file (the classic resume bug), so restart from zero instead.
            val resuming = status == HttpURLConnection.HTTP_PARTIAL && requestedOffset > 0
            val restartingFromZero = !resuming && existing > 0
            if (restartingFromZero) {
                Log.w(TAG, "server ignored Range for ${record.id} (HTTP $status); restarting from 0")
                resetPartialForFullRestart(record.id, generation, partFile)
                existing = 0L
                knownTotal = 0L
            }
            val startAt = if (resuming) requestedOffset else 0L

            val responseTotal = DownloadTransferPolicy.representationTotal(
                contentRange = responseRange,
                contentLength = activeConnection.getHeaderFieldLong("Content-Length", -1L),
            )
            val progress = DownloadTransferPolicy.reconcileProgress(
                responseTotal = responseTotal,
                knownTotal = knownTotal,
                isPartialResponse = status == HttpURLConnection.HTTP_PARTIAL,
                startAt = startAt,
            ) ?: throw ProtocolException(
                "Partial response total $responseTotal did not safely reconcile with known total " +
                    "$knownTotal at byte $startAt",
            )
            declaredTotal = progress.bytesTotal
            val responseETag = if (resuming) {
                requestETag
            } else {
                DownloadTransferPolicy.strongETag(activeConnection.getHeaderField("ETag"))
            }
            // Persist the identity contract before reading the body. Even an unknown-length response needs its ETag
            // recorded now so a process-death retry can prove whether the saved prefix is appendable.
            val sized = DownloadManager.handleTransferProgress(
                id = record.id,
                generation = generation,
            ) {
                it.copy(
                    bytesTotal = declaredTotal,
                    bytesDone = progress.bytesDone,
                    representationETag = responseETag,
                )
            } ?: throw StaleTransferGenerationException()
            if (declaredTotal > 0) {
                // The representation total is resume integrity, not cosmetic progress. Persist it the first time it is
                // learned, and reconcile bytesDone to the actual partial-file offset before storage validation.
                // Re-check storage now that a real size is known: the up-front preflight in DownloadManager could not
                // run for a fresh record (bytesTotal == 0), so this is the first point a genuine shortfall is
                // knowable. Failing here beats writing until the volume fills.
                if (DownloadManager.storageShortfall(sized)) {
                    // DownloadOutOfSpaceException, NOT DownloadWriteException: a full volume must fail HONESTLY and
                    // terminally. Typed as a write failure it would enter the retry-then-park ladder and re-download
                    // gigabytes on every unlock, failing at the same byte forever.
                    throw DownloadOutOfSpaceException(
                        "Not enough storage to save this download. Free up space and try again.",
                    )
                }
            }

            writeBody(
                connection = activeConnection,
                record = record,
                partFile = partFile,
                startAt = startAt,
                declaredTotal = declaredTotal,
                responseRange = responseRange,
                generation = generation,
            )
        } finally {
            runCatching { activeConnection.disconnect() }
        }

        if (isStopped) return PreparedDownload(partFile, destination, partFile.length())
        ensureOwnsTransfer(record.id, generation)
        ensureDebridOwner(record)

        val actualBytes = partFile.length()
        if (!DownloadTransferPolicy.hasCompleteLength(declaredTotal, actualBytes)) {
            throw EOFException(
                "Download ended at $actualBytes bytes, but the server declared $declaredTotal bytes",
            )
        }

        validateCompletedPartial(record.id, generation, partFile)
        return PreparedDownload(partFile, destination, actualBytes)
    }

    /**
     * Discard a partial representation and its durable identity before a full restart. The file truncation and state
     * reset are generation-guarded so a superseded worker cannot erase a replacement transfer.
     */
    private fun resetPartialForFullRestart(
        recordId: String,
        generation: String,
        partFile: File,
    ) {
        val reset = try {
            DownloadManager.performTransferFileMutation(recordId, generation) {
                RandomAccessFile(partFile, "rw").use { it.setLength(0L) }
            }
        } catch (error: Throwable) {
            throw DownloadWriteException("Could not reset the partial download", error)
        }
        if (!reset) throw StaleTransferGenerationException()
        DownloadManager.handleTransferProgress(
            id = recordId,
            generation = generation,
        ) {
            it.copy(
                bytesDone = 0L,
                bytesTotal = 0L,
                representationETag = null,
            )
        } ?: throw StaleTransferGenerationException()
    }

    /**
     * Validate a complete partial before the manager atomically authorizes its rename. Shared by the normal network
     * tail and the retry path where the previous attempt already wrote every declared byte but died before finalizing.
     */
    private fun validateCompletedPartial(recordId: String, generation: String, partFile: File) {
        // An add-on that hands back an HLS playlist or a web embed page yields a few-KB non-media "download". Reject
        // it instead of "completing" with garbage, and delete the bogus file so it never appears playable offline.
        if (looksLikeNonMedia(partFile)) {
            val deleted = DownloadManager.performTransferFileMutation(recordId, generation) {
                runCatching { partFile.delete() }
            }
            if (!deleted) throw StaleTransferGenerationException()
            throw java.io.IOException(
                "This source isn't a downloadable file (it streams or resolves through a web page). " +
                    "Downloads work with direct and debrid file sources.",
            )
        }
    }

    /** Rename the completed partial onto its real filename. A rename inside one directory moves no bytes. */
    private fun finalize(partFile: File, destination: File) {
        runCatching { destination.delete() }
        if (!partFile.renameTo(destination)) {
            throw DownloadWriteException(
                "Could not save the finished download to ${destination.name}",
                null,
            )
        }
    }

    private data class PreparedDownload(
        val partFile: File,
        val destination: File,
        val completedBytes: Long,
    )

    private fun openConnection(
        record: DownloadRecord,
        offset: Long,
        ifRangeETag: String?,
    ): HttpURLConnection {
        val connection = URL(record.remoteURL).openConnection() as HttpURLConnection
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        connection.instanceFollowRedirects = true
        // The add-on's declared request headers (behaviorHints.proxyHeaders): a CDN behind a header-gated add-on
        // rejects a request without the right Referer / User-Agent. The player applies the same headers.
        record.headers?.forEach { (name, value) -> connection.setRequestProperty(name, value) }
        if (offset > 0) {
            connection.setRequestProperty("Range", "bytes=$offset-")
            requireNotNull(ifRangeETag) { "A Range request requires a strong If-Range validator" }
            connection.setRequestProperty("If-Range", ifRangeETag)
        }
        return connection
    }

    /**
     * Stream the body onto the partial file, reporting throttled progress. Uses [RandomAccessFile] positioned at
     * [startAt] rather than an append-mode stream so a restart-from-zero (server ignored Range) truncates instead of
     * appending onto stale bytes.
     */
    private fun writeBody(
        connection: HttpURLConnection,
        record: DownloadRecord,
        partFile: File,
        startAt: Long,
        declaredTotal: Long,
        responseRange: DownloadTransferPolicy.ContentRange?,
        generation: String,
    ) {
        var written = startAt
        var responseBytes = 0L
        var lastPushBytes = startAt
        var lastPushAt = 0L
        val expectedResponseBytes = responseRange?.let {
            DownloadTransferPolicy.expectedRangeBodyLength(it)
        }

        // Opening the destination is unambiguously OUR write, and it is the FIRST thing that fails when storage is
        // not writable (no Downloads dir, no permission, credential-encrypted storage still locked). Typing it here
        // is what routes that case into the park ladder; left bare it would surface as a FileNotFoundException, which
        // DownloadManager deliberately does not treat as a write failure because a 404 throws the same class.
        val out = try {
            var opened: RandomAccessFile? = null
            val accepted = DownloadManager.performTransferFileMutation(record.id, generation) {
                opened = RandomAccessFile(partFile, "rw")
            }
            if (!accepted) throw StaleTransferGenerationException()
            requireNotNull(opened)
        } catch (stale: StaleTransferGenerationException) {
            throw stale
        } catch (error: Throwable) {
            throw DownloadWriteException("Could not open the download file for writing", error)
        }

        try {
            out.use { out ->
                // Truncate BEFORE seeking: setLength can move the file pointer when it shortens the file past it, so
                // seeking first and truncating second would leave the pointer's position depending on the old length.
                // This drops any bytes past the resume point (a truncated or corrupt earlier attempt).
                val positioned = DownloadManager.performTransferFileMutation(record.id, generation) {
                    out.setLength(startAt)
                    out.seek(startAt)
                }
                if (!positioned) throw StaleTransferGenerationException()
                connection.inputStream.use { input ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    ensureDebridOwner(record)
                    while (true) {
                        if (isStopped) return
                        ensureOwnsTransfer(record.id, generation)
                        val read = input.read(buffer)
                        if (read < 0) break
                        ensureOwnsTransfer(record.id, generation)
                        ensureDebridOwner(record)
                        if (
                            expectedResponseBytes != null &&
                            read.toLong() > expectedResponseBytes - responseBytes
                        ) {
                            throw ProtocolException(
                                "Range response exceeded its declared $expectedResponseBytes-byte extent",
                            )
                        }
                        val accepted = DownloadManager.performTransferFileMutation(record.id, generation) {
                            out.write(buffer, 0, read)
                        }
                        if (!accepted) throw StaleTransferGenerationException()
                        written += read
                        responseBytes += read

                        val now = System.currentTimeMillis()
                        if (written - lastPushBytes >= PROGRESS_MIN_BYTES || now - lastPushAt >= PROGRESS_MIN_INTERVAL_MS) {
                            ensureDebridOwner(record)
                            lastPushBytes = written
                            lastPushAt = now
                            val total = if (declaredTotal > 0) declaredTotal else 0L
                            // persistIndex = false: a bare progress tick must not re-encode + rewrite the JSON index
                            // several times a second. A crash mid-download only loses a cosmetic byte count -- the
                            // real resume state is the .part file's length, which is always accurate.
                            DownloadManager.handleTransferProgress(
                                id = record.id,
                                generation = generation,
                                persistIndex = false,
                            ) {
                                it.copy(bytesDone = written, bytesTotal = if (total > 0) total else it.bytesTotal)
                            } ?: throw StaleTransferGenerationException()
                            runCatching {
                                val fraction = if (total > 0) written.toDouble() / total.toDouble() else -1.0
                                setForegroundAsync(foregroundInfo(record.displayTitle, fraction))
                            }
                        }
                    }
                    if (
                        responseRange != null &&
                        !DownloadTransferPolicy.hasExactRangeBodyLength(responseRange, responseBytes)
                    ) {
                        throw EOFException(
                            "Range response ended at $responseBytes bytes, but its declared extent was " +
                                "${DownloadTransferPolicy.expectedRangeBodyLength(responseRange)} bytes",
                        )
                    }
                }
            }
        } catch (error: Throwable) {
            if (error is StaleTransferGenerationException || error is StaleDebridOwnerException) throw error
            // A failure here is ambiguous: it could be the socket dying mid-read (network) or the volume refusing the
            // write (ours). Only classify it as a WRITE failure -- which routes it into the park / self-heal ladder --
            // when the evidence says so: an errno-bearing exception, or a user who cannot write CE storage right now.
            // Misclassifying a dead link as a write failure would park it forever instead of failing honestly.
            if (isDiskError(error) || !DownloadManager.isUserUnlocked()) {
                throw DownloadWriteException("Could not write the download to storage", error)
            }
            throw error
        } finally {
            // Commit the true byte count even on a failure path, so the row and the next resume agree with the file.
            DownloadManager.handleTransferProgress(record.id, generation) {
                it.copy(bytesDone = maxOf(written, 0L))
            }
        }
    }

    private fun ensureOwnsTransfer(id: String, generation: String) {
        if (!DownloadManager.ownsTransfer(id, generation)) {
            throw StaleTransferGenerationException()
        }
    }

    private fun ensureDebridOwner(record: DownloadRecord) {
        if (!DownloadManager.isDebridOwnerCurrent(record)) {
            throw StaleDebridOwnerException()
        }
    }

    /** True when an exception chain carries a filesystem errno, i.e. the write itself was refused. */
    private fun isDiskError(error: Throwable): Boolean {
        var cursor: Throwable? = error
        while (cursor != null) {
            if (cursor is android.system.ErrnoException) return true
            if (DownloadManager.isOutOfSpace(cursor)) return true
            cursor = cursor.cause
        }
        return false
    }

    /**
     * Sniff a finished download's first bytes: an HLS playlist (#EXTM3U) or an HTML embed page (from an add-on that
     * hands back a web page rather than a media file) is NOT a real media download. Real media starts with binary
     * magic (mp4 `ftyp` box, mkv EBML, MPEG-TS 0x47), which never decodes to these text markers, so there are no
     * false positives on genuine media. An empty file counts as non-media. Ported from Apple's `looksLikeNonMedia`.
     */
    private fun looksLikeNonMedia(file: File): Boolean {
        if (!file.isFile) return true
        val head = runCatching {
            file.inputStream().use { stream ->
                val buffer = ByteArray(64)
                val read = stream.read(buffer)
                if (read <= 0) ByteArray(0) else buffer.copyOf(read)
            }
        }.getOrElse { return false }
        if (head.isEmpty()) return true
        val text = runCatching { String(head, Charsets.UTF_8).trim().lowercase() }.getOrNull() ?: return false
        return text.startsWith("#extm3u") || text.startsWith("#ext-x-") ||
            text.startsWith("<!doctype") || text.startsWith("<html") ||
            text.startsWith("<?xml") || text.startsWith("<head")
    }
}

private class StaleTransferGenerationException : IllegalStateException()
private class StaleDebridOwnerException : IllegalStateException()
