package com.vortx.android.downloads

import android.content.Context
import android.os.StatFs
import android.os.UserManager
import android.util.Log
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/**
 * The coordinator for offline downloads. Android port of Apple `app/SourcesShared/DownloadManager.swift`.
 *
 * ONE download = GET an http(s) URL to a local file. Apple splits this across TWO transports (a `.background`
 * URLSession for debrid/direct/HTTP, and a `.default` foreground session wrapped in a UIKit background-task
 * assertion for loopback torrent URLs, because the in-app streaming server must stay alive). Android needs only
 * ONE: a [DownloadWorker] running under WorkManager as a foreground service. That single transport covers both
 * Apple modes because:
 *
 *  * **Process-death survival** (Apple's reason for `.background`): WorkManager persists the work in its own
 *    database and re-runs the worker in a fresh process. That is strictly stronger than URLSession resume data,
 *    which Apple holds only in memory and loses on relaunch.
 *  * **Keeping the streaming server alive** (Apple's reason for the foreground session + `beginBackgroundTask`):
 *    a WorkManager worker runs IN the app process, and `setForeground` holds a foreground-service notification
 *    that keeps that process alive. So a torrent-to-disk transfer keeps the loopback server up for free.
 *    [DownloadRecord.isTorrent] is therefore retained for DISPLAY and provenance, but it does NOT branch the
 *    transport the way it does on Apple. Fail-soft is unchanged: if the streaming server is not up (e.g. WorkManager
 *    revived the worker into a process whose engine has not started its server), the loopback GET simply fails and
 *    the record parks resumable, exactly as Apple's torrent transfer does when its server dies.
 *
 * WHAT IS DELIBERATELY NOT PORTED (each fails honestly rather than silently doing nothing):
 *  * **HLS offline** (`.m3u8`). Apple downloads these on iOS ONLY, via `AVAssetDownloadTask` into a system-managed
 *    `.movpkg`, and fails honestly on tvOS/macOS where that API does not exist. Android has no `.movpkg` analogue;
 *    the equivalent would be a Media3 `DownloadService` writing an opaque cache, which is a different architecture
 *    from this subsystem's `<id>.<ext>` flat file + `index.json` record schema. So Android takes the SAME honest
 *    failure Apple's tvOS/macOS branch takes. See [isHLSPlaylistURL].
 *  * **Auto-delete watched downloads** (Apple's opt-in `autoDeleteWatchedDefaultsKey` sweep). It is driven by the
 *    app-wide finished-watched signal `WatchedIndex.ids`, and `WatchedIndex` is NOT ported to Android (it is a
 *    genuinely-absent row on the parity map). Porting the sweep now would mean writing a feature whose trigger can
 *    never fire, so it waits for WatchedIndex.
 *  * **The batch coordinator** (`iOSBatchDownloadCoordinator.swift`, "download season 2"). It sits on top of THIS
 *    core plus the ranking settle loop and the contributor merges; it is its own unit.
 *
 * All state writes go through [DownloadStore] (the local index). Nothing here writes a `libraryItem` document or
 * syncs the list. Apple's manager is `@MainActor`-isolated; this one is guarded by `@Synchronized` instead, because
 * [DownloadWorker] calls back into it from a WorkManager background thread. The lock covers in-memory bookkeeping
 * plus store writes only, never a transfer.
 */
object DownloadManager {

    private const val TAG = "downloads"

    private const val PREFS = "vortx.downloads"
    const val MAX_CONCURRENT_KEY = "vortx.downloads.maxConcurrent"
    /**
     * Gates the Settings > Downloads row. The download subsystem is fully built (manager, worker, store,
     * notifications, screen) but has no CREATE entry point yet: nothing calls [download], so the screen can
     * only ever show "No downloads yet". The row is hidden until a Download action (on the streams or detail
     * screen) actually calls [download]; flip this to true in the same change that wires that action.
     */
    const val CREATE_PATH_WIRED = false
    private const val QUEUE_ORDER_KEY = "vortx.downloads.queueOrder"
    private const val AWAITING_UNLOCK_KEY = "vortx.downloads.awaitingUnlock"

    /** Apple's `concurrencyRange` / `defaultMaxConcurrent`, unchanged. */
    val CONCURRENCY_RANGE = 1..5
    private const val DEFAULT_MAX_CONCURRENT = 2

    /** Unique WorkManager work name for a record. Replaces Apple's whole `taskIdentifier` reconnection dance. */
    fun workName(id: String): String = "vortx-download-$id"

    private val lock = Any()

    @Volatile
    private var appContext: Context? = null

    /**
     * Most downloads we run at once. Beyond this, new downloads are created [DownloadState.QUEUED] and start
     * automatically as running ones finish / fail / are cancelled / are paused (start-next-on-finish).
     *
     * Kept small BY DEFAULT: each transfer is a multi-GB media file, and torrent transfers also pin the loopback
     * streaming server, so a low cap avoids thrashing bandwidth + disk + (for torrents) the server. USER-CONFIGURABLE
     * and persisted. RAISING the cap fills the freed slots immediately; LOWERING it NEVER stops an in-flight transfer
     * (that could corrupt a partial file), it only applies to future starts.
     */
    private val _maxConcurrentDownloads = MutableStateFlow(DEFAULT_MAX_CONCURRENT)
    val maxConcurrentDownloads: StateFlow<Int> = _maxConcurrentDownloads.asStateFlow()

