package com.vortx.android.downloads

import android.content.Context
import android.os.StatFs
import android.os.UserManager
import android.util.Log
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkManager
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.Executor

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
 * syncs the list. Apple's manager is `@MainActor`-isolated; this one uses [lock] instead because [DownloadWorker]
 * calls back from a WorkManager thread. The lock covers bookkeeping, store writes, and each small partial-file
 * mutation needed to make generation ownership atomic. It is never held across network I/O.
 */
object DownloadManager {

    private const val TAG = "downloads"
    private const val OWNER_CHANGED_ERROR =
        "The VortX account that created this debrid download is no longer active."

    private const val PREFS = "vortx.downloads"
    const val MAX_CONCURRENT_KEY = "vortx.downloads.maxConcurrent"
    /**
     * Gates the Settings > Downloads row. The download subsystem (manager, worker, store, notifications,
     * screen) is fully built AND now has a live CREATE entry point: the detail-screen source-row long-press
     * "Download" action resolves the chosen source through the same [com.vortx.android.data.CatalogRepository.resolve]
     * the player uses and calls [download] (see [com.vortx.android.ui.viewmodel.DetailViewModel.download]). So
     * the row is shown: a tester can fill the screen. A raw torrent with no debrid key still cannot be turned
     * into a direct URL (torrent-to-disk needs the not-yet-wired streaming server), so it surfaces the
     * resolver's own message instead of enqueuing; direct / debrid / HTTP sources download for real.
     */
    const val CREATE_PATH_WIRED = true
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
    @Volatile
    private var debridKeys: DebridKeys? = null

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
     * Record id to opaque generation for every live transfer. The token makes ownership ABA-safe across pause/resume:
     * a delayed callback from generation A cannot remove or complete the active generation B slot. After process death
     * this starts empty and is refilled by revived workers through [claimTransfer] or by [reconcileInFlight].
     */
    private val activeGenerations = mutableMapOf<String, String>()

    /**
     * A generation published to the local index but whose WorkManager enqueue operation has not completed yet.
     * Reconciliation must treat it as live: WorkManager can legitimately return no rows until its asynchronous
     * database transaction commits. The operation callback clears this marker on success and generation-safely
     * fails the record on error.
     */
    private val pendingEnqueueGenerations = mutableMapOf<String, String>()

    /** A ListenableFuture invokes this only after completion, so running its tiny bookkeeping callback inline is safe. */
    private val directExecutor = Executor { command -> command.run() }

