package com.vortx.android.sync

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

/** Interoperable with Apple's OwnerWatchedIntentStore. Intent clocks are never viewing clocks. */
internal class OwnerWatchedIntentStore(private val persistence: LibraryProofPersistence, private val now: () -> Double = { System.currentTimeMillis().toDouble() }) {
    constructor(context: Context) : this(object : LibraryProofPersistence {
        val store = FailClosedCredentialStore(context, "vortx_owner_watched_intents", tag = "OwnerWatched")
        override fun read(key: String): Result<String?> {
            val snapshot = store.confirmedSnapshot(key)
            return if (snapshot.availability == PersistentCredentialAvailability.AVAILABLE) Result.success(snapshot.values[key])
            else Result.failure(IllegalStateException("Watched intent storage unavailable"))
        }
        override fun write(key: String, value: String) = store.set(key, value)
    })

    data class Entry(val title: String, val video: String, val watched: Boolean, val updated: Double, val actor: String) {
        val key get() = title + '\u001f' + video
        fun json() = JSONObject().put("t", title).put("v", video).put("w", watched).put("u", updated).put("a", actor)
    }

    @Synchronized fun entries(account: String): List<Entry> = load(account)?.optJSONObject("entries")?.let(::parse).orEmpty().values.toList()

    @Synchronized fun record(account: String, title: String, videos: List<String>, watched: Boolean): Boolean {
        if (!valid(title, 512) || videos.isEmpty() || videos.any { !valid(it, 512) }) return false
        val root = load(account) ?: return false
        val all = parse(root.optJSONObject("entries")).toMutableMap()
        val actor = (root.opt("actor") as? String)?.takeIf { valid(it, 128) } ?: UUID.randomUUID().toString()
        val observed = all.values.filter { it.title == title }.maxOfOrNull { it.updated } ?: 0.0
        val stamp = maxOf(now(), observed + 1)
        if (!stamp.isFinite() || stamp <= observed) return false
        for (video in videos.distinct()) Entry(title, video, watched, stamp, actor).let { all[it.key] = it }
        if (all.size > MAX_ROWS) return false
        root.put("actor", actor).put("entries", encode(all.values))
        return persist(account, root)
    }

    @Synchronized fun merge(account: String, wire: JSONObject?): Boolean {
        if (wire == null) return true
        val root = load(account) ?: return false
        val all = mergeRows(parse(root.optJSONObject("entries")), parse(wire))
        if (all.size > MAX_ROWS) return false
        return persist(account, root.put("entries", encode(all.values)))
    }

    @Synchronized fun wire(account: String, existing: JSONObject?): JSONObject =
        (existing?.let { JSONObject(it.toString()) } ?: JSONObject()).apply {
            mergeRows(parse(existing), entries(account).associateBy { it.key }).values.forEach { put(it.key, it.json()) }
        }

    private fun load(account: String): JSONObject? {
        val result = persistence.read(key(account))
        if (result.isFailure) return null
        val raw = result.getOrNull() ?: return JSONObject()
        return runCatching { JSONObject(raw) }.getOrNull()
    }
    private fun persist(account: String, root: JSONObject): Boolean {
        val raw = root.toString()
        return persistence.write(key(account), raw) && persistence.read(key(account)).getOrNull() == raw
    }
    private fun key(account: String) = "owner." + MessageDigest.getInstance("SHA-256").digest(account.toByteArray())
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    companion object {
        private const val MAX_ROWS = 50_000
        private fun valid(value: String, max: Int) = value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= max && value.none { Character.isISOControl(it) }
        fun parse(wire: JSONObject?): Map<String, Entry> {
            if (wire == null || wire.length() > MAX_ROWS) return emptyMap()
            val result = mutableMapOf<String, Entry>()
            for (key in wire.keys()) {
                val row = wire.optJSONObject(key) ?: continue
                val title = row.opt("t") as? String ?: continue
                val video = row.opt("v") as? String ?: continue
                val watched = row.opt("w") as? Boolean ?: continue
                val actor = row.opt("a") as? String ?: continue
                val updated = (row.opt("u") as? Number)?.toDouble() ?: continue
                if (!valid(title, 512) || !valid(video, 512) || !valid(actor, 128) || !updated.isFinite() || updated <= 0) continue
                val entry = Entry(title, video, watched, updated, actor)
                if (wins(entry, result[entry.key])) result[entry.key] = entry
            }
            return result
        }
        private fun mergeRows(a: Map<String, Entry>, b: Map<String, Entry>) = a.toMutableMap().apply {
            b.forEach { (key, value) -> if (wins(value, this[key])) this[key] = value }
        }
        private fun encode(entries: Collection<Entry>) = JSONObject().apply { entries.sortedBy { it.key }.forEach { put(it.key, it.json()) } }
        private fun wins(a: Entry, b: Entry?) = b == null || a.updated > b.updated || (a.updated == b.updated && a.actor > b.actor)
        fun effectiveTitles(entries: List<Entry>, engine: Set<String>): Set<String> = engine.toMutableSet().apply {
            entries.filter { it.title == it.video }.forEach { if (it.watched) add(it.title) else remove(it.title) }
        }
        fun effectiveVideos(entries: List<Entry>, title: String, engine: Set<String>, known: Set<String>): Set<String> {
            val scoped = entries.filter { it.title == title }
            val whole = scoped.firstOrNull { it.video == title }
            val result = (whole?.let { if (it.watched) known else emptySet() } ?: engine).toMutableSet()
            scoped.filter { it.video != title && (whole == null || wins(it, whole)) }.forEach { if (it.watched) result.add(it.video) else result.remove(it.video) }
            return result
        }
    }
}

internal class OwnerWatchedIntentLease(private val account: String, private val store: OwnerWatchedIntentStore, private val admit: ((() -> Boolean) -> Boolean)) {
    fun record(title: String, videos: List<String>, watched: Boolean): Boolean = admit { store.record(account, title, videos, watched) }
    fun entries(): List<OwnerWatchedIntentStore.Entry> {
        var result = emptyList<OwnerWatchedIntentStore.Entry>()
        return if (admit { result = store.entries(account); true }) result else emptyList()
    }
}