    /**
     * Explicit drain order for queued downloads (queue-manager reorder). The queue otherwise drains oldest-first by
     * `addedAt`; this list lets the user move a pending item up or down. Persisted so a reorder survives relaunch.
     * May hold ids that are momentarily not queued (harmless: the ordering read filters to live queued rows) and is
     * pruned of removed ids on the next terminal transition.
     */
    private val _queueOrder = MutableStateFlow<List<String>>(emptyList())
    val queueOrder: StateFlow<List<String>> = _queueOrder.asStateFlow()

    /**
     * Record ids with a live transfer. Apple derives this from `taskForRecord`; here the [DownloadWorker] registers
     * itself via [markActive] when it starts and the terminal handlers clear it, so the count is exactly the number
     * of running downloads, which is what the cap gates on. After a process death this starts EMPTY and is refilled
     * by whichever workers WorkManager revives (they call [markActive] on start), which is why [reconcileInFlight]
     * only demotes records it can prove have no live work.
     */
    private val activeIds = mutableSetOf<String>()

    /**
     * Records parked after a transfer could not write its file while the user was LOCKED. Restarting immediately
     * would just re-download and fail again while still locked, so these are held [DownloadState.PAUSED] and
     * auto-resumed on user unlock. See [parkForUnlock] / [retryDownloadsAwaitingUnlock].
     *
     * PERSISTED, unlike Apple's in-memory `awaitingUnlockRetry`. Apple can keep it in memory because
     * `protectedDataDidBecomeAvailable` is delivered to a live app, and it accepts that a cold relaunch leaves the
     * record merely `.paused` (resumable by hand). On Android the unlock signal arrives at a manifest
     * [DownloadUnlockReceiver] that can run in a FRESH process, so an in-memory set would be empty exactly when the
     * recovery needs it. Persisting is what makes the #132 auto-recovery actually fire here.
     */
    private val awaitingUnlock = mutableSetOf<String>()

    /**
     * Per-record count of write-failure self-heal restarts, so a transient staging failure is retried once from
     * scratch, but a genuinely unwritable destination still surfaces its error on the second hit instead of looping.
     * Mirrors Apple's `cannotCreateFileRetries`.
     */
    private val writeFailureRetries = mutableMapOf<String, Int>()

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Volatile
    private var restored = false

    /**
     * Restore the queue-manager settings (fail-soft): a missing / out-of-range cap falls back to the default, missing
     * / garbage order data falls back to an empty order (plain `addedAt` draining).
     *
     * The prefs restore runs ONCE per process, not once per call. Several entry points init defensively (the
     * Application, [DownloadUnlockReceiver] in a fresh process, every [DownloadWorker] run), and re-reading prefs on
     * a LIVE process would overwrite in-memory state with a disk snapshot -- harmless only for as long as every
     * mutation happens to persist before the next init, which is not a property worth betting the parked-download set
     * on. Setting the context stays unconditional, since it is idempotent and always the same instance.
     */
    fun init(context: Context) {
        appContext = context.applicationContext
        if (restored) return
        synchronized(lock) {
            if (restored) return
            val p = prefs(context)
            _maxConcurrentDownloads.value = clampConcurrency(p.getInt(MAX_CONCURRENT_KEY, DEFAULT_MAX_CONCURRENT))
            _queueOrder.value = p.getString(QUEUE_ORDER_KEY, null)
                ?.split('\n')?.filter { it.isNotBlank() } ?: emptyList()
            awaitingUnlock.clear()
            awaitingUnlock.addAll(p.getStringSet(AWAITING_UNLOCK_KEY, emptySet()).orEmpty())
            restored = true
        }
    }

    // MARK: Public API

