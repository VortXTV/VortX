package com.vortx.android.sync

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

internal interface LibraryTombstonePersistence {
    fun readMap(key: String): Map<String, Double>
    fun writeMap(key: String, value: Map<String, Double>)
    fun readLegacy(key: String): Set<String>
    fun writeLegacy(key: String, value: Set<String>)
}

private class SharedPrefsLibraryTombstonePersistence(
    private val prefs: SharedPreferences,
) : LibraryTombstonePersistence {
    override fun readMap(key: String): Map<String, Double> {
        val raw = runCatching { prefs.getString(key, null) }.getOrNull() ?: return emptyMap()
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyMap()
        return buildMap {
            for (id in obj.keys()) {
                obj.optDouble(id, Double.NaN).takeIf(Double::isFinite)?.let { put(id, it) }
            }
        }
    }

    override fun writeMap(key: String, value: Map<String, Double>) {
        val encoded = JSONObject().apply { for ((id, stamp) in value) put(id, stamp) }.toString()
        prefs.edit().putString(key, encoded).apply()
    }

    override fun readLegacy(key: String): Set<String> {
        runCatching { prefs.getStringSet(key, null) }.getOrNull()?.let { return it.toSet() }
        val raw = runCatching { prefs.getString(key, null) }.getOrNull() ?: return emptySet()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptySet()
        return buildSet {
            for (index in 0 until array.length()) array.optString(index).takeIf(String::isNotEmpty)?.let(::add)
        }
    }

    override fun writeLegacy(key: String, value: Set<String>) {
        prefs.edit().putStringSet(key, value).apply()
    }
}

