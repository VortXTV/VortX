package com.vortx.android.downloads

import android.content.Context
import android.text.format.Formatter
import android.util.AtomicFile
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI

/**
 * Device-local persistence for offline downloads. Android port of Apple `app/SourcesShared/DownloadStore.swift`.
 *
 * The index is a JSON file at `filesDir/Downloads/index.json`; the media files sit alongside it at
 * `filesDir/Downloads/<id>.<ext>`. `filesDir` is the Android analogue of Apple's `Application Support`: app-private
 * internal storage, no permission needed, removed with the app.
 *
 * This store is intentionally NOT synced (no VortX-account / E2E write): a download is a physical file on one
 * device, and syncing the LIST to a device that lacks the file is misleading. It also NEVER touches `libraryItem`
 * documents -- a download is a local file plus this local index, nothing more.
 *
 * TIMESTAMP NOTE (a deliberate divergence, safe only because of the no-sync rule above): [DownloadRecord.addedAt]
 * is epoch MILLIS here, while Apple's `index.json` writes `addedAt` as an ISO8601 string. That is not a
 * cross-platform bug of the kind the profile roster hit (`profiles.modified` in millis on Android vs seconds on
 * Apple) because this index is never read by another platform -- it is a device-local file that only ever this
 * app writes and reads. If a future round ever syncs the download list, the wire format has to be reconciled
 * FIRST; do not assume this field is portable as-is.
 *
 * Apple's store is `@MainActor`-isolated and every mutation hops to the main actor. Android has no such ambient
 * isolation and the [DownloadWorker] writes progress from a WorkManager background thread, so the record list is
 * guarded by [hydrationGate] instead and published through a [StateFlow] for Compose. The lock is held only for
 * in-memory list math plus the index read/write, never across a network or media transfer.
 */
object DownloadStore {

    private val hydrationGate = OneTimeHydrationGate()
    private const val RECLAIM_TOMBSTONE_SUFFIX = ".reclaiming"
    private val managedMediaFilename = Regex(
        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(mp4|mkv|avi|mov|m4v|webm|ts|flv|wmv)$",
    )

    /** Newest-first, matching Apple's `records` ordering, for direct consumption by the downloads list. */
    private val _records = MutableStateFlow<List<DownloadRecord>>(emptyList())
    val records: StateFlow<List<DownloadRecord>> = _records.asStateFlow()

    @Volatile
    private var appContext: Context? = null

    /** Hydrate exactly once per process, under the same lock used by every live mutation. */
    fun init(context: Context) {
        hydrationGate.hydrate {
            appContext = context.applicationContext
            ensureDownloadsDirectoryExists()
            // Only a fully decoded index proves which tombstones belong to committed removals. Missing and corrupt
            // indexes preserve every reclaim artifact for manual/forensic recovery instead of guessing it is safe.
            if (loadLocked() is DownloadIndexHydration.Receipt.Loaded) recoverReclaimArtifactsLocked()
        }
    }

    // MARK: Locations

    /**
     * `filesDir/Downloads`, created on demand. Apple additionally marks this directory excluded-from-iCloud-backup
     * (downloaded media is large and re-downloadable). The Android analogue is declarative, not an API call: the
     * `files/Downloads` exclusions in `res/xml/backup_rules.xml` + `res/xml/data_extraction_rules.xml`, wired from
     * `AndroidManifest.xml`, keep this directory out of Auto Backup and device-transfer alike.
     */
    fun downloadsDirectory(): File {
        val context = requireNotNull(appContext) { "DownloadStore.init(context) must run before any file access" }
        return DownloadDirectoryPolicy.trustedDownloadsDirectory(context.filesDir)
    }

    private fun indexFile(): File = File(downloadsDirectory(), "index.json")

    /**
     * Absolute file for a record's media, rebuilt from the CURRENT `filesDir` so a relocated app data dir never
     * strands a stored absolute path (the reason Apple persists only the filename stem, not a path).
     */
    fun fileFor(record: DownloadRecord): File = File(downloadsDirectory(), record.localFilename)

    /**
     * The in-progress file a transfer appends to, renamed onto [fileFor] only once the transfer completes.
     *
     * Apple gets this separation for free: URLSession writes to a system-managed temp and hands it over at
     * `didFinishDownloadingTo`, so `<id>.<ext>` never exists in a partial state. Android's worker owns the write, so
     * without a distinct `.part` name a half-downloaded file would sit at the record's real path and read as playable
     * media to anything that checks [fileExists] alone. The rename is within one directory, so it is atomic and
     * costs no copy of a multi-GB file.
     */
    fun partFileFor(record: DownloadRecord): File = File(downloadsDirectory(), "${record.localFilename}.part")