    /**
     * Begin downloading [stream] for the given title, fetching the already-resolved [resolvedUrl] (the SAME URL the
     * player would have used -- debrid/direct https, or the loopback torrent URL). Returns the record. No-ops to the
     * existing record if this exact video is already downloaded / downloading; a PAUSED record resumes instead of
     * being returned unchanged (which would read as a silent no-op), matching Apple.
     *
     * [requestHeaders] is an explicit parameter rather than being read off [stream], which is where Apple gets it
     * (`stream.requestHeaders`, derived from `behaviorHints.proxyHeaders.request`). The reason is a real gap in the
     * Android model, not a preference: [StreamSource] does not decode `proxyHeaders` at all. The field exists only on
     * the resolved [com.vortx.android.model.Playable] (`Playable.headers`, model/Media.kt), and NOTHING in the tree
     * currently populates even that one -- so header-gated add-ons are unserved on Android generally, for playback as
     * much as for downloads. Fixing that belongs to the engine decode, not to this subsystem. Passing the headers in
     * keeps the record schema and the worker correct NOW (both already apply them), so the day the decode lands the
     * caller has one argument to fill and nothing here changes.
     */
    fun download(
        stream: StreamSource,
        contentId: String,
        videoId: String,
        type: String,
        name: String,
        poster: String?,
        season: Int?,
        episode: Int?,
        resolvedUrl: String,
        sourceName: String?,
        qualityText: String?,
        requestHeaders: Map<String, String>? = null,
    ): DownloadRecord {
        DownloadStore.records.value.firstOrNull { it.videoId == videoId && it.state != DownloadState.FAILED }
            ?.let { existing ->
                if (existing.state == DownloadState.PAUSED) resume(existing.id)
                return existing
            }

        val id = UUID.randomUUID().toString()
        val ext = fileExtension(resolvedUrl)
        val headers = requestHeaders?.takeIf { it.isNotEmpty() }

        // HLS sources (adaptive .m3u8) cannot be saved by a single-file transfer -- it fetches only the playlist,
        // not the media segments. Apple downloads them properly on iOS via AVAssetDownloadTask and fails honestly
        // everywhere else; Android has no equivalent, so it takes that same honest failure. (An embed page that does
        // not end in .m3u8 is caught post-download by the content sniff in DownloadWorker.)
        if (!stream.isTorrent && isHLSPlaylistURL(resolvedUrl)) {
            val failed = DownloadRecord(
                id = id, contentId = contentId, videoId = videoId, type = type, name = name, poster = poster,
                season = season, episode = episode, sourceName = sourceName, qualityText = qualityText,
                isTorrent = false, headers = headers, remoteURL = resolvedUrl,
                localFilename = "$id.$ext", state = DownloadState.FAILED,
                errorText = "This source streams in segments (HLS), which can't be saved for offline on Android yet. " +
                    "Try a direct or debrid file source.",
            )
            DownloadStore.upsert(failed)
            return failed
        }

        // Honor the concurrency cap: start now only if a slot is free, else create the record QUEUED and let it
        // start when a running download finishes / fails / is cancelled / paused (start-next-on-finish).
        synchronized(lock) {
            val canStartNow = activeIds.size < _maxConcurrentDownloads.value
            val record = DownloadRecord(
                id = id, contentId = contentId, videoId = videoId, type = type, name = name, poster = poster,
                season = season, episode = episode, sourceName = sourceName, qualityText = qualityText,
                isTorrent = stream.isTorrent, headers = headers, remoteURL = resolvedUrl,
                localFilename = "$id.$ext",
                state = if (canStartNow) DownloadState.DOWNLOADING else DownloadState.QUEUED,
            )
            DownloadStore.upsert(record)
            runCatching { DownloadStore.ensureDownloadsDirectoryExists() }
                .onFailure { Log.w(TAG, "could not create Downloads dir up front", it) }

            if (canStartNow) startTransfer(record) else appendToQueueOrder(id)
            return DownloadStore.record(id) ?: record
        }
    }

    /**
     * Pause a download. A queued item has no live transfer yet: just mark it paused so it stops being eligible to
     * start. A running one has its worker cancelled; the partial file stays on disk and [resume] continues it with a
     * Range request (Android's analogue of Apple's URLSession resume data, and a stronger one -- it survives process
     * death, which Apple's in-memory `resumeData` does not).
     */
    fun pause(id: String) {
        synchronized(lock) {
            val record = DownloadStore.record(id) ?: return
            if (record.state == DownloadState.QUEUED) {
                DownloadStore.update(id) { it.copy(state = DownloadState.PAUSED) }
                return
            }
            cancelWork(id)
            activeIds.remove(id)
            DownloadStore.update(id) { it.copy(state = DownloadState.PAUSED) }
            afterSlotFreed()
        }
    }

    /**
     * Resume a paused / failed download. Respects the concurrency cap: if every slot is busy, re-queue instead of
     * starting now, so resuming several paused items can't blow past the cap.
     */
    fun resume(id: String) {
        synchronized(lock) {
            val record = DownloadStore.record(id) ?: return
            awaitingUnlock.remove(id)
            persistAwaitingUnlock()
            if (activeIds.size >= _maxConcurrentDownloads.value) {
                DownloadStore.update(id) { it.copy(state = DownloadState.QUEUED, errorText = null) }
                appendToQueueOrder(id)
                return
            }
            val updated = record.copy(state = DownloadState.DOWNLOADING, errorText = null)
            DownloadStore.update(id) { updated }
            startTransfer(updated)
        }
    }

    /** Cancel and remove the download entirely (transfer + record + on-disk file). */
    fun cancel(id: String) {
        synchronized(lock) {
            cancelWork(id)
            activeIds.remove(id)
            writeFailureRetries.remove(id)
            awaitingUnlock.remove(id)
            persistAwaitingUnlock()
            DownloadStore.remove(id)
            pruneQueueOrder()
            fillAvailableSlots()
        }
    }

    // MARK: Queue manager (concurrency cap + reorder)

    private fun clampConcurrency(value: Int): Int = value.coerceIn(CONCURRENCY_RANGE)

