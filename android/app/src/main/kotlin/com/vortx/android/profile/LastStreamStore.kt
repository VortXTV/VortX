package com.vortx.android.profile

import android.content.Context
import com.vortx.android.debrid.DebridCoordinator
import com.vortx.android.debrid.DebridService
import com.vortx.android.model.MediaRef
import com.vortx.android.model.MediaType
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import org.json.JSONObject

/** Per-profile last played source, ported for audit R01 so a process restart does not erase direct resume. */
internal class LastStreamStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    private var lastWriteAtMs = 0L

    data class Record(
        val mediaId: String,
        val mediaType: MediaType,
        val title: String,
        val url: String,
        val positionMs: Long,
        val timestampMs: Long,
        val linkSavedAtMs: Long?,
        val mediaRef: MediaRef?,
        val source: StreamSource,
        val debridService: DebridService?,
        val infoHash: String?,
        val torrentId: Int?,
        val fileId: Int?,
        val fileIdx: Int?,
    )

    fun load(): Record? = prefs.getString(key(), null)?.let(::decode)

    fun saveReady(
        mediaId: String,
        mediaType: MediaType,
        playable: Playable,
        source: StreamSource?,
        ref: DebridCoordinator.DebridPlaybackRef?,
        linkSavedAtMs: Long?,
    ) {
        source ?: return
        write(
            Record(
                mediaId = mediaId,
                mediaType = mediaType,
                title = playable.mediaRef?.title ?: playable.title,
                url = playable.url,
                positionMs = playable.startPositionMs,
                timestampMs = System.currentTimeMillis(),
                linkSavedAtMs = linkSavedAtMs,
                mediaRef = playable.mediaRef,
                source = source,
                debridService = ref?.service,
                infoHash = ref?.infoHash,
                torrentId = ref?.torrentId,
                fileId = ref?.fileId,
                fileIdx = ref?.fileIdx,
            ),
        )
    }

    fun saveProgress(mediaId: String, positionMs: Long, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - lastWriteAtMs < WRITE_THROTTLE_MS) return
        val current = load()?.takeIf { it.mediaId == mediaId } ?: return
        write(current.copy(positionMs = positionMs.coerceAtLeast(0L), timestampMs = now))
    }

    private fun write(record: Record) {
        prefs.edit().putString(key(), encode(record).toString()).apply()
        lastWriteAtMs = System.currentTimeMillis()
    }

    private fun key(): String = "$KEY_PREFIX${ProfileStore.sharedOrNull()?.activeProfileId ?: UserProfile.OWNER_ID}"

    private fun encode(record: Record) = JSONObject().apply {
        put("mediaId", record.mediaId)
        put("mediaType", record.mediaType.id)
        put("title", record.title)
        put("url", record.url)
        put("positionMs", record.positionMs)
        put("timestampMs", record.timestampMs)
        record.linkSavedAtMs?.let { put("linkSavedAtMs", it) }
        put("source", JSONObject().apply {
            put("id", record.source.id)
            put("addon", record.source.addon)
            put("title", record.source.title)
            record.source.description?.let { put("description", it) }
            record.source.quality?.let { put("quality", it) }
            put("isTorrent", record.source.isTorrent)
            record.source.url?.let { put("url", it) }
            record.source.infoHash?.let { put("infoHash", it) }
            record.source.fileIdx?.let { put("fileIdx", it) }
            record.source.nzbUrl?.let { put("nzbUrl", it) }
            record.source.usenetKnownHash?.let { put("usenetKnownHash", it) }
            record.source.fileMustInclude?.let { put("fileMustInclude", it) }
            record.source.bingeGroup?.let { put("bingeGroup", it) }
        })
        record.mediaRef?.let { media ->
            put("mediaRef", JSONObject().apply {
                put("isSeries", media.isSeries)
                media.imdb?.let { put("imdb", it) }
                media.tmdb?.let { put("tmdb", it) }
                media.season?.let { put("season", it) }
                media.episode?.let { put("episode", it) }
                media.title?.let { put("title", it) }
                media.year?.let { put("year", it) }
            })
        }
        record.debridService?.let { put("debridService", it.id) }
        record.infoHash?.let { put("debridInfoHash", it) }
        record.torrentId?.let { put("torrentId", it) }
        record.fileId?.let { put("fileId", it) }
        record.fileIdx?.let { put("debridFileIdx", it) }
    }

    private fun decode(raw: String): Record? = runCatching {
        val json = JSONObject(raw)
        val sourceJson = json.getJSONObject("source")
        val mediaJson = json.optJSONObject("mediaRef")
        Record(
            mediaId = json.getString("mediaId"),
            mediaType = MediaType.entries.first { it.id == json.getString("mediaType") },
            title = json.getString("title"),
            url = json.getString("url"),
            positionMs = json.optLong("positionMs"),
            timestampMs = json.optLong("timestampMs"),
            linkSavedAtMs = json.optLongOrNull("linkSavedAtMs"),
            mediaRef = mediaJson?.let {
                MediaRef(
                    isSeries = it.optBoolean("isSeries"),
                    imdb = it.optStringOrNull("imdb"),
                    tmdb = it.optIntOrNull("tmdb"),
                    season = it.optIntOrNull("season"),
                    episode = it.optIntOrNull("episode"),
                    title = it.optStringOrNull("title"),
                    year = it.optIntOrNull("year"),
                )
            },
            source = StreamSource(
                id = sourceJson.getString("id"),
                addon = sourceJson.getString("addon"),
                title = sourceJson.getString("title"),
                description = sourceJson.optStringOrNull("description"),
                quality = sourceJson.optStringOrNull("quality"),
                isTorrent = sourceJson.optBoolean("isTorrent"),
                url = sourceJson.optStringOrNull("url"),
                infoHash = sourceJson.optStringOrNull("infoHash"),
                fileIdx = sourceJson.optIntOrNull("fileIdx"),
                nzbUrl = sourceJson.optStringOrNull("nzbUrl"),
                usenetKnownHash = sourceJson.optStringOrNull("usenetKnownHash"),
                fileMustInclude = sourceJson.optStringOrNull("fileMustInclude"),
                bingeGroup = sourceJson.optStringOrNull("bingeGroup"),
            ),
            debridService = json.optStringOrNull("debridService")?.let { id ->
                DebridService.entries.firstOrNull { it.id == id }
            },
            infoHash = json.optStringOrNull("debridInfoHash"),
            torrentId = json.optIntOrNull("torrentId"),
            fileId = json.optIntOrNull("fileId"),
            fileIdx = json.optIntOrNull("debridFileIdx"),
        )
    }.getOrNull()

    private fun JSONObject.optStringOrNull(name: String): String? =
        if (has(name) && !isNull(name)) optString(name).takeIf { it.isNotEmpty() } else null

    private fun JSONObject.optIntOrNull(name: String): Int? = if (has(name) && !isNull(name)) optInt(name) else null
    private fun JSONObject.optLongOrNull(name: String): Long? = if (has(name) && !isNull(name)) optLong(name) else null

    companion object {
        private const val KEY_PREFIX = "stremiox.profiles.lastStream."
        private const val WRITE_THROTTLE_MS = 15_000L
    }
}