    /**
     * Create the Downloads directory. THROWS on a real failure so the worker can surface a directory-creation
     * fault at the write step instead of a later opaque error, mirroring Apple's
     * `ensureDownloadsDirectoryExists()`.
     *
     * Apple additionally downgrades the directory's file-protection class to
     * `completeUntilFirstUserAuthentication` here, so a transfer that COMPLETES while the device is LOCKED can
     * still create its file (the #132 root cause). Android has NO equivalent call: app-private storage is
     * credential-encrypted (CE), which is already exactly "readable/writable after the first unlock since boot"
     * -- i.e. Android's DEFAULT is what Apple has to opt into. The residual locked-write window that remains on
     * Android (before first unlock, or a locked work profile) is handled by the park-for-unlock path in
     * [DownloadManager], not by a protection-class change here. See [DownloadManager.parkForUnlock].
     */
    fun ensureDownloadsDirectoryExists() {
        val dir = downloadsDirectory()
        if (!dir.exists() && !dir.mkdirs() && !dir.isDirectory) {
            throw java.io.IOException("Could not create Downloads directory at ${dir.absolutePath}")
        }
        // Re-check after mkdir: canonical validation must guard the root itself, not just filenames below it.
        if (!dir.isDirectory || dir.canonicalFile != dir) {
            throw java.io.IOException("Downloads directory is redirected outside app files storage")
        }
    }

    /**
     * True when the media file for a completed record actually exists on disk (guards play-from-local against a
     * row whose file was purged out from under us -- Android reclaims app storage under pressure much as tvOS does).
     */
    fun fileExists(record: DownloadRecord): Boolean = fileFor(record).isFile

    // MARK: Persistence

    private fun loadLocked(): DownloadIndexHydration.Receipt<List<DownloadRecord>> {
        val file = indexFile()
        return DownloadIndexHydration.readAtomically(
            indexFile = file,
            openRead = { AtomicFile(file).openRead() },
        ) { index ->
            val array = JSONArray(index)
            (0 until array.length()).mapNotNull { i -> recordFromJson(array.optJSONObject(i) ?: return@mapNotNull null) }
        }.also { receipt ->
            if (receipt is DownloadIndexHydration.Receipt.Loaded) {
                _records.value = receipt.value.sortedByDescending { it.addedAt }
            }
        }
    }

    /**
     * Encode + durably replace the index through [AtomicFile]. Its write path retains the prior file until the new
     * bytes are flushed (`fd.sync`) and finalized, so a process death cannot turn a media tombstone into a claimed
     * committed deletion merely because a direct index overwrite was torn.
     */
    private fun persistLocked(): Boolean {
        val array = JSONArray()
        _records.value.forEach { array.put(recordToJson(it)) }
        return runCatching {
            ensureDownloadsDirectoryExists()
            val atomic = AtomicFile(indexFile())
            val output = atomic.startWrite()
            try {
                output.write(array.toString().toByteArray(Charsets.UTF_8))
                output.fd.sync()
                atomic.finishWrite(output)
                true
            } catch (failure: Throwable) {
                atomic.failWrite(output)
                false
            }
        }.getOrDefault(false)
    }

    // MARK: CRUD

    fun record(id: String): DownloadRecord? = _records.value.firstOrNull { it.id == id }

    /**
     * True when a completed (or in-flight) download already exists for this exact video -- drives the
     * "Downloaded" / "Downloading" state on a source row so a user can't queue a title twice.
     */
    fun hasDownload(videoId: String): Boolean =
        _records.value.any { it.videoId == videoId && it.state != DownloadState.FAILED }

    fun upsert(record: DownloadRecord) {
        hydrationGate.withLock {
            val current = _records.value
            val index = current.indexOfFirst { it.id == record.id }
            _records.value = if (index >= 0) {
                current.toMutableList().also { it[index] = record }
            } else {
                listOf(record) + current
            }
            persistLocked()
        }
    }