    /**
     * Set the max-concurrent-downloads cap. Clamped to [CONCURRENCY_RANGE] and persisted. RAISING the cap pulls
     * queued items into the newly-freed slots right away; LOWERING it leaves every running transfer alone (stopping
     * one could corrupt a partial file) and simply gates future starts.
     */
    fun setMaxConcurrentDownloads(value: Int) {
        synchronized(lock) {
            val clamped = clampConcurrency(value)
            if (clamped == _maxConcurrentDownloads.value) return
            _maxConcurrentDownloads.value = clamped
            appContext?.let { prefs(it).edit().putInt(MAX_CONCURRENT_KEY, clamped).apply() }
            fillAvailableSlots() // no-op when the cap dropped (activeIds already >= cap)
        }
    }

    /**
     * Queued records in the exact order they will start: explicit [queueOrder] first, then `addedAt` for any id not
     * yet in the order list. The queue view and the drainer both read THIS, so what the user sees is what starts next.
     */
    fun orderedQueuedRecords(): List<DownloadRecord> {
        val rank = _queueOrder.value.withIndex().associate { (index, id) -> id to index }
        return DownloadStore.records.value
            .filter { it.state == DownloadState.QUEUED }
            .sortedWith(compareBy({ rank[it.id] ?: Int.MAX_VALUE }, { it.addedAt }))
    }

    /** Move a pending download one place earlier / later in the drain order. */
    fun moveQueuedEarlier(id: String) = reorderQueued(id, -1)
    fun moveQueuedLater(id: String) = reorderQueued(id, +1)

    private fun reorderQueued(id: String, delta: Int) {
        synchronized(lock) {
            val ids = orderedQueuedRecords().map { it.id }.toMutableList()
            val from = ids.indexOf(id)
            if (from < 0) return
            val to = from + delta
            if (to !in ids.indices) return // already first / last: nothing to do
            java.util.Collections.swap(ids, from, to)
            _queueOrder.value = ids
            persistQueueOrder()
        }
    }

    /** Append a freshly-queued download to the tail of the drain order. Idempotent, so a re-queue never duplicates. */
    private fun appendToQueueOrder(id: String) {
        if (_queueOrder.value.contains(id)) return
        _queueOrder.value = _queueOrder.value + id
        persistQueueOrder()
    }

    /**
     * Drop ids whose record is gone (cancelled). State flips (queued <-> downloading <-> paused) are left in place so
     * a paused item keeps its position when it re-queues. Persists only on a real change.
     */
    private fun pruneQueueOrder() {
        val filtered = _queueOrder.value.filter { DownloadStore.record(it) != null }
        if (filtered == _queueOrder.value) return
        _queueOrder.value = filtered
        persistQueueOrder()
    }

    private fun persistQueueOrder() {
        appContext?.let { prefs(it).edit().putString(QUEUE_ORDER_KEY, _queueOrder.value.joinToString("\n")).apply() }
    }

    private fun persistAwaitingUnlock() {
        appContext?.let { prefs(it).edit().putStringSet(AWAITING_UNLOCK_KEY, awaitingUnlock.toSet()).apply() }
    }

    /**
     * Pull queued downloads into EVERY free slot. A cap raise opens several slots at once, so loop until the cap is
     * met or the queue is empty. Guarded against a no-progress spin: if a pass neither starts a transfer nor shrinks
     * the queue (e.g. every remaining record has a broken URL and was failed), stop.
     */
    private fun fillAvailableSlots() {
        fun queuedCount() = DownloadStore.records.value.count { it.state == DownloadState.QUEUED }
        while (activeIds.size < _maxConcurrentDownloads.value) {
            val beforeActive = activeIds.size
            val beforeQueued = queuedCount()
            startNextQueued()
            if (activeIds.size == beforeActive && queuedCount() == beforeQueued) break
        }
    }

    /**
     * Start the next queued download if a slot is free. Picks the head of the reorderable drain order, so the queue
     * drains in the order the user set, or request order when untouched. Fail-soft: a queued record whose source URL
     * no longer parses is marked failed and skipped, so one bad URL can't wedge the queue.
     */
    private fun startNextQueued() {
        if (activeIds.size >= _maxConcurrentDownloads.value) return
        val next = orderedQueuedRecords().firstOrNull() ?: return
        if (next.remoteURL.toHttpUrlOrNull() == null) {
            DownloadStore.update(next.id) { it.copy(state = DownloadState.FAILED, errorText = "Invalid source URL") }
            return
        }
        val started = next.copy(state = DownloadState.DOWNLOADING)
        DownloadStore.update(next.id) { started }
        startTransfer(started)
    }

    /** Common tail for every terminal/slot-freeing transition: prune the order, then fill the freed slot(s). */
    private fun afterSlotFreed() {
        pruneQueueOrder()
        fillAvailableSlots()
    }

    // MARK: Transfer lifecycle

