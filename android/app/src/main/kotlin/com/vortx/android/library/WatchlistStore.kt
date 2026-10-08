package com.vortx.android.library

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Want-to-watch projection, separate from engine-library membership and remote integrations.
 *
 * This module does not currently carry AndroidX DataStore. Keep the existing Apple-compatible
 * SharedPreferences keys, but follow the repository's serialized IO pattern (SkipTimestampStore): one
 * coroutine [Mutex] around read-modify-write and JSON/persistence operations on [Dispatchers.IO].
 * Native mode instead uses the injected account/profile host-register authority, with no local
 * ledger fallback or optimistic publication. Native clocks and checkpointing belong to its gateway.
 */
class WatchlistStore internal constructor(
    private val persistence: WatchlistPersistence,
    private val activeProfileId: () -> String,
    registerProfileSwitch: ((() -> Unit) -> Unit),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val nowEpochSeconds: () -> Double = { System.currentTimeMillis() / 1000.0 },
    initialNativeEnabled: () -> Boolean = { false },
) {
    private val _items = MutableStateFlow<List<MetaItem>>(emptyList())
    val items: StateFlow<List<MetaItem>> = _items.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()
    private val mutex = Mutex()
    private val publishLock = Any()

    private var publishedProfileId: String? = null
    private var publishedNativeOwner: NativeWatchlistGateway.Owner? = null
    private var profileGeneration = 0L
    private var reloadSequence = 0L
    private var nativeGateway: NativeWatchlistGateway? = null
    private var nativeEnabled: () -> Boolean = initialNativeEnabled
    private var nativeChangesJob: Job? = null

    init {
        scheduleReload(advanceGeneration = true)
        registerProfileSwitch { scheduleReload(advanceGeneration = true) }
    }

    /** Application wiring owns this choice. Native enabled with no gateway always fails closed. */
    internal fun installNativeGateway(gateway: NativeWatchlistGateway?, enabled: () -> Boolean) {
        val previous = synchronized(publishLock) {
            profileGeneration += 1
            nativeGateway = gateway
            nativeEnabled = enabled
            publishedNativeOwner = null
            publishedProfileId = null
            _items.value = emptyList()
            _error.value = null
            nativeChangesJob.also { nativeChangesJob = null }
        }
        previous?.cancel()
        val job = gateway?.let {
            scope.launch { it.changes.collect { scheduleReload() } }
        }
        synchronized(publishLock) {
            if (nativeGateway === gateway && nativeEnabled === enabled) nativeChangesJob = job else job?.cancel()
        }
        scheduleReload()
    }

    /**
     * Called synchronously before native account retire/rebind/mount. May run while Session is held:
     * never call a gateway, profile provider or other external code under this publication monitor.
     */
    internal fun invalidateNativeAuthority() = synchronized(publishLock) {
        profileGeneration += 1
        publishedNativeOwner = null
        publishedProfileId = null
        _items.value = emptyList()
        _error.value = null
    }

    fun requestReload() = scheduleReload()

    suspend fun reload() {
        reload(currentProfileOperation())
    }

    private suspend fun reload(operation: ProfileOperation) {
        mutex.withLock {
            val loaded = withContext(ioDispatcher) {
                operation.native?.let { NativeWatchlistCodec.entries(it.snapshot.registers) }
                    ?: WatchlistCodec.decode(persistence.read(storageKey(operation.profileId))).take(MAX_ENTRIES)
            }
            publishIfCurrent(operation, loaded.map(WatchlistEntry::toMetaItem))
        }
    }

    fun isWatchlisted(id: String): Boolean = _items.value.any { it.id == id }
    fun isWatchlisted(id: String, type: MediaType): Boolean = _items.value.any { it.id == id && it.type == type }

    /** Must run in the click/intent caller, before launch/withContext can capture a newer owner. */
    internal fun captureToggle(item: MetaItem): ToggleIntent {
        val operation = currentProfileOperation()
        val entry = WatchlistEntry(item.id, item.type.id, item.name.takeIf(String::isNotBlank),
            item.poster?.takeIf(String::isNotBlank), nowEpochSeconds())
        if (operation.native != null) NativeWatchlistCodec.field(entry.id, entry.type)
        return ToggleIntent(operation, entry)
    }

    /** Returns the new membership state. Unsafe synthetic ids are rejected. */
    suspend fun toggle(item: MetaItem): Boolean = toggle(captureToggle(item))

    internal suspend fun toggle(intent: ToggleIntent): Boolean {
        val operation = intent.operation
        if (operation.native == null && !isSafeId(intent.entry.id)) return false
        return mutex.withLock {
            check(intentSourceCurrent(operation)) { "Watchlist account or profile changed. Try again." }
            operation.native?.let { native ->
                val current = withContext(ioDispatcher) { NativeWatchlistCodec.entries(native.snapshot.registers) }
                val adding = current.none { it.id == intent.entry.id && it.type == intent.entry.type }
                val changes = withContext(ioDispatcher) {
                    if (adding) NativeWatchlistCodec.requireAdditionCapacity(current, intent.entry.id, intent.entry.type)
                    NativeWatchlistCodec.change(intent.entry, adding)
                }
                val acknowledged = native.gateway.mutate(native.snapshot.owner, changes).getOrThrow()
                val loaded = withContext(ioDispatcher) { NativeWatchlistCodec.entries(acknowledged.registers) }
                check(loaded.any { it.id == intent.entry.id && it.type == intent.entry.type } == adding) {
                    "Watchlist update was not acknowledged. Try again."
                }
                check(publishIfCurrent(operation.copy(native = native.copy(snapshot = acknowledged)),
                    loaded.map(WatchlistEntry::toMetaItem))) { "Watchlist account or profile changed. Try again." }
                return@withLock adding
            }
            val result = withContext(ioDispatcher) {
                val current = WatchlistCodec.decode(
                    persistence.read(storageKey(operation.profileId)),
                ).toMutableList()
                val existing = current.indexOfFirst { it.id == intent.entry.id }
                val nowWatchlisted = existing < 0
                if (existing >= 0) {
                    current.removeAt(existing)
                } else {
                    current += intent.entry.copy(type = if (intent.entry.type == MediaType.SERIES.id) MediaType.SERIES.id else MediaType.MOVIE.id)
                }
                val bounded = current.sortedByDescending(WatchlistEntry::addedAt).take(MAX_ENTRIES)
                check(persistence.write(storageKey(operation.profileId), WatchlistCodec.encode(bounded))) {
                    "Could not save Watchlist. Try again."
                }
                ToggleResult(nowWatchlisted, bounded.map(WatchlistEntry::toMetaItem))
            }
            // Publication is part of the same serialized operation as the read/write. A reload that
            // entered first must publish before a queued toggle, never after that newer mutation.
            publishIfCurrent(operation, result.items)
            result.nowWatchlisted
        }
    }

    private fun scheduleReload(advanceGeneration: Boolean = false) {
        val attempt = synchronized(publishLock) {
            if (advanceGeneration) profileGeneration += 1
            ReloadAttempt(profileGeneration, ++reloadSequence)
        }
        val operation = try { currentProfileOperation().copy(loadTicket = attempt.ticket) } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            synchronized(publishLock) {
                if (profileGeneration == attempt.generation && reloadSequence == attempt.ticket) {
                    _items.value = emptyList()
                    _error.value = "Watchlist is unavailable for this account. Try again."
                }
            }
            return
        }
        scope.launch {
            try { reload(operation) } catch (error: Exception) {
                if (error is kotlinx.coroutines.CancellationException) throw error
                reportLoadFailure(operation)
            }
        }
    }

    private fun currentProfileOperation(): ProfileOperation {
        val basis = synchronized(publishLock) { CaptureBasis(profileGeneration, nativeGateway, nativeEnabled) }
        // Session -> publication is the integration lock order. Never invert it by capturing inside
        // publishLock; the synchronous native invalidation hook fences this capture/publication gap.
        val native = if (basis.enabled()) {
            val gateway = checkNotNull(basis.gateway) { "Native Watchlist is unavailable" }
            NativeOperation(gateway, gateway.capture().getOrThrow())
        } else null
        val profileId = native?.snapshot?.owner?.profileId ?: activeProfileId()
        fun record(): ProfileOperation = synchronized(publishLock) {
            check(profileGeneration == basis.generation && nativeGateway === basis.gateway && nativeEnabled === basis.enabled) {
                "Watchlist account or profile changed. Try again."
            }
            // Normally the profile listener has already advanced the generation. This branch also
            // makes a direct reload/toggle safe if the active-profile provider changes first.
            if (publishedProfileId != profileId || publishedNativeOwner != native?.snapshot?.owner) {
                if (native == null) profileGeneration += 1
                publishedProfileId = profileId
                publishedNativeOwner = native?.snapshot?.owner
                _items.value = emptyList()
                _error.value = null
            }
            ProfileOperation(profileId, profileGeneration, native)
        }
        if (native == null) return record()
        // Bookkeeping/clears are publications too: an older capture cannot clear a newer revision.
        var operation: ProfileOperation? = null
        check(native.gateway.publishIfCurrent(native.snapshot.owner) { operation = record() }) {
            "Watchlist account or profile changed. Try again."
        }
        return checkNotNull(operation)
    }

    private fun publishIfCurrent(operation: ProfileOperation, items: List<MetaItem>): Boolean {
        val basis = synchronized(publishLock) { CaptureBasis(profileGeneration, nativeGateway, nativeEnabled) }
        if (basis.generation != operation.generation) return false
        var published = false
        val publication = {
            synchronized(publishLock) {
                if (
                profileGeneration == operation.generation &&
                nativeGateway === basis.gateway && nativeEnabled === basis.enabled &&
                publishedProfileId == operation.profileId
                ) {
                    publishedNativeOwner = operation.native?.snapshot?.owner
                    _items.value = items
                    _error.value = null
                    reloadSequence += 1
                    published = true
                }
            }
            Unit
        }
        operation.native?.let {
            if (basis.gateway !== it.gateway || !basis.enabled()) return false
            // Atomic publication admission only. Mutation used its original opaque Owner throughout.
            return it.gateway.publishIfCurrent(it.snapshot.owner, publication) && published
        }
        if (basis.enabled() || activeProfileId() != operation.profileId) return false
        publication()
        return published
    }

    private fun intentSourceCurrent(operation: ProfileOperation): Boolean {
        val basis = synchronized(publishLock) { CaptureBasis(profileGeneration, nativeGateway, nativeEnabled) }
        if (basis.generation != operation.generation) return false
        val modeMatches = operation.native?.let { basis.gateway === it.gateway && basis.enabled() }
            ?: (!basis.enabled() && activeProfileId() == operation.profileId)
        return synchronized(publishLock) {
            modeMatches && profileGeneration == operation.generation && nativeGateway === basis.gateway && nativeEnabled === basis.enabled
        }
    }

    private fun reportLoadFailure(operation: ProfileOperation) {
        val failure = {
            synchronized(publishLock) {
                if (profileGeneration == operation.generation && operation.loadTicket == reloadSequence) {
                    _items.value = emptyList()
                    _error.value = "Watchlist is unavailable for this account. Try again."
                }
            }
            Unit
        }
        operation.native?.let { it.gateway.publishIfCurrent(it.snapshot.owner, failure) }
            ?: if (intentSourceCurrent(operation)) failure() else Unit
    }

    private fun storageKey(profileId: String): String = "$KEY_PREFIX.$profileId"

    internal class ToggleIntent internal constructor(internal val operation: ProfileOperation, internal val entry: WatchlistEntry)

    internal data class ProfileOperation(val profileId: String, val generation: Long, val native: NativeOperation? = null, val loadTicket: Long? = null)
    internal data class NativeOperation(val gateway: NativeWatchlistGateway, val snapshot: NativeWatchlistGateway.Snapshot)
    private data class CaptureBasis(val generation: Long, val gateway: NativeWatchlistGateway?, val enabled: () -> Boolean)
    private data class ReloadAttempt(val generation: Long, val ticket: Long)

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
                initialNativeEnabled = { com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED },
            ).also { instance = it }
        }
    }
}

internal interface WatchlistPersistence {
    fun read(key: String): String?
    fun write(key: String, value: String): Boolean
}

private class SharedPreferencesWatchlistPersistence(
    private val prefs: SharedPreferences,
) : WatchlistPersistence {
    override fun read(key: String): String? = prefs.getString(key, null)

    override fun write(key: String, value: String): Boolean {
        // commit() is intentionally blocking here because the caller is already on Dispatchers.IO and the
        // mutex must not admit another read-modify-write until this one has reached the backing store.
        return prefs.edit().putString(key, value).commit()
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