    /**
     * Mutate a record in place (progress / state transitions) and persist. No-op if the id is gone (e.g. the user
     * deleted the row while a late worker callback arrived).
     *
     * `persistIndex = false` is for high-frequency PROGRESS ticks: they only need the published records for the
     * UI, and re-encoding + rewriting the JSON index on every tick would be a disk write several times per
     * second. State transitions keep the default and persist.
     */
    fun update(id: String, persistIndex: Boolean = true, mutate: (DownloadRecord) -> DownloadRecord) {
        updateIf(id, persistIndex, predicate = { true }, mutate = mutate)
    }

    /**
     * Atomically mutate only when the current row still satisfies [predicate]. Returns the published row, or null
     * when the id disappeared or its ownership changed before this callback arrived.
     */
    internal fun updateIf(
        id: String,
        persistIndex: Boolean = true,
        predicate: (DownloadRecord) -> Boolean,
        mutate: (DownloadRecord) -> DownloadRecord,
    ): DownloadRecord? = hydrationGate.withLock {
        val current = _records.value
        val index = current.indexOfFirst { it.id == id }
        if (index < 0 || !predicate(current[index])) return@withLock null
        val updated = mutate(current[index])
        _records.value = current.toMutableList().also { it[index] = updated }
        if (persistIndex) persistLocked()
        updated
    }

    /**
     * Remove a record AND its bounded on-disk artifacts. The caller ([DownloadManager]) cancels any live transfer
     * first. The file move and index commit use the same tombstone protocol as watched reclaim, so an index-write
     * failure cannot leave an in-memory or rebooted row pointing at a permanently deleted file.
     */
    fun remove(id: String) {
        hydrationGate.withLock {
            val current = _records.value
            val record = current.firstOrNull { it.id == id } ?: return@withLock
            removeRecordLocked(current, record)
        }
    }

    /** Safe, completed-only transaction used by the opt-in watched-download path. */
    internal fun removeCompletedForWatchedReclaim(record: DownloadRecord): WatchedDownloadReclaimResult =
        hydrationGate.withLock {
            val current = _records.value
            val live = current.firstOrNull { it.id == record.id && it.state == DownloadState.COMPLETED }
                ?: return@withLock WatchedDownloadReclaimResult.NO_MATCHING_COMPLETED_DOWNLOAD
            // The policy selected [record] from an earlier snapshot. Recheck the entire immutable row before
            // moving bytes: a late event may share an id yet no longer name the same file/media after a lifecycle
            // transition, and must become a harmless no-op.
            if (!DownloadWatchedReclaimPolicy.matchesCapturedCompletedRecord(record, live)) {
                return@withLock WatchedDownloadReclaimResult.NO_MATCHING_COMPLETED_DOWNLOAD
            }
            when (removeRecordLocked(current, live)) {
                DownloadReclaimTransaction.Result.RECLAIMED -> WatchedDownloadReclaimResult.RECLAIMED
                DownloadReclaimTransaction.Result.FILE_RENAME_FAILED -> WatchedDownloadReclaimResult.FILE_RENAME_FAILED
                DownloadReclaimTransaction.Result.INDEX_WRITE_FAILED_ROLLED_BACK ->
                    WatchedDownloadReclaimResult.INDEX_WRITE_FAILED_ROLLED_BACK
                DownloadReclaimTransaction.Result.INDEX_WRITE_FAILED_RECOVERY_REQUIRED ->
                    WatchedDownloadReclaimResult.INDEX_WRITE_FAILED_RECOVERY_REQUIRED
            }
        }

    /** The selector must compare against an exact managed path, never a path from the JSON index unchecked. */
    internal fun matchesManagedFileUri(record: DownloadRecord, rawUri: String): Boolean {
        val media = managedFilesFor(record)?.media ?: return false
        return runCatching {
            val uri = URI(rawUri)
            uri.scheme.equals("file", ignoreCase = true) && File(uri).canonicalFile == media.canonicalFile
        }.getOrDefault(false)
    }

    private fun removeRecordLocked(
        current: List<DownloadRecord>,
        record: DownloadRecord,
    ): DownloadReclaimTransaction.Result {
        val files = managedFilesFor(record) ?: return DownloadReclaimTransaction.Result.FILE_RENAME_FAILED
        val remaining = current.filterNot { it.id == record.id }
        return DownloadReclaimTransaction().reclaim(
            mediaFile = files.media,
            tombstoneFile = files.tombstone,
            stalePartFile = files.part,
        ) {
            _records.value = remaining
            if (persistLocked()) {
                true
            } else {
                _records.value = current
                false
            }
        }
    }

    private data class ManagedFiles(val media: File, val part: File, val tombstone: File)