    /**
     * Fail EARLY with a clear message when the volume can't hold the expected file, instead of running a full
     * multi-GB transfer that ends in an opaque write error. Only a HARD shortfall fails; an unknown size
     * (`bytesTotal == 0`, which is every fresh download and every torrent) is allowed through -- the worker
     * re-checks once the server declares a length.
     *
     * Only the REMAINING bytes still have to be written: a resumed partial already occupies its downloaded bytes on
     * the volume, so comparing the FULL size would double-count them and fail a nearly-complete resume as "not enough
     * storage" with ample free space (a bug Apple explicitly fixed; the same arithmetic applies here).
     */
    fun storageShortfall(record: DownloadRecord): Boolean {
        if (record.bytesTotal <= 0) return false
        val remaining = (record.bytesTotal - record.bytesDone).coerceAtLeast(0)
        if (remaining == 0L) return false
        val free = runCatching {
            val stat = StatFs(DownloadStore.downloadsDirectory().absolutePath)
            stat.availableBlocksLong * stat.blockSizeLong
        }.getOrNull() ?: return false
        return free < remaining + STORAGE_MARGIN_BYTES
    }

    /** Apple's ~200 MB margin, kept: the OS wants headroom and a partial write should not wedge the volume. */
    private const val STORAGE_MARGIN_BYTES = 200L * 1024L * 1024L

    private fun startTransfer(record: DownloadRecord) {
        val context = appContext
        if (context == null) {
            Log.w(TAG, "startTransfer before init(); record ${record.id} left queued")
            return
        }
        if (storageShortfall(record)) {
            DownloadStore.update(record.id) {
                it.copy(
                    state = DownloadState.FAILED,
                    errorText = "Not enough storage to save this download. Free up space and try again.",
                )
            }
            return
        }
        runCatching { DownloadStore.ensureDownloadsDirectoryExists() }
            .onFailure { Log.w(TAG, "could not create Downloads dir before transfer", it) }
        activeIds.add(record.id)
        // KEEP, not REPLACE: if WorkManager already has live work for this record (a revived worker after process
        // death), do not tear it down and restart the transfer from scratch.
        WorkManager.getInstance(context).enqueueUniqueWork(
            workName(record.id),
            ExistingWorkPolicy.KEEP,
            DownloadWorker.request(record.id),
        )
    }

    private fun cancelWork(id: String) {
        appContext?.let { WorkManager.getInstance(it).cancelUniqueWork(workName(id)) }
    }

    // MARK: Worker callbacks

    /**
     * The worker registers itself as it starts. This is what refills [activeIds] after a process death: WorkManager
     * revives at most `cap` workers (the manager never enqueued more than the cap), so the count stays correct by
     * construction rather than needing Apple's `getAllTasks` reconciliation.
     */
    fun markActive(id: String) {
        synchronized(lock) {
            activeIds.add(id)
            if (DownloadStore.record(id)?.state == DownloadState.QUEUED) {
                DownloadStore.update(id) { it.copy(state = DownloadState.DOWNLOADING) }
            }
        }
    }

    /** The transfer finished and the file is in place. */
    fun handleTransferComplete(id: String) {
        synchronized(lock) {
            activeIds.remove(id)
            writeFailureRetries.remove(id)
            DownloadStore.update(id) {
                it.copy(
                    state = DownloadState.COMPLETED,
                    bytesDone = maxOf(it.bytesDone, it.bytesTotal),
                    errorText = null,
                )
            }
            afterSlotFreed()
        }
    }

    /**
     * The worker was STOPPED rather than failing: WorkManager reclaimed it (constraint lost, system pressure, the
     * user swiped the app away) or [pause]/[cancel] cancelled it. Park the record resumable -- never delete it, the
     * partial bytes are intact on disk and a Range resume continues from them. This is the analogue of Apple's
     * `reconcileStuckDownloading` demotion, but delivered as an event instead of discovered on the next launch.
     *
     * A record the caller already moved out of DOWNLOADING (pause/cancel got there first) is left alone.
     */
    fun handleTransferStopped(id: String) {
        synchronized(lock) {
            activeIds.remove(id)
            if (DownloadStore.record(id)?.state == DownloadState.DOWNLOADING) {
                DownloadStore.update(id) { it.copy(state = DownloadState.PAUSED) }
            }
            afterSlotFreed()
        }
    }