    /** Legacy DOWNLOADING rows without a generation still reserve capacity until reconciliation parks them. */
    private val legacyStartupReservations = mutableSetOf<String>()

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
        if (debridKeys == null) debridKeys = DebridKeys(context.applicationContext)
        if (restored) return
        synchronized(lock) {
            if (restored) return
            val p = prefs(context)
            _maxConcurrentDownloads.value = clampConcurrency(p.getInt(MAX_CONCURRENT_KEY, DEFAULT_MAX_CONCURRENT))
            _queueOrder.value = p.getString(QUEUE_ORDER_KEY, null)
                ?.split('\n')?.filter { it.isNotBlank() } ?: emptyList()
            awaitingUnlock.clear()
            awaitingUnlock.addAll(p.getStringSet(AWAITING_UNLOCK_KEY, emptySet()).orEmpty())
            val persistedRecords = DownloadStore.records.value
            val startupReservedIds = DownloadQueuePolicy.startupReservedIds(persistedRecords)
            persistedRecords
                .filter { it.id in startupReservedIds }
                .forEach { record ->
                    val generation = record.transferGeneration
                    if (generation == null) {
                        legacyStartupReservations.add(record.id)
                    } else {
                        activeGenerations[record.id] = generation
                    }
                }
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
     * [requestHeaders] is an explicit parameter rather than being read off [stream], mirroring how the caller
     * already holds the RESOLVED [com.vortx.android.model.Playable] whose `headers` carry the stream's declared
     * `behaviorHints.proxyHeaders.request` (decoded by EngineState.parseStream into [StreamSource.requestHeaders]
     * and attached at resolve time by EngineStremioRepository.resolve). DetailViewModel.download forwards
     * `playable.headers` here, so a header-gated CDN (Referer / User-Agent requirement) serves the download the
     * same way it serves playback.
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
        isDolbyVision: Boolean = false,
        isAtmos: Boolean = false,
        requestHeaders: Map<String, String>? = null,
        debridOwnerIdentity: String? = null,
        debridOwnerGeneration: Long? = null,
    ): DownloadRecord = synchronized(lock) {
        DownloadStore.records.value.firstOrNull { it.videoId == videoId && it.state != DownloadState.FAILED }
            ?.let { existing ->
                if (
                    existing.state != DownloadState.COMPLETED &&
                    !isDebridOwnerCurrent(existing)
                ) {
                    cancelWork(existing.id)
                    releaseSlotReservation(existing.id, existing.transferGeneration)
                    DownloadStore.update(existing.id) {
                        it.copy(
                            state = DownloadState.FAILED,
                            transferGeneration = null,
                            errorText = OWNER_CHANGED_ERROR,
                        )
                    }
                } else {
                    if (existing.state == DownloadState.PAUSED) resume(existing.id)
                    return@synchronized existing
                }
            }

        val id = UUID.randomUUID().toString()
        val ext = fileExtension(resolvedUrl)
        val headers = requestHeaders?.takeIf { it.isNotEmpty() }
        if (
            !DownloadDebridOwnerPolicy.isCurrent(
                expectedIdentity = debridOwnerIdentity,
                expectedGeneration = debridOwnerGeneration,
                current = currentDebridOwner(),
            )
        ) {
            val failed = DownloadRecord(
                id = id, contentId = contentId, videoId = videoId, type = type, name = name, poster = poster,
                season = season, episode = episode, sourceName = sourceName, qualityText = qualityText,
                isDolbyVision = isDolbyVision, isAtmos = isAtmos,
                isTorrent = stream.isTorrent, headers = headers, remoteURL = resolvedUrl,
                debridOwnerIdentity = debridOwnerIdentity,
                debridOwnerGeneration = debridOwnerGeneration,
                localFilename = "$id.$ext", state = DownloadState.FAILED,
                errorText = OWNER_CHANGED_ERROR,
            )
            DownloadStore.upsert(failed)
            return@synchronized failed
        }

        // HLS sources (adaptive .m3u8) cannot be saved by a single-file transfer -- it fetches only the playlist,
        // not the media segments. Apple downloads them properly on iOS via AVAssetDownloadTask and fails honestly
        // everywhere else; Android has no equivalent, so it takes that same honest failure. (An embed page that does
        // not end in .m3u8 is caught post-download by the content sniff in DownloadWorker.)
        if (!stream.isTorrent && isHLSPlaylistURL(resolvedUrl)) {
            val failed = DownloadRecord(
                id = id, contentId = contentId, videoId = videoId, type = type, name = name, poster = poster,
                season = season, episode = episode, sourceName = sourceName, qualityText = qualityText,
                isDolbyVision = isDolbyVision, isAtmos = isAtmos,
                isTorrent = false, headers = headers, remoteURL = resolvedUrl,
                debridOwnerIdentity = debridOwnerIdentity,
                debridOwnerGeneration = debridOwnerGeneration,
                localFilename = "$id.$ext", state = DownloadState.FAILED,
                errorText = "This source streams in segments (HLS), which can't be saved for offline on Android yet. " +
                    "Try a direct or debrid file source.",
            )
            DownloadStore.upsert(failed)
            return@synchronized failed
        }

        // Honor the concurrency cap: start now only if a slot is free, else create the record QUEUED and let it
        // start when a running download finishes / fails / is cancelled / paused (start-next-on-finish).
        val canStartNow = hasFreeSlot()
        val generation = if (canStartNow) newTransferGeneration() else null
        val record = DownloadRecord(
            id = id, contentId = contentId, videoId = videoId, type = type, name = name, poster = poster,
            season = season, episode = episode, sourceName = sourceName, qualityText = qualityText,
            isDolbyVision = isDolbyVision, isAtmos = isAtmos,
            isTorrent = stream.isTorrent, headers = headers, remoteURL = resolvedUrl,
            debridOwnerIdentity = debridOwnerIdentity,
            debridOwnerGeneration = debridOwnerGeneration,
            localFilename = "$id.$ext",
            state = if (canStartNow) DownloadState.DOWNLOADING else DownloadState.QUEUED,
            transferGeneration = generation,
        )
        DownloadStore.upsert(record)
        runCatching { DownloadStore.ensureDownloadsDirectoryExists() }
            .onFailure { Log.w(TAG, "could not create Downloads dir up front", it) }

        if (canStartNow) {
            if (startTransfer(record).freesSlot) afterSlotFreed()
        } else {
            appendToQueueOrder(id)
        }
        DownloadStore.record(id) ?: record
    }

