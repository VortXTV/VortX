package com.vortx.android.library

import com.vortx.android.model.Catalog
import com.vortx.android.profile.WatchEntry
import org.json.JSONObject
import java.io.File

/** Cached O(1) watched-title lookup for the active Home profile. */
internal class WatchedIndex(private val storageDir: File) {
    private var cachedUid: String? = null
    private var cachedSignature: List<BucketSignature> = emptyList()
    private var cachedIds: Set<String> = emptySet()

    /** Engine-backed history, guarded by the bucket's account uid and refreshed on file change. */
    @Synchronized
    fun engineIds(expectedUid: String?): Set<String> {
        val files = BUCKET_NAMES.map { File(storageDir, it) }
        val signature = files.map(::signature)
        if (cachedUid == expectedUid && cachedSignature == signature) return cachedIds

        cachedUid = expectedUid
        cachedSignature = signature
        cachedIds = files.fold(emptySet()) { ids, file ->
            ids + parseBucket(file, expectedUid)
        }
        return cachedIds
    }

    companion object {
        private val BUCKET_NAMES = listOf("library.json", "library_recent.json")

        /** Overlay profiles never read account history. Any watched video marks the title watched. */
        fun overlayIds(watch: Map<String, WatchEntry>): Set<String> =
            watch.asSequence()
                .filter { (_, entry) -> entry.watchedVideoIds.isNotEmpty() }
                .mapTo(linkedSetOf()) { (metaId, _) -> metaId }

        /** Merge engine history without trusting the stale account preview during sign-out suppression. */
        fun engineHomeIds(
            bucketIds: Set<String>,
            libraryIds: Set<String>,
            continueWatchingIds: Set<String>,
            suppressAccountHistory: Boolean,
        ): Set<String> = if (suppressAccountHistory) {
            emptySet()
        } else {
            bucketIds + libraryIds + continueWatchingIds
        }

        /** Both persisted buckets must belong to the authenticated uid, including valid empty buckets. */
        fun storageMatchesUid(storageDir: File, expectedUid: String): Boolean =
            BUCKET_NAMES.all { name ->
                val file = File(storageDir, name)
                file.isFile && runCatching {
                    val root = JSONObject(file.readText())
                    root.has("uid") && !root.isNull("uid") && root.optString("uid") == expectedUid
                }.getOrDefault(false)
            }

        /** Apply badges to catalog rails while leaving Continue Watching untouched. */
        fun apply(catalogs: List<Catalog>, watchedIds: Set<String>): List<Catalog> =
            catalogs.map { catalog ->
                if (catalog.id == CONTINUE_ROW_ID) catalog else catalog.copy(
                    items = catalog.items.map { item -> item.copy(watched = item.id in watchedIds) },
                )
            }

        internal fun parseBucketJson(json: String, expectedUid: String?): Set<String> {
            val root = runCatching { JSONObject(json) }.getOrNull() ?: return emptySet()
            val bucketUid = if (root.has("uid") && !root.isNull("uid")) root.optString("uid") else null
            if (bucketUid != expectedUid) return emptySet()
            val items = root.optJSONObject("items") ?: return emptySet()
            val watched = linkedSetOf<String>()
            for (id in items.keys()) {
                val state = items.optJSONObject(id)?.optJSONObject("state") ?: continue
                if (state.optInt("timesWatched", 0) > 0) watched += id
            }
            return watched
        }

        private fun parseBucket(file: File, expectedUid: String?): Set<String> {
            if (!file.isFile) return emptySet()
            return runCatching { parseBucketJson(file.readText(), expectedUid) }.getOrDefault(emptySet())
        }

        private fun signature(file: File): BucketSignature = BucketSignature(
            exists = file.isFile,
            modified = if (file.isFile) file.lastModified() else 0L,
            length = if (file.isFile) file.length() else 0L,
        )

        private const val CONTINUE_ROW_ID = "continue"
    }

    private data class BucketSignature(
        val exists: Boolean,
        val modified: Long,
        val length: Long,
    )
}