    /**
     * The transfer failed. This is the Android face of Apple's `-3000` (`NSURLErrorCannotCreateFile`) branch -- the
     * #132 root cause -- and it keeps that branch's three cases and their ORDER, because the ordering is what makes
     * the lesson hold:
     *
     *  1. **Could not write while the user is LOCKED** -> PARK, do not consume the self-heal budget. Restarting now
     *     would just re-download gigabytes and fail again while still locked (Apple's "retry cap exhausted before the
     *     device unlocks" trap). The record parks [DownloadState.PAUSED] and auto-resumes on unlock via
     *     [DownloadUnlockReceiver], so a completed-while-locked download recovers itself instead of dead-ending.
     *  2. **Genuine out-of-space** -> HARD FAIL, always, and BEFORE any parking. Parking an ENOSPC would re-download
     *     gigabytes on every unlock and never succeed. The user has to free space, so say so.
     *  3. **Any other write failure, user unlocked** -> self-heal restart ONCE, then park (not dead-fail) if it
     *     recurs. A write failure is transient far more often than terminal, and dead-failing a 100%-downloaded title
     *     is exactly the #132 complaint.
     *
     * Everything else (a network error, a dead link, a non-media body) fails honestly with its own message.
     *
     * ANDROID EXPOSURE, HONESTLY: case 1's window is NARROWER here than on iOS. iOS's default file-protection class
     * makes app files unwritable whenever the SCREEN is locked, so an overnight transfer trips it routinely. Android
     * app-private storage is credential-encrypted, which stays writable once the user has unlocked ONCE since boot --
     * so the locked-write window is only (a) before the first unlock after a reboot, and (b) a work/secondary profile
     * that locked independently while the device stayed on. Case 1 will therefore fire far less often on Android than
     * the iOS report volume suggests. It is still implemented, because when it does fire the alternative is the
     * dead-end #132 is about, and because [UserManager.isUserUnlocked] is the exact signal for it.
     *
     * Returns the VERDICT for the caller to execute rather than restarting the transfer itself. That is not a style
     * choice, it is required for correctness: this runs while the failing worker is STILL RUNNING, and the restart is
     * an `enqueueUniqueWork` under the SAME unique name. With [ExistingWorkPolicy.KEEP] that enqueue would be
     * silently DROPPED (live work already holds the name) and the record would sit DOWNLOADING forever with nothing
     * behind it; with REPLACE it would cancel the very worker asking the question and race its own state write. So
     * the manager decides and [DownloadWorker] executes the decision through WorkManager's own retry, which reuses
     * the same work rather than fighting it.
     */
    fun handleTransferFailure(id: String, cause: Throwable): FailureVerdict {
        synchronized(lock) {
            val detail = failureDetail(cause)
            if (DownloadStore.record(id) == null) {
                // Cancelled out from under the worker; nothing to record.
                activeIds.remove(id)
                return FailureVerdict.TERMINAL
            }

            // (2) FIRST: genuine out-of-space is terminal wherever it appears. Checked ahead of the locked branch so
            // that a full volume before first unlock still fails honestly instead of park-looping forever.
            if (isOutOfSpace(cause)) {
                Log.w(TAG, "out of space id=$id detail=$detail")
                activeIds.remove(id)
                DownloadStore.update(id) {
                    it.copy(
                        state = DownloadState.FAILED,
                        errorText = "Not enough storage to save this download. Free up space and try again.",
                    )
                }
                afterSlotFreed()
                return FailureVerdict.TERMINAL
            }

            if (isWriteFailure(cause)) {
                // (1) Could not write while locked: park for unlock, do NOT consume the self-heal budget.
                if (!isUserUnlocked()) {
                    Log.w(TAG, "write failed while locked, parked for unlock retry id=$id detail=$detail")
                    activeIds.remove(id)
                    parkForUnlock(
                        id,
                        "Waiting to finish saving. It will retry automatically when you unlock your device.",
                    )
                    afterSlotFreed()
                    return FailureVerdict.TERMINAL
                }
                // (3) Unlocked, so this is a transient write failure. Retry ONCE.
                //
                // DIVERGENCE, deliberate: Apple drops its stashed resume data and restarts "from scratch" here,
                // because its resume state is an OPAQUE blob produced by a background daemon whose staging just
                // misbehaved, so re-staging fresh is the only lever it has. Our resume state is the .part file we
                // wrote ourselves; it is not suspect just because one write failed. So the retry RESUMES from it
                // rather than re-downloading gigabytes. Same one-retry budget, far cheaper attempt.
                val attempts = writeFailureRetries.getOrDefault(id, 0)
                if (attempts < 1) {
                    writeFailureRetries[id] = attempts + 1
                    Log.w(TAG, "write failure retry id=$id attempt=${attempts + 1} detail=$detail")
                    // Keep the slot: the SAME work retries, so releasing it here would let a queued download start
                    // alongside and momentarily exceed the cap.
                    DownloadStore.update(id) { it.copy(state = DownloadState.DOWNLOADING, errorText = null) }
                    return FailureVerdict.RETRY
                }
                // (3b) The one retry ALSO failed. Do NOT dead-fail (the #132 behaviour that stranded a
                // 100%-downloaded title at "couldn't save"). Park it: it auto-retries on the next unlock / app
                // foreground. Because a later resume resets the self-heal counter, each retry gets a fresh
                // retry-then-re-park cycle rather than burning through to a hard failure.
                Log.w(TAG, "write failure persisted after retry, parked id=$id detail=$detail")
                activeIds.remove(id)
                parkForUnlock(
                    id,
                    "Waiting to finish saving. It will retry automatically when you unlock your device or reopen the app.",
                )
                afterSlotFreed()
                return FailureVerdict.TERMINAL
            }

            Log.w(TAG, "transfer FAILED id=$id detail=$detail")
            activeIds.remove(id)
            DownloadStore.update(id) {
                it.copy(state = DownloadState.FAILED, errorText = "Couldn't save this download: $detail")
            }
            afterSlotFreed()
            return FailureVerdict.TERMINAL
        }
    }