    /**
     * Pause a download. A queued item has no live transfer yet: just mark it paused so it stops being eligible to
     * start. A running one has its worker cancelled; the partial file stays on disk and [resume] continues it only
     * when a strong ETag proves the Range belongs to the same representation, otherwise it restarts from zero.
     */
    fun pause(id: String) {
        synchronized(lock) {
            val record = DownloadStore.record(id) ?: return
            val pausedState = DownloadTransferStatePolicy.pause(record.state) ?: return
            if (record.state == DownloadState.QUEUED) {
                DownloadStore.update(id) { it.copy(state = pausedState, transferGeneration = null) }
                return
            }
            cancelWork(id)
            releaseSlotReservation(id, record.transferGeneration)
            DownloadStore.update(id) { it.copy(state = pausedState, transferGeneration = null) }
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
            if (!DownloadTransferStatePolicy.mayResume(record.state)) return
            if (!isDebridOwnerCurrent(record)) {
                DownloadStore.update(id) {
                    it.copy(
                        state = DownloadState.FAILED,
                        transferGeneration = null,
                        errorText = OWNER_CHANGED_ERROR,
                    )
                }
                return
            }
            awaitingUnlock.remove(id)
            persistAwaitingUnlock()
            if (!hasFreeSlot()) {
                DownloadStore.update(id) {
                    it.copy(
                        state = DownloadState.QUEUED,
                        transferGeneration = null,
                        errorText = null,
                    )
                }
                appendToQueueOrder(id)
                return
            }
            val updated = record.copy(
                state = DownloadState.DOWNLOADING,
                transferGeneration = newTransferGeneration(),
                errorText = null,
            )
            DownloadStore.update(id) { updated }
            if (startTransfer(updated).freesSlot) afterSlotFreed()
        }
    }

    /** Cancel and remove the download entirely (transfer + record + on-disk file). */
    fun cancel(id: String) {
        synchronized(lock) {
            cancelWork(id)
            val generation = DownloadStore.record(id)?.transferGeneration
            releaseSlotReservation(id, generation)
            awaitingUnlock.remove(id)
            persistAwaitingUnlock()
            DownloadStore.remove(id)
            pruneQueueOrder()
            fillAvailableSlots()
        }
    }

    // MARK: Queue manager (concurrency cap + reorder)

    private fun clampConcurrency(value: Int): Int = DownloadQueuePolicy.clampConcurrency(value, CONCURRENCY_RANGE)

