package com.vortx.android.player.queue

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.security.MessageDigest
import java.util.UUID

/** Upcoming catalog targets only. No resolved streams, credentials, playback leases or progress. */
internal data class PlaybackQueueEntry(val id: String, val item: MetaItem)

internal data class PlaybackQueueState(
    val owner: ContinueWatchingOwner? = null,
    val revision: Long = 0L,
    val ready: Boolean = false,
    val entries: List<PlaybackQueueEntry> = emptyList(),
    val error: String? = null,
)

/** An in-memory capability: every queue edit and every original owner transition revokes it. */
internal class PlaybackQueueToken internal constructor(
    val owner: ContinueWatchingOwner,
    val revision: Long,
    val entry: PlaybackQueueEntry,
)

internal object PlaybackQueueModel {
    const val MAX_ENTRIES = 100

    fun capture(state: PlaybackQueueState, owner: ContinueWatchingOwner, id: String): PlaybackQueueToken? =
        state.takeIf { it.ready && it.owner == owner }?.entries?.firstOrNull { it.id == id }
            ?.let { PlaybackQueueToken(owner, state.revision, it) }

    fun accepts(state: PlaybackQueueState, currentOwner: ContinueWatchingOwner, token: PlaybackQueueToken): Boolean =
        state.ready && currentOwner == token.owner && state.owner == token.owner &&
            state.revision == token.revision && state.entries.any { it == token.entry }

    fun add(state: PlaybackQueueState, owner: ContinueWatchingOwner, item: MetaItem, playNext: Boolean,
            newId: String = UUID.randomUUID().toString()): PlaybackQueueState? {
        if (!state.ready || state.owner != owner || state.entries.size >= MAX_ENTRIES ||
            state.entries.any { it.id == newId }) return null
        val entry = PlaybackQueueEntry(validUuid(newId), catalogOnly(item))
        return changed(state, if (playNext) listOf(entry) + state.entries else state.entries + entry)
    }

    fun remove(state: PlaybackQueueState, owner: ContinueWatchingOwner, id: String): PlaybackQueueState? {
        if (!state.ready || state.owner != owner || state.entries.none { it.id == id }) return null
        return changed(state, state.entries.filterNot { it.id == id })
    }

    fun move(state: PlaybackQueueState, owner: ContinueWatchingOwner, id: String, delta: Int): PlaybackQueueState? {
        if (!state.ready || state.owner != owner || delta !in listOf(-1, 1)) return null
        val from = state.entries.indexOfFirst { it.id == id }
        val to = from + delta
        if (from < 0 || to !in state.entries.indices) return null
        val entries = state.entries.toMutableList()
        entries.add(to, entries.removeAt(from))
        return changed(state, entries)
    }

    fun consumeAfterAccepted(state: PlaybackQueueState, currentOwner: ContinueWatchingOwner,
                             token: PlaybackQueueToken): PlaybackQueueState? =
        if (accepts(state, currentOwner, token)) remove(state, currentOwner, token.entry.id) else null

    private fun changed(state: PlaybackQueueState, entries: List<PlaybackQueueEntry>) = state.copy(
        revision = Math.incrementExact(state.revision), entries = entries, error = null,
    )