    /** What [DownloadWorker] should do with a failure, decided by [handleTransferFailure]. */
    enum class FailureVerdict {
        /** Let WorkManager re-run the SAME work on its backoff; the record stays DOWNLOADING and keeps its slot. */
        RETRY,

        /** The record has reached a resting state (failed or parked); do not re-run. */
        TERMINAL,
    }

    /** Park a record for unlock-triggered auto-resume, clearing its self-heal budget for the next attempt. */
    private fun parkForUnlock(id: String, message: String) {
        awaitingUnlock.add(id)
        writeFailureRetries.remove(id)
        persistAwaitingUnlock()
        DownloadStore.update(id) { it.copy(state = DownloadState.PAUSED, errorText = message) }
    }

    /**
     * Resume every download parked by a locked-write failure, once the user is unlocked again. Each still-paused
     * record goes back through [resume] (which continues from the partial file via a Range request) and its holding
     * message is cleared. A record the user cancelled or that changed state is skipped. No-op when nothing is parked
     * (the common case), so an ordinary unlock / foreground pays nothing.
     *
     * Apple wires three triggers (`protectedDataDidBecomeAvailable`, `didBecomeActive`, `willEnterForeground`); the
     * Android equivalents are [DownloadUnlockReceiver] (`ACTION_USER_UNLOCKED` + `ACTION_BOOT_COMPLETED`) and the
     * app-foreground call in [com.vortx.android.VortXApplication].
     */
    fun retryDownloadsAwaitingUnlock() {
        val ids = synchronized(lock) {
            if (awaitingUnlock.isEmpty() || !isUserUnlocked()) return
            awaitingUnlock.toList().also {
                awaitingUnlock.clear()
                persistAwaitingUnlock()
            }
        }
        for (id in ids) {
            val record = DownloadStore.record(id) ?: continue
            if (record.state != DownloadState.PAUSED) continue
            DownloadStore.update(id) { it.copy(errorText = null) }
            resume(id)
        }
    }

    /**
     * Reconcile records that CLAIM to be downloading but have no live WorkManager work -- e.g. WorkManager exhausted
     * its retries, or the work was cancelled while the app was dead. Demote them to PAUSED (resumable); never delete,
     * the partial bytes are on disk.
     *
     * This is Apple's `reconnectInFlightDownloads`, and it is dramatically smaller: Apple must re-create its
     * background sessions, `getAllTasks`, and map opaque task identifiers back to records via a persisted
     * `taskIdentifier` plus a `taskDescription` filename fallback. WorkManager keys work by OUR OWN record id, so a
     * membership check is the whole job. Blocking on WorkManager's future, so call it OFF the main thread.
     */
    fun reconcileInFlight() {
        val context = appContext ?: return
        val inFlight = DownloadStore.records.value.filter { it.state == DownloadState.DOWNLOADING }
        if (inFlight.isEmpty()) return
        val wm = WorkManager.getInstance(context)
        for (record in inFlight) {
            val live = runCatching {
                wm.getWorkInfosForUniqueWork(workName(record.id)).get()
                    .any { !it.state.isFinished }
            }.getOrDefault(true) // a query failure must not demote a healthy download
            if (live) {
                synchronized(lock) { activeIds.add(record.id) }
                continue
            }
            synchronized(lock) {
                activeIds.remove(record.id)
                if (DownloadStore.record(record.id)?.state == DownloadState.DOWNLOADING) {
                    DownloadStore.update(record.id) { it.copy(state = DownloadState.PAUSED) }
                }
            }
        }
        synchronized(lock) { afterSlotFreed() }
    }

    // MARK: Helpers

    /**
     * True when app-private (credential-encrypted) storage is writable right now, i.e. the user has unlocked since
     * boot. The Android analogue of Apple's `isProtectedDataAvailable`.
     *
     * `isUserUnlocked` arrived in API 24 and minSdk is 26, so no version guard is needed. Both fallbacks return TRUE
     * (assume writable) rather than false: a false would park a perfectly healthy download for an unlock that already
     * happened, which is a worse failure than letting the write attempt proceed and report what actually goes wrong.
     */
    fun isUserUnlocked(): Boolean {
        val context = appContext ?: return true
        val userManager = context.getSystemService(Context.USER_SERVICE) as? UserManager ?: return true
        return userManager.isUserUnlocked
    }

    /**
     * True when a resolved playback URL is an adaptive HLS playlist (.m3u8): a single-file transfer only fetches the
     * tiny playlist, not the media segments. Cheap string check, no network.
     */
    fun isHLSPlaylistURL(url: String): Boolean = url.lowercase().substringBefore('?').endsWith(".m3u8") ||
        url.lowercase().contains(".m3u8")

