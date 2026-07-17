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
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
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
 * restarts from zero. Here the partial file IS the resume state: we ask for `Range: bytes=<len>-` and append. That
 * survives process death, app kill, and reboot, because it depends on nothing but the bytes already on disk.
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

        private const val CONNECT_TIMEOUT_MS = 30_000
        private const val READ_TIMEOUT_MS = 60_000
        private const val BUFFER_BYTES = 64 * 1024

        /** Apple's progress throttle, unchanged: forward a tick at most every ~0.5s AND ~8 MB per record. */
        private const val PROGRESS_MIN_INTERVAL_MS = 500L
        private const val PROGRESS_MIN_BYTES = 8_000_000L

        fun request(recordId: String) = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(workDataOf(KEY_RECORD_ID to recordId))
            // No network CONSTRAINT: Apple's sessions set `allowsCellularAccess = true` and start regardless of the
            // connection type, so a constraint would silently diverge from that. A dead network surfaces as a normal
            // transfer failure and the record parks resumable, which is the same outcome, honestly reported.
            //
            // Not expedited either: WorkManager's expedited quota is designed for SHORT user-visible bursts, and a
            // multi-GB media transfer is the opposite of that. This is a long-running foreground-service worker, which
            // is the category the platform actually intends for it.
            //
            // LINEAR backoff, not the EXPONENTIAL default: the only thing that returns Result.retry() here is
            // DownloadManager's one-shot write retry (FailureVerdict.RETRY), which wants to re-attempt promptly while
            // the transient condition may still be clearing, not after a doubling wait.
            .setBackoffCriteria(BackoffPolicy.LINEAR, RETRY_BACKOFF_SECONDS, TimeUnit.SECONDS)
            .build()

        /** WorkManager clamps any backoff below 10s to 10s, so this is the real floor rather than a wish. */
        private const val RETRY_BACKOFF_SECONDS = 10L
    }

    private val recordId: String? get() = inputData.getString(KEY_RECORD_ID)

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
        val record = DownloadStore.record(id) ?: return@withContext Result.failure()

        DownloadManager.markActive(id)
        runCatching { setForeground(foregroundInfo(record.displayTitle, record.fractionComplete)) }
            .onFailure { Log.w(TAG, "could not enter foreground for ${record.id}", it) }

        try {
            transfer(record)
            // Cancellation between the last byte and here would otherwise report a completion for a transfer the user
            // just paused. isStopped is the authoritative check.
            if (isStopped) {
                DownloadManager.handleTransferStopped(id)
                return@withContext Result.success()
            }
            DownloadManager.handleTransferComplete(id)
            Result.success()
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            // pause() / cancel() cancelled the work, or WorkManager reclaimed it. The partial file stays on disk and
            // a Range resume continues from it. Apple's analogue is the `NSURLErrorCancelled` branch it deliberately
            // ignores because pause() already recorded the state.
            DownloadManager.handleTransferStopped(id)
            throw cancellation
        } catch (error: Throwable) {
            if (isStopped) {
                DownloadManager.handleTransferStopped(id)
                return@withContext Result.success()
            }
            // The manager owns the ladder (locked write -> park, full volume -> hard fail, other write -> retry once
            // then park, anything else -> fail honestly) because only it holds the retry budget and the parked set.
            // The worker only executes the verdict. RETRY re-runs THIS work through WorkManager's own backoff, which
            // is the one restart mechanism that does not collide with the unique work name this worker still holds.
            when (DownloadManager.handleTransferFailure(id, error)) {
                DownloadManager.FailureVerdict.RETRY -> Result.retry()
                DownloadManager.FailureVerdict.TERMINAL -> Result.failure()
            }
        }
    }

    /**
     * The transfer itself. Appends to the record's `.part` file and renames onto the real filename at the end.
     *
     * @throws DownloadWriteException when the failure was OURS to write (so [DownloadManager] can route it into the
     * park / self-heal ladder, the #132 path) rather than the network's.
     */
    private suspend fun transfer(record: DownloadRecord) {
        val partFile = DownloadStore.partFileFor(record)
        val destination = DownloadStore.fileFor(record)

        // Directory creation is a WRITE, and it is the first write that fails when the user is locked. Typing it as a
        // DownloadWriteException is what routes a Direct-Boot start into the park ladder instead of an opaque failure.
        try {
            DownloadStore.ensureDownloadsDirectoryExists()
        } catch (error: Throwable) {
            throw DownloadWriteException("Could not create the Downloads folder", error)
        }

        val existing = if (partFile.isFile) partFile.length() else 0L
        val connection = openConnection(record, offset = existing)
        try {
            val status = connection.responseCode
            if (status !in 200..299) {
                throw java.io.IOException("HTTP $status ${connection.responseMessage.orEmpty()}".trim())
            }

            // A server that ignores Range answers 200 with the WHOLE body. Appending that onto our partial would
            // silently corrupt the file (the classic resume bug), so restart from zero instead.
            val resuming = status == HttpURLConnection.HTTP_PARTIAL && existing > 0
            if (!resuming && existing > 0) {
                Log.w(TAG, "server ignored Range for ${record.id} (HTTP $status); restarting from 0")
                runCatching { partFile.delete() }
            }
            val startAt = if (resuming) existing else 0L

            val declared = contentLength(connection, resuming = resuming, startAt = startAt)
            if (declared > 0) {
                DownloadStore.update(record.id, persistIndex = false) { it.copy(bytesTotal = declared) }
                // Re-check storage now that a real size is known: the up-front preflight in DownloadManager could not
                // run for a fresh record (bytesTotal == 0), so this is the first point a genuine shortfall is
                // knowable. Failing here beats writing until the volume fills.
                val sized = DownloadStore.record(record.id)
                if (sized != null && DownloadManager.storageShortfall(sized)) {
                    // DownloadOutOfSpaceException, NOT DownloadWriteException: a full volume must fail HONESTLY and
                    // terminally. Typed as a write failure it would enter the retry-then-park ladder and re-download
                    // gigabytes on every unlock, failing at the same byte forever.
                    throw DownloadOutOfSpaceException(
                        "Not enough storage to save this download. Free up space and try again.",
                    )
                }
            }

            writeBody(connection, record, partFile, startAt, declared)
        } finally {
            runCatching { connection.disconnect() }
        }

        if (isStopped) return

        // Content sniff BEFORE the rename: an add-on that hands back an HLS playlist or a web embed page yields a
        // few-KB non-media "download". Reject it with an honest message instead of "completing" with garbage, and
        // delete the bogus file so it never shows up as a playable offline title.
        if (looksLikeNonMedia(partFile)) {
            runCatching { partFile.delete() }
            throw java.io.IOException(
                "This source isn't a downloadable file (it streams or resolves through a web page). " +
                    "Downloads work with direct and debrid file sources.",
            )
        }

        finalize(partFile, destination)
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

    private fun openConnection(record: DownloadRecord, offset: Long): HttpURLConnection {
        val connection = URL(record.remoteURL).openConnection() as HttpURLConnection
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        connection.instanceFollowRedirects = true
        // The add-on's declared request headers (behaviorHints.proxyHeaders): a CDN behind a header-gated add-on
        // rejects a request without the right Referer / User-Agent. The player applies the same headers.
        record.headers?.forEach { (name, value) -> connection.setRequestProperty(name, value) }
        if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
        return connection
    }

    /**
     * The transfer's TOTAL size, not the length of this response. On a resumed request the server reports only the
     * remaining bytes in `Content-Length`, so the total has to come from `Content-Range`'s trailing size (or be
     * reconstructed as offset + remaining). Getting this wrong is what makes a resumed download's progress bar report
     * a total smaller than the bytes already on disk.
     */
    private fun contentLength(connection: HttpURLConnection, resuming: Boolean, startAt: Long): Long {
        val range = connection.getHeaderField("Content-Range")
        if (range != null) {
            // "bytes 200-1023/1024" -> 1024. A "*" total is legal and means unknown.
            range.substringAfterLast('/', "").trim().toLongOrNull()?.let { return it }
        }
        val length = connection.getHeaderFieldLong("Content-Length", -1L)
        if (length <= 0) return 0L // unknown (chunked, or a torrent loopback stream): progress stays indeterminate
        return if (resuming) startAt + length else length
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
    ) {
        var written = startAt
        var lastPushBytes = startAt
        var lastPushAt = 0L

        // Opening the destination is unambiguously OUR write, and it is the FIRST thing that fails when storage is
        // not writable (no Downloads dir, no permission, credential-encrypted storage still locked). Typing it here
        // is what routes that case into the park ladder; left bare it would surface as a FileNotFoundException, which
        // DownloadManager deliberately does not treat as a write failure because a 404 throws the same class.
        val out = try {
            RandomAccessFile(partFile, "rw")
        } catch (error: Throwable) {
            throw DownloadWriteException("Could not open the download file for writing", error)
        }

        try {
            out.use { out ->
                // Truncate BEFORE seeking: setLength can move the file pointer when it shortens the file past it, so
                // seeking first and truncating second would leave the pointer's position depending on the old length.
                // This drops any bytes past the resume point (a truncated or corrupt earlier attempt).
                out.setLength(startAt)
                out.seek(startAt)
                connection.inputStream.use { input ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    while (true) {
                        if (isStopped) return
                        val read = input.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                        written += read

                        val now = System.currentTimeMillis()
                        if (written - lastPushBytes >= PROGRESS_MIN_BYTES || now - lastPushAt >= PROGRESS_MIN_INTERVAL_MS) {
                            lastPushBytes = written
                            lastPushAt = now
                            val total = if (declaredTotal > 0) declaredTotal else 0L
                            // persistIndex = false: a bare progress tick must not re-encode + rewrite the JSON index
                            // several times a second. A crash mid-download only loses a cosmetic byte count -- the
                            // real resume state is the .part file's length, which is always accurate.
                            DownloadStore.update(record.id, persistIndex = false) {
                                it.copy(bytesDone = written, bytesTotal = if (total > 0) total else it.bytesTotal)
                            }
                            runCatching {
                                val fraction = if (total > 0) written.toDouble() / total.toDouble() else -1.0
                                setForegroundAsync(foregroundInfo(record.displayTitle, fraction))
                            }
                        }
                    }
                }
            }
        } catch (error: Throwable) {
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
            DownloadStore.update(record.id) { it.copy(bytesDone = maxOf(written, 0L)) }
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