    /** Namespace is stable across launches, while the in-memory token includes the full owner revision. */
    fun storageKey(owner: ContinueWatchingOwner): String {
        val parts = listOf(owner.accountSlot, owner.principal, owner.profileId,
            if (owner.usesEngineHistory) "engine" else "overlay")
        require(parts.take(3).all { it.isNotBlank() && it.length <= 2048 })
        val framed = parts.joinToString("") { "${it.length}:$it" }.toByteArray(Charsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-256").digest(framed)
        return "queue.v1." + digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    internal fun validUuid(raw: String): String {
        require(raw.length == 36 && UUID.fromString(raw).toString() == raw)
        return raw
    }

    internal fun catalogOnly(item: MetaItem): MetaItem {
        require(item.type == MediaType.MOVIE || item.type == MediaType.SERIES)
        require(item.id.isNotBlank() && item.id.length <= 1024 && item.id.none { it.code < 32 })
        require(item.name.isNotBlank() && item.name.length <= 512 && '\u0000' !in item.name)
        require(item.poster == null || (item.poster.length <= 4096 && '\u0000' !in item.poster))
        val hint = item.preferredEpisode?.also {
            require(item.type == MediaType.SERIES && it.season >= 0 && it.episode > 0)
            require(it.videoIdentity == null || (it.videoIdentity.length <= 1024 && it.videoIdentity.none { c -> c.code < 32 }))
        }?.copy(upNext = false)
        return MetaItem(id = item.id, type = item.type, name = item.name, poster = item.poster, preferredEpisode = hint)
    }
}

/** Unknown/newer records remain untouched on disk: fail the whole load rather than rewrite a subset. */
internal object PlaybackQueueCodec {
    private const val MAX_BYTES = 768 * 1024
    private fun fields(o: JSONObject, allowed: Set<String>) {
        require(o.keys().asSequence().all { it in allowed })
    }
    private fun text(o: JSONObject, key: String): String = (o.opt(key) as? String) ?: error("Invalid queue field")
    private fun optionalText(o: JSONObject, key: String): String? = if (!o.has(key) || o.isNull(key)) null else text(o, key)
    private fun integer(o: JSONObject, key: String): Int {
        val value = o.opt(key)
        require(value is Int || value is Long)
        val long = (value as Number).toLong()
        require(long in Int.MIN_VALUE..Int.MAX_VALUE)
        return long.toInt()
    }

    fun decode(raw: String?): List<PlaybackQueueEntry> {
        if (raw == null) return emptyList()
        require(raw.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
        require('\u0000' !in raw)
        val input = JSONTokener(raw)
        val doc = input.nextValue() as? JSONObject ?: error("Invalid queue document")
        require(input.nextClean() == '\u0000')
        fields(doc, setOf("schema", "entries"))
        require(integer(doc, "schema") == 1)
        val array = doc.opt("entries") as? JSONArray ?: error("Invalid queue entries")
        require(array.length() <= PlaybackQueueModel.MAX_ENTRIES)
        val entries = (0 until array.length()).map { index ->
            val o = array.opt(index) as? JSONObject ?: error("Invalid queue entry")
            fields(o, setOf("entryId", "id", "type", "name", "poster", "episode"))
            val type = when (text(o, "type")) {
                "movie" -> MediaType.MOVIE
                "series" -> MediaType.SERIES
                else -> error("Unsupported queue media")
            }
            val episode = if (!o.has("episode") || o.isNull("episode")) null else {
                val e = o.opt("episode") as? JSONObject ?: error("Invalid queue episode")
                fields(e, setOf("season", "number", "videoId"))
                PreferredEpisode(integer(e, "season"), integer(e, "number"), optionalText(e, "videoId"))
            }
            PlaybackQueueEntry(PlaybackQueueModel.validUuid(text(o, "entryId")), PlaybackQueueModel.catalogOnly(
                MetaItem(text(o, "id"), type, text(o, "name"), optionalText(o, "poster"), preferredEpisode = episode),
            ))
        }
        require(entries.map { it.id }.toSet().size == entries.size)
        return entries
    }

    fun encode(entries: List<PlaybackQueueEntry>): String {
        require(entries.size <= PlaybackQueueModel.MAX_ENTRIES && entries.map { it.id }.toSet().size == entries.size)
        val array = JSONArray()
        entries.forEach { entry ->
            val item = PlaybackQueueModel.catalogOnly(entry.item)
            val o = JSONObject().put("entryId", PlaybackQueueModel.validUuid(entry.id)).put("id", item.id)
                .put("type", item.type.id).put("name", item.name)
            item.poster?.let { o.put("poster", it) }
            item.preferredEpisode?.let { e ->
                val hint = JSONObject().put("season", e.season).put("number", e.episode)
                e.videoIdentity?.let { hint.put("videoId", it) }
                o.put("episode", hint)
            }
            array.put(o)
        }
        return JSONObject().put("schema", 1).put("entries", array).toString().also {
            require(it.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
        }
    }
}