/** Durable LWW removal tombstones for the owner account library. */
class LibraryTombstones internal constructor(
    private val persistence: LibraryTombstonePersistence,
    private val nowMs: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    // A store is a captured owner capability, not a live pointer to whichever account signs in next.
    // A -> B -> A invalidates an old A capability even though A's durable namespace is reused.
    private val owner = synchronized(LOCK) { activeOwner }

    constructor(context: Context) : this(
        SharedPrefsLibraryTombstonePersistence(
            context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE),
        ),
    )

    private data class State(
        val removedAt: MutableMap<String, Double>,
        val addedAt: MutableMap<String, Double>,
    )

    fun all(): Set<String> = synchronized(LOCK) {
        if (!isCurrent()) return@synchronized emptySet()
        val state = load()
        if (isCurrent()) effectiveRemoved(state.removedAt, state.addedAt) else emptySet()
    }

    fun timestampsForSync(): Map<String, Map<String, Double>> = synchronized(LOCK) {
        if (!isCurrent() || owner.accountId == null) return@synchronized emptyMap()
        val state = load()
        if (!isCurrent()) return@synchronized emptyMap()
        buildMap {
            for (id in state.removedAt.keys + state.addedAt.keys) {
                val entry = buildMap {
                    state.removedAt[id]?.let { put("removedAt", it) }
                    state.addedAt[id]?.let { put("addedAt", it) }
                }
                if (entry.isNotEmpty()) put(id, entry)
            }
        }
    }

    fun tombstone(id: String): Boolean = synchronized(LOCK) {
        if (!isCurrent()) return@synchronized false
        val key = normalize(id)
        if (key.isEmpty() || key.length > MAX_ID_LENGTH) return false
        val state = load()
        val wasRemoved = isRemoved(key, state)
        state.removedAt[key] = maxOf(state.removedAt[key] ?: 0.0, nowMs())
        if (!save(state)) return@synchronized false
        !wasRemoved && isRemoved(key, state)
    }

    fun forget(id: String): Boolean = synchronized(LOCK) {
        if (!isCurrent()) return@synchronized false
        val key = normalize(id)
        if (key.isEmpty() || key.length > MAX_ID_LENGTH) return false
        val state = load()
        val wasRemoved = isRemoved(key, state)
        state.addedAt[key] = maxOf(state.addedAt[key] ?: 0.0, nowMs())
        if (!save(state)) return@synchronized false
        wasRemoved && !isRemoved(key, state)
    }

    fun merge(
        legacyIds: List<String>,
        stampsRaw: Map<String, Map<String, Double>>,
    ): Boolean = synchronized(LOCK) {
        if (!isCurrent() || owner.accountId == null) return@synchronized false
        val state = load()
        val before = effectiveRemoved(state.removedAt, state.addedAt)
        val futureThresholdMs = nowMs() + 48.0 * 60.0 * 60.0 * 1000.0
        var maxFutureSeen = 0.0
        val stamped = HashSet<String>()

        for ((rawId, entry) in stampsRaw) {
            val id = normalize(rawId)
            if (id.isEmpty() || id.length > MAX_ID_LENGTH) continue
            var applied = false
            entry["removedAt"]?.takeIf(Double::isFinite)?.let { removed ->
                if (removed > futureThresholdMs) maxFutureSeen = maxOf(maxFutureSeen, removed)
                state.removedAt[id] = maxOf(state.removedAt[id] ?: 0.0, removed)
                applied = true
            }
            entry["addedAt"]?.takeIf(Double::isFinite)?.let { added ->
                if (added > futureThresholdMs) maxFutureSeen = maxOf(maxFutureSeen, added)
                state.addedAt[id] = maxOf(state.addedAt[id] ?: 0.0, added)
                applied = true
            }
            if (applied) stamped.add(id)
        }
        for (rawId in legacyIds) {
            val id = normalize(rawId)
            if (id.isEmpty() || id.length > MAX_ID_LENGTH || id in stamped) continue
            state.removedAt[id] = maxOf(state.removedAt[id] ?: 0.0, MIGRATION_EPOCH_MS)
        }

        if (!save(state)) return@synchronized false
        if (maxFutureSeen > 0.0) {
            Log.d(TAG, "library tombstone fold saw a stamp ${maxFutureSeen.toLong()} beyond now+48h (peer clock skew)")
        }
        val after = load()
        isCurrent() && effectiveRemoved(after.removedAt, after.addedAt) != before
    }

    private fun isCurrent(): Boolean = owner == activeOwner

    private fun scopedKey(base: String): String = owner.namespace?.let { "$base.account.$it" } ?: base

    private fun load(): State {
        val removedAt = persistence.readMap(scopedKey(REMOVED_AT_KEY)).toMutableMap()
        val addedAt = persistence.readMap(scopedKey(ADDED_AT_KEY)).toMutableMap()
        // Old global data has no proven account owner; only the unassigned local namespace may see it.
        for (raw in persistence.readLegacy(scopedKey(LEGACY_DELETED_KEY)).take(MAX_ENTRIES)) {
            val id = normalize(raw)
            if (id.isNotEmpty() && id.length <= MAX_ID_LENGTH) {
                removedAt[id] = maxOf(removedAt[id] ?: 0.0, MIGRATION_EPOCH_MS)
            }
        }
        return State(removedAt, addedAt)
    }

    private fun save(state: State): Boolean {
        if (!isCurrent()) return false
        val bounded = capped(state)
        persistence.writeMap(scopedKey(REMOVED_AT_KEY), bounded.removedAt)
        persistence.writeMap(scopedKey(ADDED_AT_KEY), bounded.addedAt)
        persistence.writeLegacy(
            scopedKey(LEGACY_DELETED_KEY),
            effectiveRemoved(bounded.removedAt, bounded.addedAt),
        )
        return isCurrent()
    }

    private fun isRemoved(id: String, state: State): Boolean =
        (state.removedAt[id] ?: 0.0) > (state.addedAt[id] ?: 0.0)

    private fun capped(state: State): State {
        val ids = state.removedAt.keys + state.addedAt.keys
        if (ids.size <= MAX_ENTRIES) return state
        val keep = ids.sortedByDescending { id ->
            maxOf(state.removedAt[id] ?: 0.0, state.addedAt[id] ?: 0.0)
        }.take(MAX_ENTRIES).toSet()
        return State(
            removedAt = state.removedAt.filterKeys(keep::contains).toMutableMap(),
            addedAt = state.addedAt.filterKeys(keep::contains).toMutableMap(),
        )
    }

    companion object {
        private const val REMOVED_AT_KEY = "stremiox.library.removedAt"
        private const val ADDED_AT_KEY = "stremiox.library.addedAt"
        private const val LEGACY_DELETED_KEY = "stremiox.library.deleted"
        private const val PREFS_FILE = "vortx_settings"
        private const val TAG = "LibraryTombstones"
        const val MIGRATION_EPOCH_MS: Double = 1.0
        private const val MAX_ENTRIES = 10_000
        private const val MAX_ID_LENGTH = 512
        private val LOCK = Any()
        private data class Owner(val accountId: String?, val namespace: String?, val revision: Long)
        private var activeOwner = Owner(null, null, 0)

        /** Called only at serialized VortX session adoption/clear, before publishing the new account. */
        internal fun activateAccount(accountId: String?) = synchronized(LOCK) {
            val id = accountId?.takeIf { it.isNotBlank() }
            val namespace = id?.let {
                MessageDigest.getInstance("SHA-256").digest(it.toByteArray(Charsets.UTF_8))
                    .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
            }
            activeOwner = Owner(id, namespace, activeOwner.revision + 1)
        }

        fun normalize(id: String): String = id.trim().lowercase()

        internal fun effectiveRemoved(
            removedAt: Map<String, Double>,
            addedAt: Map<String, Double>,
        ): Set<String> = buildSet {
            for ((id, removed) in removedAt) {
                if (removed > (addedAt[id] ?: 0.0)) add(id)
            }
        }
    }
}