    /**
     * A reasonable media extension from the URL path, defaulting to mp4 (the loopback torrent URL and many debrid
     * links carry no extension). Only used to name the local file.
     */
    private fun fileExtension(url: String): String {
        val known = setOf("mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "flv", "wmv")
        val ext = url.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase()
        return if (ext in known) ext else "mp4"
    }

    /** Minimal URL sanity check, standing in for Apple's `URL(string:)` guard. */
    private fun String.toHttpUrlOrNull(): String? =
        runCatching { java.net.URL(this).takeIf { it.host != null }?.let { this } }.getOrNull()

    /**
     * True when a failure is ultimately a FILE-WRITE problem (as opposed to a network/HTTP one). Apple gets this for
     * free from a single error code (`NSURLErrorCannotCreateFile`, -3000); Android has no such code, so the write
     * sites type their own failures instead.
     *
     * Deliberately does NOT treat a bare [java.io.FileNotFoundException] as a write failure, even though a failed
     * `RandomAccessFile` open throws one: `HttpURLConnection.getInputStream()` ALSO throws it for a 404, so matching
     * on it would classify a dead link as a write problem and park it for unlock FOREVER instead of failing honestly.
     * [DownloadWorker] wraps its genuine write sites in [DownloadWriteException] precisely so the distinction is made
     * where the code knows what it was doing, rather than guessed from an exception type that means both things.
     */
    private fun isWriteFailure(error: Throwable): Boolean {
        var cursor: Throwable? = error
        while (cursor != null) {
            if (cursor is DownloadWriteException) return true
            if (cursor is android.system.ErrnoException) return true
            cursor = cursor.cause
        }
        return false
    }

    /**
     * True when a failure is ultimately an out-of-space condition (POSIX ENOSPC), at the top level or as an
     * underlying cause. A write failure backed by ENOSPC really is a full volume, so it must stay a hard failure (the
     * user has to free space) instead of being parked for retry: parking would re-download gigabytes and fail again
     * at write on every unlock, never succeeding. Keeps Apple's "genuine out-of-space keeps failing" invariant.
     */
    fun isOutOfSpace(error: Throwable): Boolean {
        var cursor: Throwable? = error
        while (cursor != null) {
            // Our own preflight verdict. Structural, not message-matched: this exception carries a HUMAN message
            // ("Not enough storage...") with no errno text in it, so a text-only check would miss it, drop it into
            // the write-failure ladder, and PARK a genuinely full volume for retry forever. That is precisely the
            // failure the "genuine out-of-space must still fail honestly" invariant exists to prevent.
            if (cursor is DownloadOutOfSpaceException) return true
            if (cursor is android.system.ErrnoException && cursor.errno == android.system.OsConstants.ENOSPC) return true
            val message = cursor.message.orEmpty()
            // Java's FileOutputStream does not throw ErrnoException; it wraps the errno into an IOException message
            // ("write failed: ENOSPC (No space left on device)"), so the text is the only signal available there.
            if (message.contains("ENOSPC") || message.contains("No space left on device", ignoreCase = true)) return true
            cursor = cursor.cause
        }
        return false
    }

    /**
     * A compact, self-diagnosing cause for a failed download, mirroring Apple's `downloadFailureDetail`: it digs PAST
     * the top-level exception into its underlying cause so a write failure is legible from a screenshot alone instead
     * of an opaque class name.
     */
    fun failureDetail(error: Throwable): String {
        val parts = mutableListOf<String>()
        var cursor: Throwable? = error
        var depth = 0
        while (cursor != null && depth < 4) {
            val label = cursor.javaClass.simpleName
            val message = cursor.message?.takeIf { it.isNotBlank() }
            parts.add(if (message != null) "$label: $message" else label)
            if (cursor is android.system.ErrnoException) {
                parts.add("errno=${android.system.OsConstants.errnoName(cursor.errno) ?: cursor.errno}")
            }
            cursor = cursor.cause
            depth++
        }
        return parts.joinToString(" | ")
    }
}

/**
 * A file-write failure raised by [DownloadWorker], so [DownloadManager.handleTransferFailure] can tell a write
 * problem (park / self-heal territory, the #132 path) from a network problem (fail honestly) WITHOUT string-matching
 * a generic [java.io.IOException]. Apple distinguishes these by error code; Kotlin has no such code, so the worker
 * types the failure at the point it knows what it was doing.
 */
class DownloadWriteException(message: String, cause: Throwable?) : java.io.IOException(message, cause)

/**
 * A genuine out-of-space verdict raised by the worker's own preflight (a declared Content-Length the volume cannot
 * hold), as opposed to one the kernel reported via ENOSPC.
 *
 * It is a distinct TYPE rather than a [DownloadWriteException] with a telling message because
 * [DownloadManager.isOutOfSpace] must recognise it BEFORE the write ladder does, and it must do so structurally: this
 * failure's message is human copy for the user ("Not enough storage..."), so an errno text match would not catch it,
 * and it would be parked for unlock retry forever instead of failing honestly. Out-of-space is the one condition the
 * park ladder must never swallow: retrying re-downloads gigabytes and fails at exactly the same byte every time.
 */
class DownloadOutOfSpaceException(message: String) : java.io.IOException(message)