    /**
     * Validate every filename before deletion/rename. A corrupted or hostile index can still render a row, but it
     * can never make this store touch a path outside its private Downloads directory.
     */
    private fun managedFilesFor(record: DownloadRecord): ManagedFiles? = runCatching {
        val filename = record.localFilename
        if (!managedMediaFilename.matches(filename) || !filename.startsWith("${record.id}.")) return@runCatching null
        val directory = downloadsDirectory().canonicalFile
        val media = File(directory, filename).canonicalFile
        if (media.parentFile != directory || media.name != filename) return@runCatching null
        ManagedFiles(
            media = media,
            part = File(directory, "$filename.part").canonicalFile,
            tombstone = File(directory, "$filename$RECLAIM_TOMBSTONE_SUFFIX").canonicalFile,
        ).takeIf { files ->
            files.part.parentFile == directory && files.tombstone.parentFile == directory
        }
    }.getOrNull()

    /**
     * Complete an interrupted reclaim before publishing records. A tombstone with a live row is restored (or removed
     * when the original already exists); a tombstone without a row is the post-index-commit residue and is deleted.
     * Orphan parts are only removed when their exact UUID/media filename belongs to this managed directory.
     */
    private fun recoverReclaimArtifactsLocked() {
        val directory = downloadsDirectory().canonicalFile
        val recordsByFilename = _records.value.associateBy { it.localFilename }
        directory.listFiles().orEmpty().forEach { file ->
            val name = file.name
            // A valid-looking filename can still be a symlink. Canonical validation prevents recovery cleanup from
            // traversing it to an arbitrary target outside the managed owner directory.
            val canonicalArtifact = runCatching { file.canonicalFile }.getOrNull() ?: return@forEach
            if (canonicalArtifact.parentFile != directory || canonicalArtifact.name != name) return@forEach
            when {
                name.endsWith(RECLAIM_TOMBSTONE_SUFFIX) -> {
                    val mediaName = name.removeSuffix(RECLAIM_TOMBSTONE_SUFFIX)
                    if (!managedMediaFilename.matches(mediaName)) return@forEach
                    val record = recordsByFilename[mediaName]
                    val media = runCatching { File(directory, mediaName).canonicalFile }.getOrNull() ?: return@forEach
                    if (media.parentFile != directory || media.name != mediaName) return@forEach
                    DownloadReclaimTransaction().recoverTombstone(
                        mediaFile = media,
                        tombstoneFile = canonicalArtifact,
                        indexStillHasRecord = record != null,
                    )
                }
                name.endsWith(".part") -> {
                    val mediaName = name.removeSuffix(".part")
                    if (!managedMediaFilename.matches(mediaName)) return@forEach
                    val record = recordsByFilename[mediaName]
                    if (record == null || record.state == DownloadState.COMPLETED) runCatching { canonicalArtifact.delete() }
                }
            }
        }
    }

    // MARK: Storage usage

    /**
     * Total bytes of downloads currently on disk (sums ACTUAL file sizes, not the recorded totals, so a
     * partially-deleted file reports honestly).
     *
     * Counts the `.part` of an in-flight transfer too: those bytes genuinely occupy the volume, and a storage figure
     * that ignored them would under-report exactly while a multi-GB download is filling the disk. (On Apple the
     * in-flight bytes live in a system temp outside the Downloads dir, so its equivalent sum sees 0 for them.)
     */
    fun totalBytesOnDisk(): Long = _records.value.sumOf { record ->
        runCatching {
            val done = fileFor(record).takeIf { it.isFile }?.length() ?: 0L
            val partial = partFileFor(record).takeIf { it.isFile }?.length() ?: 0L
            done + partial
        }.getOrDefault(0L)
    }

    /** Human-readable total storage used, e.g. "3.4 GB". Apple: `ByteCountFormatter` with `.file` count style. */
    fun formattedTotalSize(): String = formatBytes(totalBytesOnDisk())

    /**
     * Recorded byte total for a subset of records (the larger of done/total per record). Reads the INDEX, not the
     * filesystem, so it is cheap enough to call while rendering a grouped list. Feeds the per-show folder header.
     */
    fun recordedSize(records: List<DownloadRecord>): String =
        formatBytes(DownloadQueuePolicy.recordedSizeBytes(records))

    fun formatBytes(bytes: Long): String {
        val context = appContext ?: return "$bytes B"
        return Formatter.formatFileSize(context, bytes)
    }