    /**
     * The concurrency-cap gate, funnelled through [DownloadQueuePolicy] so EVERY start path (create, resume, queue
     * drain, cap raise) enforces the cap identically. Reads the live [activeGenerations] count, so it must be called under
     * [lock] like the state it gates. Kept as a thin instance wrapper (rather than inlining the policy call at each
     * site) so the four call sites stay a single readable predicate.
     */
    private fun hasFreeSlot(): Boolean =
        DownloadQueuePolicy.canStartNow(
            activeCount = (activeGenerations.keys + legacyStartupReservations).size,
            cap = _maxConcurrentDownloads.value,
        )

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
            fillAvailableSlots() // no-op when the cap dropped (active generations already >= cap)
        }
    }

    /**
     * Queued records in the exact order they will start: explicit [queueOrder] first, then `addedAt` for any id not
     * yet in the order list. The queue view and the drainer both read THIS, so what the user sees is what starts next.
     */
    fun orderedQueuedRecords(): List<DownloadRecord> =
        DownloadQueuePolicy.orderedQueued(DownloadStore.records.value, _queueOrder.value)

    /** Move a pending download one place earlier / later in the drain order. */
    fun moveQueuedEarlier(id: String) = reorderQueued(id, -1)
    fun moveQueuedLater(id: String) = reorderQueued(id, +1)

    private fun reorderQueued(id: String, delta: Int) {
        synchronized(lock) {
            val ids = orderedQueuedRecords().map { it.id }
            // null == nothing to do: the id is not queued, or it is already at the end it is being moved toward.
            val reordered = DownloadQueuePolicy.reorder(ids, id, delta) ?: return
            _queueOrder.value = reordered
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
        while (hasFreeSlot()) {
            val beforeActive = activeGenerations.size
            val beforeQueued = queuedCount()
            startNextQueued()
            if (activeGenerations.size == beforeActive && queuedCount() == beforeQueued) break
        }
    }

    /**
     * Start the next queued download if a slot is free. Picks the head of the reorderable drain order, so the queue
     * drains in the order the user set, or request order when untouched. Fail-soft: a queued record whose source URL
     * no longer parses is marked failed and skipped, so one bad URL can't wedge the queue.
     */
    private fun startNextQueued() {
        if (!hasFreeSlot()) return
        val next = orderedQueuedRecords().firstOrNull() ?: return
        if (!isDebridOwnerCurrent(next)) {
            DownloadStore.update(next.id) {
                it.copy(
                    state = DownloadState.FAILED,
                    transferGeneration = null,
                    errorText = OWNER_CHANGED_ERROR,
                )
            }
            return
        }
        if (next.remoteURL.toHttpUrlOrNull() == null) {
            DownloadStore.update(next.id) {
                it.copy(
                    state = DownloadState.FAILED,
                    transferGeneration = null,
                    errorText = "Invalid source URL",
                )
            }
            return
        }
        val started = next.copy(
            state = DownloadState.DOWNLOADING,
            transferGeneration = newTransferGeneration(),
        )
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
        // Fast path: an unknown or already-complete size can't short the volume, so skip the StatFs syscall entirely
        // (this also preserves "a fresh download / torrent is allowed through" without touching the disk). The two
        // guards together are exactly the policy's own early-outs (bytesTotal <= 0, and remaining == 0 i.e.
        // bytesDone >= bytesTotal), so the delegated call below only ever runs the real free-space comparison.
        if (record.bytesTotal <= 0 || record.bytesDone >= record.bytesTotal) return false
        val free = runCatching {
            val stat = StatFs(DownloadStore.downloadsDirectory().absolutePath)
            stat.availableBlocksLong * stat.blockSizeLong
        }.getOrNull() ?: return false
        return DownloadQueuePolicy.hasStorageShortfall(
            bytesTotal = record.bytesTotal, bytesDone = record.bytesDone,
            freeBytes = free, marginBytes = STORAGE_MARGIN_BYTES,
        )
    }

    /** Apple's ~200 MB margin, kept: the OS wants headroom and a partial write should not wedge the volume. */
    private const val STORAGE_MARGIN_BYTES = 200L * 1024L * 1024L

    private fun newTransferGeneration(): String = UUID.randomUUID().toString()

    private fun releaseActive(id: String, generation: String?): Boolean {
        if (generation == null) return false
        if (pendingEnqueueGenerations[id] == generation) pendingEnqueueGenerations.remove(id)
        if (activeGenerations[id] != generation) return false
        activeGenerations.remove(id)
        return true
    }

    private fun releaseSlotReservation(id: String, generation: String?): Boolean =
        if (generation == null) legacyStartupReservations.remove(id) else releaseActive(id, generation)

    private fun ownsTransferLocked(record: DownloadRecord?, generation: String): Boolean =
        record != null &&
            record.state == DownloadState.DOWNLOADING &&
            DownloadTransferStatePolicy.owns(
                recordGeneration = record.transferGeneration,
                activeGeneration = activeGenerations[record.id],
                requestedGeneration = generation,
            )

    private fun startTransfer(record: DownloadRecord): DownloadTransferStartResult {
        val context = appContext
        if (context == null) {
            Log.w(TAG, "startTransfer before init(); record ${record.id} left queued")
            return DownloadTransferStartResult.NOT_STARTED
        }
        val generation = record.transferGeneration ?: run {
            Log.w(TAG, "startTransfer without generation; record ${record.id} not scheduled")
            return DownloadTransferStartResult.NOT_STARTED
        }
        if (!isDebridOwnerCurrent(record)) {
            releaseActive(record.id, generation)
            DownloadStore.updateIf(
                id = record.id,
                predicate = { it.transferGeneration == generation },
            ) {
                it.copy(
                    state = DownloadState.FAILED,
                    transferGeneration = null,
                    errorText = OWNER_CHANGED_ERROR,
                )
            }
            return DownloadTransferStartResult.PREFLIGHT_FAILED
        }
        val current = DownloadStore.record(record.id)
        if (
            current?.state != DownloadState.DOWNLOADING ||
            current.transferGeneration != generation
        ) {
            return DownloadTransferStartResult.NOT_STARTED
        }
        if (storageShortfall(record)) {
            val failed = DownloadStore.updateIf(
                id = record.id,
                predicate = { it.transferGeneration == generation },
            ) {
                it.copy(
                    state = DownloadState.FAILED,
                    transferGeneration = null,
                    errorText = "Not enough storage to save this download. Free up space and try again.",
                )
            }
            return if (failed != null) {
                DownloadTransferStartResult.PREFLIGHT_FAILED
            } else {
                DownloadTransferStartResult.NOT_STARTED
            }
        }
        runCatching { DownloadStore.ensureDownloadsDirectoryExists() }
            .onFailure { Log.w(TAG, "could not create Downloads dir before transfer", it) }
        activeGenerations[record.id] = generation
        pendingEnqueueGenerations[record.id] = generation
        // REPLACE any older generation still winding down after pause/cancel. KEEP can discard an immediate resume
        // while the cancelled worker still owns the unique name, stranding the new generation with no worker.
        // A revived current-generation worker never comes through startTransfer, so it is not replaced here.
        val operation = try {
            WorkManager.getInstance(context).enqueueUniqueWork(
                workName(record.id),
                ExistingWorkPolicy.REPLACE,
                DownloadWorker.request(record.id, generation),
            )
        } catch (cause: Throwable) {
            return failEnqueue(record, generation, cause)
        }
        val result = operation.result
        try {
            result.addListener(
                {
                    val failure = runCatching { result.get() }.exceptionOrNull()
                    synchronized(lock) {
                        if (pendingEnqueueGenerations[record.id] != generation) return@synchronized
                        if (failure == null) {
                            pendingEnqueueGenerations.remove(record.id)
                        } else if (failEnqueue(record, generation, failure).freesSlot) {
                            afterSlotFreed()
                        }
                    }
                },
                directExecutor,
            )
        } catch (cause: Throwable) {
            return failEnqueue(record, generation, cause)
        }
        return DownloadTransferStartResult.STARTED
    }

    private fun failEnqueue(
        record: DownloadRecord,
        generation: String,
        cause: Throwable,
    ): DownloadTransferStartResult {
        if (pendingEnqueueGenerations[record.id] != generation) {
            return DownloadTransferStartResult.NOT_STARTED
        }
        Log.w(TAG, "could not enqueue download ${record.id}", cause)
        releaseActive(record.id, generation)
        val failed = DownloadStore.updateIf(
            id = record.id,
            predicate = {
                it.state == DownloadState.DOWNLOADING &&
                    it.transferGeneration == generation
            },
        ) {
            it.copy(
                state = DownloadState.FAILED,
                transferGeneration = null,
                errorText = "Could not schedule this download. Try again.",
            )
        }
        return if (failed != null) {
            DownloadTransferStartResult.ENQUEUE_FAILED
        } else {
            DownloadTransferStartResult.NOT_STARTED
        }
    }

    private fun cancelWork(id: String) {
        appContext?.let { WorkManager.getInstance(it).cancelUniqueWork(workName(id)) }
    }

    // MARK: Worker callbacks

    /**
     * Atomically claim a record before any transfer or local finalization. WorkManager may deliver stale work after
     * pause, failure, or completion; only QUEUED and DOWNLOADING remain authorized to run.
     */
    fun claimTransfer(id: String, generation: String): Boolean {
        synchronized(lock) {
            val record = DownloadStore.record(id) ?: return false
            when (
                val claim = DownloadTransferClaimPolicy.decide(
                    record = record,
                    requestedGeneration = generation,
                    isOwnerCurrent = ::isDebridOwnerCurrent,
                )
            ) {
                DownloadTransferClaimDecision.OwnerChanged -> {
                    handleDebridOwnerChangedLocked(id, generation)
                    return false
                }
                DownloadTransferClaimDecision.Rejected -> return false
                is DownloadTransferClaimDecision.Claimed -> if (claim.state != record.state) {
                    DownloadStore.updateIf(
                        id = id,
                        predicate = { it.transferGeneration == generation },
                    ) {
                        it.copy(state = claim.state)
                    } ?: return false
                }
            }
            activeGenerations[id] = generation
            legacyStartupReservations.remove(id)
            return true
        }
    }

    /** Fail a revived/in-flight native-debrid transfer whose capability URL belongs to another owner epoch. */
    fun handleDebridOwnerChanged(id: String, generation: String) {
        synchronized(lock) {
            handleDebridOwnerChangedLocked(id, generation)
        }
    }

    private fun handleDebridOwnerChangedLocked(id: String, generation: String) {
        releaseSlotReservation(id, generation)
        DownloadStore.updateIf(
            id = id,
            predicate = { it.transferGeneration == generation },
        ) {
            it.copy(
                state = DownloadState.FAILED,
                transferGeneration = null,
                errorText = OWNER_CHANGED_ERROR,
            )
        }
        afterSlotFreed()
    }

    fun isDebridOwnerCurrent(record: DownloadRecord): Boolean {
        val identity = record.debridOwnerIdentity
        val generation = record.debridOwnerGeneration
        if (identity == null && generation == null) return true
        if (identity == null || generation == null) return false
        return debridKeys?.isCurrent(identity, generation) == true
    }

    private fun currentDebridOwner(): DownloadDebridOwnerPolicy.Owner? {
        val token = debridKeys?.ownerToken() ?: return null
        return DownloadDebridOwnerPolicy.Owner(token.identity, token.generation)
    }

    fun ownsTransfer(id: String, generation: String): Boolean =
        synchronized(lock) { ownsTransferLocked(DownloadStore.record(id), generation) }

    /**
     * Couple a partial-file mutation to the same generation lock as pause/resume. This closes the small window where
     * an old worker could pass an ownership check, get paused, then truncate or append to the new generation's file.
     */
    fun performTransferFileMutation(id: String, generation: String, mutate: () -> Unit): Boolean {
        synchronized(lock) {
            if (!ownsTransferLocked(DownloadStore.record(id), generation)) return false
            mutate()
            return true
        }
    }

    /**
     * Publish transfer progress only while both the record and active slot still belong to this generation. The
     * mutation cannot change lifecycle ownership fields.
     */
    fun handleTransferProgress(
        id: String,
        generation: String,
        persistIndex: Boolean = true,
        mutate: (DownloadRecord) -> DownloadRecord,
    ): DownloadRecord? {
        synchronized(lock) {
            val record = DownloadStore.record(id)
            if (!ownsTransferLocked(record, generation)) return null
            return DownloadStore.updateIf(
                id = id,
                persistIndex = persistIndex,
                predicate = {
                    it.state == DownloadState.DOWNLOADING &&
                        it.transferGeneration == generation
                },
            ) { live ->
                mutate(live).copy(
                    state = live.state,
                    transferGeneration = live.transferGeneration,
                )
            }
        }
    }

    /**
     * Finalize and publish completion as one locked state transition. If pause/cancel/failure won first, the callback
     * is not run and that resting state is preserved.
     */
    fun handleTransferComplete(
        id: String,
        generation: String,
        completedBytes: Long,
        finalize: () -> Unit,
    ): Boolean {
        synchronized(lock) {
            val current = DownloadStore.record(id)
            if (current != null && !isDebridOwnerCurrent(current)) {
                releaseActive(id, generation)
                DownloadStore.updateIf(
                    id = id,
                    predicate = { it.transferGeneration == generation },
                ) {
                    it.copy(
                        state = DownloadState.FAILED,
                        transferGeneration = null,
                        errorText = OWNER_CHANGED_ERROR,
                    )
                }
                afterSlotFreed()
                return false
            }
            val completedState = current?.let {
                DownloadTransferStatePolicy.complete(
                    state = it.state,
                    recordGeneration = it.transferGeneration,
                    activeGeneration = activeGenerations[id],
                    requestedGeneration = generation,
                    onAuthorized = finalize,
                )
            }
            if (current == null || completedState == null) return false

            releaseActive(id, generation)
            DownloadStore.updateIf(
                id = id,
                predicate = { it.transferGeneration == generation },
            ) {
                it.copy(
                    state = completedState,
                    transferGeneration = null,
                    bytesDone = completedBytes,
                    bytesTotal = completedBytes,
                    errorText = null,
                )
            }
            afterSlotFreed()
            return true
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
    fun handleTransferStopped(id: String, generation: String) {
        synchronized(lock) {
            val current = DownloadStore.record(id)
            if (!ownsTransferLocked(current, generation)) return
            releaseActive(id, generation)
            DownloadStore.updateIf(
                id = id,
                predicate = {
                    it.state == DownloadState.DOWNLOADING &&
                        it.transferGeneration == generation
                },
            ) { it.copy(state = DownloadState.PAUSED, transferGeneration = null) }
            afterSlotFreed()
        }
    }

    /**
     * The transfer failed. This is the Android face of Apple's `-3000` (`NSURLErrorCannotCreateFile`) branch -- the
     * #132 root cause -- and it keeps that branch's three cases and their ORDER, because the ordering is what makes
     * the lesson hold:
     *
     *  1. **Could not write while the user is LOCKED** -> PARK, do not consume a WorkManager attempt. Restarting now
     *     would just re-download gigabytes and fail again while still locked (Apple's "retry cap exhausted before the
     *     device unlocks" trap). The record parks [DownloadState.PAUSED] and auto-resumes on unlock via
     *     [DownloadUnlockReceiver], so a completed-while-locked download recovers itself instead of dead-ending.
     *  2. **Genuine out-of-space** -> HARD FAIL, always, and BEFORE any parking. Parking an ENOSPC would re-download
     *     gigabytes on every unlock and never succeed. The user has to free space, so say so.
     *  3. **Any other write failure, user unlocked** -> self-heal restart ONCE, then park (not dead-fail) if it
     *     recurs. A write failure is transient far more often than terminal, and dead-failing a 100%-downloaded title
     *     is exactly the #132 complaint.
     *
     * Transient network failures get a bounded WorkManager retry and resume from the partial file. Permanent HTTP
     * errors, dead links after the retry ceiling, and non-media bodies fail honestly with their own message.
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
    fun handleTransferFailure(
        id: String,
        generation: String,
        cause: Throwable,
        runAttemptCount: Int,
    ): FailureVerdict {
        synchronized(lock) {
            val detail = failureDetail(cause)
            val current = DownloadStore.record(id) ?: return FailureVerdict.IGNORED
            if (!ownsTransferLocked(current, generation)) return FailureVerdict.IGNORED
            if (!DownloadTransferPolicy.mayRetryRecord(current.state)) {
                // pause/cancel can win while a socket failure is being delivered. Never turn that resting state back
                // into DOWNLOADING or ask WorkManager to retry work the user explicitly stopped.
                return FailureVerdict.TERMINAL
            }

            // (2) FIRST: genuine out-of-space is terminal wherever it appears. Checked ahead of the locked branch so
            // that a full volume before first unlock still fails honestly instead of park-looping forever.
            if (isOutOfSpace(cause)) {
                Log.w(TAG, "out of space id=$id detail=$detail")
                releaseActive(id, generation)
                DownloadStore.updateIf(
                    id = id,
                    predicate = { it.transferGeneration == generation },
                ) {
                    it.copy(
                        state = DownloadState.FAILED,
                        transferGeneration = null,
                        errorText = "Not enough storage to save this download. Free up space and try again.",
                    )
                }
                afterSlotFreed()
                return FailureVerdict.TERMINAL
            }

            if (isWriteFailure(cause)) {
                // (1) Could not write while locked: park for unlock, do NOT consume another WorkManager attempt.
                if (!isUserUnlocked()) {
                    Log.w(TAG, "write failed while locked, parked for unlock retry id=$id detail=$detail")
                    releaseActive(id, generation)
                    parkForUnlock(
                        id,
                        generation,
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
                // rather than re-downloading gigabytes. The persisted WorkManager attempt count grants it once.
                if (DownloadTransferPolicy.canRetryWrite(runAttemptCount)) {
                    Log.w(TAG, "write failure retry id=$id attempt=1 detail=$detail")
                    // Keep the slot: the SAME work retries, so releasing it here would let a queued download start
                    // alongside and momentarily exceed the cap.
                    DownloadStore.updateIf(
                        id = id,
                        predicate = { it.transferGeneration == generation },
                    ) {
                        it.copy(state = DownloadState.DOWNLOADING, errorText = null)
                    }
                    return FailureVerdict.RETRY
                }
                // (3b) The one retry ALSO failed. Do NOT dead-fail (the #132 behaviour that stranded a
                // 100%-downloaded title at "couldn't save"). Park it: it auto-retries on the next unlock / app
                // foreground. A later user resume creates a fresh generation and WorkRequest, so that explicit cycle
                // gets one new retry without process death regranting retries to this generation.
                Log.w(TAG, "write failure persisted after retry, parked id=$id detail=$detail")
                releaseActive(id, generation)
                parkForUnlock(
                    id,
                    generation,
                    "Waiting to finish saving. It will retry automatically when you unlock your device or reopen the app.",
                )
                afterSlotFreed()
                return FailureVerdict.TERMINAL
            }

            if (DownloadTransferPolicy.shouldRetry(cause, runAttemptCount)) {
                Log.w(
                    TAG,
                    "transient transfer retry id=$id attempt=${runAttemptCount + 1} detail=$detail",
                )
                // Keep the slot: WorkManager retries this same work. Its .part resumes only with a matching ETag.
                DownloadStore.updateIf(
                    id = id,
                    predicate = { it.transferGeneration == generation },
                ) {
                    it.copy(state = DownloadState.DOWNLOADING, errorText = null)
                }
                return FailureVerdict.RETRY
            }

            Log.w(TAG, "transfer FAILED id=$id detail=$detail")
            releaseActive(id, generation)
            DownloadStore.updateIf(
                id = id,
                predicate = { it.transferGeneration == generation },
            ) {
                it.copy(
                    state = DownloadState.FAILED,
                    transferGeneration = null,
                    errorText = "Couldn't save this download: $detail",
                )
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

        /** A superseded generation reported late; finish its WorkManager row without touching current state. */
        IGNORED,
    }

    /** Park a record for unlock-triggered auto-resume; resume creates a fresh generation and attempt budget. */
    private fun parkForUnlock(id: String, generation: String, message: String) {
        if (
            DownloadStore.updateIf(
                id = id,
                predicate = { it.transferGeneration == generation },
            ) {
                it.copy(
                    state = DownloadState.PAUSED,
                    transferGeneration = null,
                    errorText = message,
                )
            } == null
        ) {
            return
        }
        awaitingUnlock.add(id)
        persistAwaitingUnlock()
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
        val inFlight = synchronized(lock) {
            DownloadStore.records.value.filter {
                it.state == DownloadState.DOWNLOADING &&
                    (
                        it.transferGeneration == null ||
                            pendingEnqueueGenerations[it.id] != it.transferGeneration
                    )
            }
        }
        if (inFlight.isEmpty()) return
        val wm = WorkManager.getInstance(context)
        for (record in inFlight) {
            val generation = record.transferGeneration
            val work = runCatching {
                wm.getWorkInfosForUniqueWork(workName(record.id)).get()
                    .map {
                        DownloadWorkSnapshot(
                            id = it.id.toString(),
                            generation = DownloadWorker.generationFromTags(it.tags),
                            isFinished = it.state.isFinished,
                        )
                    }
            }.getOrNull() ?: continue // a query failure must not demote or release a reserved slot
            if (
                generation != null &&
                DownloadReconciliationPolicy.hasLiveGeneration(generation, work)
            ) {
                synchronized(lock) {
                    val current = DownloadStore.record(record.id)
                    if (
                        current?.state == DownloadState.DOWNLOADING &&
                        current.transferGeneration == generation
                    ) {
                        activeGenerations[record.id] = generation
                    }
                }
                continue
            }
            val exactWorkIds = DownloadReconciliationPolicy.cancellableWorkIds(generation, work)
            val demoted = synchronized(lock) {
                val current = DownloadStore.record(record.id)
                if (pendingEnqueueGenerations[record.id] == generation) {
                    return@synchronized false
                }
                if (
                    current?.state != DownloadState.DOWNLOADING ||
                    current.transferGeneration != generation
                ) {
                    return@synchronized false
                }
                releaseSlotReservation(record.id, generation)
                DownloadStore.updateIf(
                    id = record.id,
                    predicate = {
                        it.state == DownloadState.DOWNLOADING &&
                            it.transferGeneration == generation
                    },
                ) {
                    it.copy(state = DownloadState.PAUSED, transferGeneration = null)
                } != null
            }
            if (demoted) {
                exactWorkIds.forEach { workId ->
                    wm.cancelWorkById(UUID.fromString(workId))
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

internal object DownloadDebridOwnerPolicy {
    data class Owner(val identity: String, val generation: Long)

    /**
     * Missing fields are a compatible pre-owner-schema record. A partially written owner is invalid; a complete
     * owner must match both opaque scope and mutation generation.
     */
    fun isCurrent(
        expectedIdentity: String?,
        expectedGeneration: Long?,
        current: Owner?,
    ): Boolean {
        if (expectedIdentity == null && expectedGeneration == null) return true
        if (expectedIdentity == null || expectedGeneration == null) return false
        return current?.identity == expectedIdentity && current.generation == expectedGeneration
    }
}

internal sealed interface DownloadTransferClaimDecision {
    data class Claimed(val state: DownloadState) : DownloadTransferClaimDecision
    data object OwnerChanged : DownloadTransferClaimDecision
    data object Rejected : DownloadTransferClaimDecision
}

/**
 * Evaluate ownership as part of the claim decision, after the manager reloads the durable row under its lifecycle
 * lock. A successful worker precheck therefore cannot authorize a later claim after the account has changed.
 */
internal object DownloadTransferClaimPolicy {
    fun decide(
        record: DownloadRecord,
        requestedGeneration: String,
        isOwnerCurrent: (DownloadRecord) -> Boolean,
    ): DownloadTransferClaimDecision {
        val state = DownloadTransferStatePolicy.claim(
            state = record.state,
            recordGeneration = record.transferGeneration,
            requestedGeneration = requestedGeneration,
        ) ?: return DownloadTransferClaimDecision.Rejected
        if (!isOwnerCurrent(record)) return DownloadTransferClaimDecision.OwnerChanged
        return DownloadTransferClaimDecision.Claimed(state)
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
