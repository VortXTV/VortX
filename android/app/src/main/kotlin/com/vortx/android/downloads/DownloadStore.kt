package com.vortx.android.downloads

import android.content.Context
import android.text.format.Formatter
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

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
 * guarded by [lock] instead and published through a [StateFlow] for Compose. The lock is held only for in-memory
 * list math plus the index write, never across a network or file transfer.
 */
object DownloadStore {

    private val lock = Any()

    /** Newest-first, matching Apple's `records` ordering, for direct consumption by the downloads list. */
    private val _records = MutableStateFlow<List<DownloadRecord>>(emptyList())
    val records: StateFlow<List<DownloadRecord>> = _records.asStateFlow()

    @Volatile
    private var appContext: Context? = null

    /**
     * Hydrate the index from disk. Idempotent (a second call re-reads, which is harmless), so
     * [com.vortx.android.VortXApplication] can call it at process start and the [DownloadWorker] can call it
     * defensively: WorkManager can run a worker in a process whose Application.onCreate already ran, but a
     * defensive init costs one cheap file read and rules out an un-hydrated store writing an empty index over
     * a good one.
     */
    fun init(context: Context) {
        appContext = context.applicationContext
        ensureDownloadsDirectoryExists()
        load()
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
        return File(context.filesDir, "Downloads")
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
    }

    /**
     * True when the media file for a completed record actually exists on disk (guards play-from-local against a
     * row whose file was purged out from under us -- Android reclaims app storage under pressure much as tvOS does).
     */
    fun fileExists(record: DownloadRecord): Boolean = fileFor(record).isFile

    // MARK: Persistence

    private fun load() {
        val file = indexFile()
        if (!file.isFile) return
        val decoded = runCatching {
            val array = JSONArray(file.readText())
            (0 until array.length()).mapNotNull { i -> recordFromJson(array.optJSONObject(i) ?: return@mapNotNull null) }
        }.getOrNull() ?: return
        synchronized(lock) { _records.value = decoded.sortedByDescending { it.addedAt } }
    }

    /** Encode + write the index atomically (write to a temp then rename), matching Apple's `.atomic` write. */
    private fun persistLocked() {
        val array = JSONArray()
        _records.value.forEach { array.put(recordToJson(it)) }
        runCatching {
            ensureDownloadsDirectoryExists()
            val target = indexFile()
            val temp = File(target.parentFile, "index.json.tmp")
            temp.writeText(array.toString())
            if (!temp.renameTo(target)) {
                // A rename inside one directory should not fail; fall back to a direct write rather than
                // silently leaving a stale index behind.
                target.writeText(array.toString())
                temp.delete()
            }
        }
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
        synchronized(lock) {
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
        synchronized(lock) {
            val current = _records.value
            val index = current.indexOfFirst { it.id == id }
            if (index < 0) return
            _records.value = current.toMutableList().also { it[index] = mutate(it[index]) }
            if (persistIndex) persistLocked()
        }
    }

    /**
     * Remove a record AND its on-disk files. The caller ([DownloadManager]) is responsible for cancelling any live
     * transfer first.
     *
     * BOTH the finished file and the [partFileFor] partial are unlinked: a cancelled in-flight download has only a
     * `.part`, and leaving it behind would leak the whole partial transfer (potentially gigabytes) with no record
     * left to ever reference or clean it up.
     */
    fun remove(id: String) {
        synchronized(lock) {
            val current = _records.value
            val record = current.firstOrNull { it.id == id } ?: return
            runCatching { fileFor(record).delete() }
            runCatching { partFileFor(record).delete() }
            _records.value = current.filterNot { it.id == id }
            persistLocked()
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
        formatBytes(records.sumOf { maxOf(it.bytesDone, it.bytesTotal) })

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

    private fun recordToJson(record: DownloadRecord): JSONObject = JSONObject().apply {
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
        put("isTorrent", record.isTorrent)
        record.headers?.takeIf { it.isNotEmpty() }?.let { headers ->
            put("headers", JSONObject().apply { headers.forEach { (k, v) -> put(k, v) } })
        }
        put("remoteURL", record.remoteURL)
        put("localFilename", record.localFilename)
        put("bytesTotal", record.bytesTotal)
        put("bytesDone", record.bytesDone)
        put("state", record.state.wireValue)
        put("addedAt", record.addedAt)
        record.errorText?.let { put("errorText", it) }
        record.retryNote?.let { put("retryNote", it) }
        record.taskIdentifier?.let { put("taskIdentifier", it) }
    }

    private fun recordFromJson(json: JSONObject): DownloadRecord? {
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
            isTorrent = json.optBoolean("isTorrent", false),
            headers = headers,
            remoteURL = json.optString("remoteURL"),
            localFilename = json.optString("localFilename"),
            bytesTotal = json.optLong("bytesTotal", 0L),
            bytesDone = json.optLong("bytesDone", 0L),
            state = DownloadState.fromWire(json.optString("state")),
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