    // MARK: Grouping (per-show download folders)

    /**
     * The device's downloads as per-show FOLDERS (one group per series) plus standalone movies, derived on demand
     * from the flat [records] index. A pure DERIVATION: it adds no persisted state and does NOT change the on-disk
     * layout (files stay flat under the Downloads dir), so the rebuild-from-current-dir path keeps working
     * unchanged, and nothing here touches a `libraryItem` document.
     *
     * GROUP ORDER is newest-activity-first, matching the flat list ([records] is already `addedAt`-desc, so the
     * first record of each key marks the group's newest activity). WITHIN a show folder the episodes are sorted by
     * SEASON then EPISODE ascending, regardless of download order, with any episode missing a season/episode number
     * sinking to the end (tie-broken oldest-first) so the folder always reads S1E1, S1E2, S2E1... A movie (or a
     * series record carrying no season/episode) forms its own single-item group and renders as a plain row.
     */
    fun groupedDownloads(): List<DownloadGroup> {
        val order = mutableListOf<String>()
        val byKey = LinkedHashMap<String, MutableList<DownloadRecord>>()
        for (record in _records.value) {
            val key = groupKey(record)
            if (byKey[key] == null) {
                order.add(key)
                byKey[key] = mutableListOf()
            }
            byKey.getValue(key).add(record)
        }
        return order.mapNotNull { key ->
            val items = byKey[key] ?: return@mapNotNull null
            val head = items.firstOrNull() ?: return@mapNotNull null
            val sorted = if (head.type == "series") items.sortedWith(episodeOrder) else items
            DownloadGroup(id = key, title = head.name, poster = head.poster, type = head.type, records = sorted)
        }
    }

    /**
     * Grouping key: a series collects ALL its episodes under the series id ([DownloadRecord.contentId]), so every
     * downloaded episode of the same show lands in one folder; a movie stands alone under its own
     * [DownloadRecord.videoId] (for a movie `contentId == videoId`, so this is unique per movie). The `series:` /
     * `movie:` prefixes keep the two namespaces from ever colliding on an id that happens to match.
     */
    private fun groupKey(record: DownloadRecord): String =
        if (record.type == "series") "series:${record.contentId}" else "movie:${record.videoId}"

    /**
     * Season-then-episode ascending; an unknown season or episode sorts last (so a stray untagged episode never
     * jumps ahead of S1E1), tie-broken oldest-added-first for a stable order.
     */
    private val episodeOrder = Comparator<DownloadRecord> { a, b ->
        val seasonA = a.season ?: Int.MAX_VALUE
        val seasonB = b.season ?: Int.MAX_VALUE
        if (seasonA != seasonB) return@Comparator seasonA.compareTo(seasonB)
        val episodeA = a.episode ?: Int.MAX_VALUE
        val episodeB = b.episode ?: Int.MAX_VALUE
        if (episodeA != episodeB) return@Comparator episodeA.compareTo(episodeB)
        a.addedAt.compareTo(b.addedAt)
    }

    // MARK: JSON

    internal fun recordToJson(record: DownloadRecord): JSONObject = JSONObject().apply {
        put("id", record.id)
        put("contentId", record.contentId)
        put("videoId", record.videoId)
        put("type", record.type)
        put("name", record.name)
        record.poster?.let { put("poster", it) }
        record.season?.let { put("season", it) }
        record.episode?.let { put("episode", it) }
        record.sourceName?.let { put("sourceName", it) }
        record.qualityText?.let { put("qualityText", it) }
        record.isDolbyVision?.let { put("isDolbyVision", it) }
        record.isAtmos?.let { put("isAtmos", it) }
        put("isTorrent", record.isTorrent)
        record.headers?.takeIf { it.isNotEmpty() }?.let { headers ->
            put("headers", JSONObject().apply { headers.forEach { (k, v) -> put(k, v) } })
        }
        put("remoteURL", record.remoteURL)
        record.debridOwnerIdentity?.let { put("debridOwnerIdentity", it) }
        record.debridOwnerGeneration?.let { put("debridOwnerGeneration", it) }
        put("localFilename", record.localFilename)
        put("bytesTotal", record.bytesTotal)
        put("bytesDone", record.bytesDone)
        put("state", record.state.wireValue)
        record.transferGeneration?.let { put("transferGeneration", it) }
        record.representationETag?.let { put("representationETag", it) }
        put("addedAt", record.addedAt)
        record.errorText?.let { put("errorText", it) }
        record.retryNote?.let { put("retryNote", it) }
        record.taskIdentifier?.let { put("taskIdentifier", it) }
    }

