package com.vortx.android.library

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Profile-local want-to-watch ledger, separate from the account library and remote integrations.
 *
 * This module does not currently carry AndroidX DataStore. Keep the existing Apple-compatible
 * SharedPreferences keys, but follow the repository's serialized IO pattern (SkipTimestampStore): one
 * coroutine [Mutex] around read-modify-write and every JSON/persistence operation on [Dispatchers.IO].
 */
class WatchlistStore internal constructor(
    private val persistence: WatchlistPersistence,
    private val activeProfileId: () -> String,
    registerProfileSwitch: ((() -> Unit) -> Unit),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowEpochSeconds: () -> Double = { System.currentTimeMillis() / 1000.0 },
) {
    private val _items = MutableStateFlow<List<MetaItem>>(emptyList())
    val items: StateFlow<List<MetaItem>> = _items.asStateFlow()
    private val mutex = Mutex()
    private val publishLock = Any()

    private var publishedProfileId: String? = null
    private var profileGeneration = 0L

    init {
        scheduleReload()
        registerProfileSwitch(::scheduleReload)
    }

    suspend fun reload() {
        reload(currentProfileOperation())
    }

    private suspend fun reload(operation: ProfileOperation) {
        mutex.withLock {
            val loaded = withContext(ioDispatcher) {
                WatchlistCodec.decode(persistence.read(storageKey(operation.profileId)))
                    .take(MAX_ENTRIES)
                    .map(WatchlistEntry::toMetaItem)
            }
            publishIfCurrent(operation, loaded)
        }
    }

    fun isWatchlisted(id: String): Boolean = _items.value.any { it.id == id }

    /** Returns the new membership state. Unsafe synthetic ids are rejected. */
    suspend fun toggle(item: MetaItem): Boolean {
        if (!isSafeId(item.id)) return false
        val operation = currentProfileOperation()
        return mutex.withLock {
            val result = withContext(ioDispatcher) {
                val current = WatchlistCodec.decode(
                    persistence.read(storageKey(operation.profileId)),
                ).toMutableList()
                val existing = current.indexOfFirst { it.id == item.id }
                val nowWatchlisted = existing < 0
                if (existing >= 0) {
                    current.removeAt(existing)
                } else {
                    current += WatchlistEntry(
                        id = item.id,
                        type = if (item.type == MediaType.SERIES) MediaType.SERIES.id else MediaType.MOVIE.id,
                        name = item.name.takeIf(String::isNotBlank),
                        poster = item.poster?.takeIf(String::isNotBlank),
                        addedAt = nowEpochSeconds(),
                    )
                }
                val bounded = current.sortedByDescending(WatchlistEntry::addedAt).take(MAX_ENTRIES)
                persistence.write(storageKey(operation.profileId), WatchlistCodec.encode(bounded))
                ToggleResult(nowWatchlisted, bounded.map(WatchlistEntry::toMetaItem))
            }
            // Publication is part of the same serialized operation as the read/write. A reload that
            // entered first must publish before a queued toggle, never after that newer mutation.
            publishIfCurrent(operation, result.items)
            result.nowWatchlisted
        }
    }

    private fun scheduleReload() {
        val operation = beginProfileReload()
        scope.launch { reload(operation) }
    }

    private fun beginProfileReload(): ProfileOperation = synchronized(publishLock) {
        val profileId = activeProfileId()
        profileGeneration += 1
        if (publishedProfileId != profileId) {
            publishedProfileId = profileId
            _items.value = emptyList()
        }
        ProfileOperation(profileId, profileGeneration)
    }

    private fun currentProfileOperation(): ProfileOperation {
        val profileId = activeProfileId()
        return synchronized(publishLock) {
            // Normally the profile listener has already advanced the generation. This branch also
            // makes a direct reload/toggle safe if the active-profile provider changes first.
            if (publishedProfileId != profileId) {
                profileGeneration += 1
                publishedProfileId = profileId
                _items.value = emptyList()
            }
            ProfileOperation(profileId, profileGeneration)
        }
    }

    private fun publishIfCurrent(operation: ProfileOperation, items: List<MetaItem>) {
        synchronized(publishLock) {
            if (
                profileGeneration == operation.generation &&
                publishedProfileId == operation.profileId &&
                activeProfileId() == operation.profileId
            ) {
                _items.value = items
            }
        }
    }

    private fun storageKey(profileId: String): String = "$KEY_PREFIX.$profileId"

    private data class ProfileOperation(val profileId: String, val generation: Long)

    private data class ToggleResult(val nowWatchlisted: Boolean, val items: List<MetaItem>)

    internal companion object {
        private const val KEY_PREFIX = "vortx.watchlist"
        internal const val MAX_ENTRIES = 1000

        internal fun isSafeId(id: String): Boolean = id.startsWith("tt") || id.startsWith("tmdb")

        @Volatile
        private var instance: WatchlistStore? = null

        fun shared(context: Context): WatchlistStore = instance ?: synchronized(this) {
            instance ?: WatchlistStore(
                persistence = SharedPreferencesWatchlistPersistence(
                    context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE),
                ),
                activeProfileId = { ProfileStore.shared.activeProfileId },
                registerProfileSwitch = { ProfileStore.shared.addSwitchListener(it) },
            ).also { instance = it }
        }
    }
}

internal interface WatchlistPersistence {
    fun read(key: String): String?
    fun write(key: String, value: String)
}

private class SharedPreferencesWatchlistPersistence(
    private val prefs: SharedPreferences,
) : WatchlistPersistence {
    override fun read(key: String): String? = prefs.getString(key, null)

    override fun write(key: String, value: String) {
        // commit() is intentionally blocking here because the caller is already on Dispatchers.IO and the
        // mutex must not admit another read-modify-write until this one has reached the backing store.
        prefs.edit().putString(key, value).commit()
    }
}

internal data class WatchlistEntry(
    val id: String,
    val type: String,
    val name: String?,
    val poster: String?,
    val addedAt: Double,
) {
    fun toMetaItem(): MetaItem = MetaItem(
        id = id,
        type = MediaType.fromId(type),
        name = name ?: id,
        poster = poster,
    )
}

internal object WatchlistCodec {
    fun decode(raw: String?): List<WatchlistEntry> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val value = array.optJSONObject(index) ?: continue
                    val id = value.optString("id").takeIf(WatchlistStore::isSafeId) ?: continue
                    add(
                        WatchlistEntry(
                            id = id,
                            type = if (value.optString("type") == MediaType.SERIES.id) {
                                MediaType.SERIES.id
                            } else {
                                MediaType.MOVIE.id
                            },
                            name = value.optNullableString("name"),
                            poster = value.optNullableString("poster"),
                            addedAt = value.optDouble("addedAt").takeIf(Double::isFinite) ?: 0.0,
                        ),
                    )
                }
            }.sortedByDescending(WatchlistEntry::addedAt).distinctBy(WatchlistEntry::id)
        }.getOrDefault(emptyList())
    }

    fun encode(entries: List<WatchlistEntry>): String = JSONArray().apply {
        entries.forEach { entry ->
            put(
                JSONObject().apply {
                    put("id", entry.id)
                    put("type", entry.type)
                    put("name", entry.name ?: JSONObject.NULL)
                    put("poster", entry.poster ?: JSONObject.NULL)
                    put("addedAt", entry.addedAt)
                },
            )
        }
    }.toString()
}

private fun JSONObject.optNullableString(key: String): String? =
    if (!has(key) || isNull(key)) null else optString(key).takeIf(String::isNotBlank)