    internal fun recordFromJson(json: JSONObject): DownloadRecord? {
        val id = json.optString("id").takeIf { it.isNotEmpty() } ?: return null
        val headers = json.optJSONObject("headers")?.let { obj ->
            obj.keys().asSequence().associateWith { obj.optString(it) }
        }
        return DownloadRecord(
            id = id,
            contentId = json.optString("contentId"),
            videoId = json.optString("videoId"),
            type = json.optString("type"),
            name = json.optString("name"),
            poster = json.optStringOrNull("poster"),
            season = if (json.has("season")) json.optInt("season") else null,
            episode = if (json.has("episode")) json.optInt("episode") else null,
            sourceName = json.optStringOrNull("sourceName"),
            qualityText = json.optStringOrNull("qualityText"),
            // Old index rows contain only display quality such as "4K", not codec capabilities.
            // Absence is therefore unknown and must be established from the completed local file.
            isDolbyVision = json.optBooleanOrNull("isDolbyVision"),
            isAtmos = json.optBooleanOrNull("isAtmos"),
            isTorrent = json.optBoolean("isTorrent", false),
            headers = headers,
            remoteURL = json.optString("remoteURL"),
            debridOwnerIdentity = json.optStringOrNull("debridOwnerIdentity"),
            debridOwnerGeneration = if (json.has("debridOwnerGeneration")) {
                json.optLong("debridOwnerGeneration")
            } else {
                null
            },
            localFilename = json.optString("localFilename"),
            bytesTotal = json.optLong("bytesTotal", 0L),
            bytesDone = json.optLong("bytesDone", 0L),
            state = DownloadState.fromWire(json.optString("state")),
            transferGeneration = json.optStringOrNull("transferGeneration"),
            representationETag = json.optStringOrNull("representationETag"),
            // Read as LONG, never optInt: this is epoch millis and exceeds 2^31, which an Int read would
            // truncate (the same trap the sync engine documents for its document `version`). A truncated
            // addedAt would silently scramble the newest-first ordering + the episode tie-break.
            addedAt = json.optLong("addedAt", System.currentTimeMillis()),
            errorText = json.optStringOrNull("errorText"),
            retryNote = json.optStringOrNull("retryNote"),
            taskIdentifier = if (json.has("taskIdentifier")) json.optInt("taskIdentifier") else null,
        )
    }

    /** `optString` returns "" for an absent key, which would turn a null poster/error into an empty string. */
    private fun JSONObject.optStringOrNull(key: String): String? =
        if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotEmpty() } else null

    private fun JSONObject.optBooleanOrNull(key: String): Boolean? =
        if (has(key) && !isNull(key)) optBoolean(key) else null
}

/**
 * One-shot hydration barrier. The load-and-publish block and every later mutation share this lock, so a delayed disk
 * read must publish before a live mutation and can never run again to resurrect stale state.
 */
internal class OneTimeHydrationGate {
    private val lock = Any()
    private var hydrated = false

    fun hydrate(loadAndPublish: () -> Unit) {
        synchronized(lock) {
            if (hydrated) return
            loadAndPublish()
            hydrated = true
        }
    }

    fun <T> withLock(block: () -> T): T = synchronized(lock) {
        check(hydrated) { "DownloadStore must hydrate before mutation" }
        block()
    }
}

/**
 * A virtual "folder" of downloads for one show (all episodes of a series) or a single movie, derived from the flat
 * download index by [DownloadStore.groupedDownloads]. Purely a view model: it holds no state of its own. See
 * [DownloadStore.groupedDownloads] for the grouping + season/episode ordering rules.
 */
data class DownloadGroup(
    /** `series:<seriesId>` for a show folder, or `movie:<videoId>` for a standalone movie. */
    val id: String,
    /** The show title (or movie title). For a series every episode carries the series name. */
    val title: String,
    val poster: String?,
    /** "series" (a show folder) or "movie" (a standalone row). */
    val type: String,
    /** For a series, episodes sorted season-then-episode; for a movie, the one record. */
    val records: List<DownloadRecord>,
) {
    /** True for a show folder (a series). A movie group renders as a plain row instead of a folder. */
    val isShow: Boolean get() = type == "series"

    /** Number of downloads in the folder (episode count for a show). */
    val count: Int get() = records.size
}
