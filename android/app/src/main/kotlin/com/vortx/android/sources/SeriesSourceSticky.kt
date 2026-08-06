package com.vortx.android.sources

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.MainThread
import com.vortx.android.profile.ProfileStore
import org.json.JSONObject

internal interface SeriesSourceStickyPersistence {
    fun read(key: String): String?
    fun write(key: String, value: String): Boolean
    fun contains(key: String): Boolean
}

private class SharedPreferencesStickyPersistence(
    private val preferences: SharedPreferences,
) : SeriesSourceStickyPersistence {
    override fun read(key: String): String? = preferences.getString(key, null)
    override fun write(key: String, value: String): Boolean = preferences.edit().putString(key, value).commit()
    override fun contains(key: String): Boolean = preferences.contains(key)
}

/**
 * Remembers the source a viewer selected by hand for a series. The record is a ranking preference, never a
 * playback lock: a later episode may still fall through to any other provider when the remembered one is absent
 * or unhealthy. Storage uses the same per-profile key and JSON shape as Apple.
 */
class SeriesSourceSticky internal constructor(
    private val persistence: SeriesSourceStickyPersistence,
    private val activeProfileId: () -> String = {
        ProfileStore.sharedOrNull()?.activeProfileId ?: DEFAULT_PROFILE
    },
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    constructor(
        context: Context,
        activeProfileId: () -> String = {
            ProfileStore.sharedOrNull()?.activeProfileId ?: DEFAULT_PROFILE
        },
        nowMs: () -> Long = System::currentTimeMillis,
    ) : this(
        persistence = SharedPreferencesStickyPersistence(
            context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE),
        ),
        activeProfileId = activeProfileId,
        nowMs = nowMs,
    )

    data class Preference(val addon: String?, val bingeGroup: String?)

    /** Captures both the profile and this screen's profile-switch epoch before an async resolve starts. */
    class WriteToken internal constructor(
        val profile: String,
        val seriesKey: String,
        internal val profileGeneration: Long,
    )

    internal data class Choice(
        val addon: String?,
        val bingeGroup: String?,
        val timestamp: Double,
    ) {
        fun preference(): Preference = Preference(addon, bingeGroup)
    }

    private val lock = Any()
    private var cachedProfile: String? = null
    private var cache: Map<String, Choice>? = null
    private var cachedRevision: Long = -1L
    private var profileGeneration: Long = 0L

    fun currentProfileId(): String = activeProfileId().ifBlank { DEFAULT_PROFILE }

    /**
     * Invalidate every outstanding write token when ProfileStore switches, including A -> B -> A. Checking only
     * the profile string would let a slow resolve from the first A session write after the round trip back to A.
     */
    fun onProfileChanged() = synchronized(lock) {
        profileGeneration += 1L
        cachedProfile = null
        cache = null
        cachedRevision = -1L
    }

    fun capture(seriesKey: String): WriteToken? {
        if (seriesKey.isBlank()) return null
        return synchronized(lock) {
            WriteToken(currentProfileId(), seriesKey, profileGeneration)
        }
    }

    /** Record only explicit viewer picks. Automatic selection and failover callers must never call this. */
    @MainThread
    fun record(seriesKey: String, addon: String?, bingeGroup: String?) {
        capture(seriesKey)?.let { record(it, addon, bingeGroup) }
    }

    /** Returns false if resolve crossed a profile switch or persistence failed. */
    @MainThread
    fun record(token: WriteToken, addon: String?, bingeGroup: String?): Boolean {
        if (addon.isNullOrBlank() && bingeGroup.isNullOrBlank()) return false
        synchronized(lock) {
            if (
                token.profileGeneration != profileGeneration ||
                token.profile != currentProfileId()
            ) {
                return false
            }
        }

        // The process-wide critical section is deliberate. Multiple detail screens own separate store instances;
        // each write must merge against the latest persisted map, not its instance cache, or concurrent picks for
        // different series lose whichever write commits first.
        return synchronized(processLock) write@{
            synchronized(lock) {
                if (
                    token.profileGeneration != profileGeneration ||
                    token.profile != currentProfileId()
                ) {
                    return@write false
                }
            }
            val latest = decodeStored(token.profile)
            val updated = latest.toMutableMap().apply {
                put(
                    token.seriesKey,
                    Choice(
                        addon = addon?.takeIf { it.isNotBlank() },
                        bingeGroup = bingeGroup?.takeIf { it.isNotBlank() },
                        timestamp = appleReferenceSeconds(nowMs()),
                    ),
                )
            }
            val pruned = prune(updated)
            if (!persistence.write(storageKey(token.profile), encode(pruned))) return@write false
            processRevision += 1L
            synchronized(lock) {
                cachedProfile = token.profile
                cache = pruned
                cachedRevision = processRevision
            }
            // Deliberately no StreamRanking.invalidateCaches(): stickiness is applied outside the score memo.
            true
        }
    }

    /** Thread-safe read; callers snapshot the immutable result before an off-thread rank pass. */
    fun preference(seriesKey: String): Preference? {
        if (seriesKey.isBlank()) return null
        return loaded().second[seriesKey]?.preference()
    }

    private fun loaded(): Pair<String, Map<String, Choice>> {
        val profile = currentProfileId()
        synchronized(lock) {
            if (cachedProfile == profile && cachedRevision == processRevision) {
                cache?.let { return profile to it }
            }
        }

        return synchronized(processLock) {
            val decoded = decodeStored(profile)
            synchronized(lock) {
                cachedProfile = profile
                cache = decoded
                cachedRevision = processRevision
            }
            profile to decoded
        }
    }

    private fun decodeStored(profile: String): Map<String, Choice> {
        val raw = persistence.read(storageKey(profile)) ?: return emptyMap()
        return runCatching { decode(raw) }.getOrElse {
            quarantineOnce(profile, raw)
            emptyMap()
        }
    }

    private fun quarantineOnce(profile: String, raw: String) {
        val key = storageKey(profile) + QUARANTINE_SUFFIX
        if (!persistence.contains(key)) persistence.write(key, raw)
    }

    internal companion object {
        private val processLock = Any()
        @Volatile
        private var processRevision: Long = 0L
        const val PREFS_FILE = "vortx_settings"
        const val DEFAULT_PROFILE = "default"
        const val MAX_SERIES = 200
        const val KEEP_SERIES = 180
        private const val QUARANTINE_SUFFIX = ".undecodable"
        private const val APPLE_REFERENCE_UNIX_SECONDS = 978_307_200.0

        fun storageKey(profile: String): String = "stremiox.seriesSourceSticky.$profile"

        internal fun prune(choices: Map<String, Choice>): Map<String, Choice> {
            if (choices.size <= MAX_SERIES) return choices.toMap()
            return choices.entries
                .sortedByDescending { it.value.timestamp }
                .take(KEEP_SERIES)
                .associate { it.key to it.value }
        }

        internal fun encode(choices: Map<String, Choice>): String = JSONObject().apply {
            choices.forEach { (seriesKey, choice) ->
                put(
                    seriesKey,
                    JSONObject().apply {
                        choice.addon?.let { put("addon", it) }
                        choice.bingeGroup?.let { put("bingeGroup", it) }
                        put("ts", choice.timestamp)
                    },
                )
            }
        }.toString()

        internal fun decode(raw: String): Map<String, Choice> {
            val root = JSONObject(raw)
            val out = linkedMapOf<String, Choice>()
            val keys = root.keys()
            while (keys.hasNext()) {
                val seriesKey = keys.next()
                val obj = root.getJSONObject(seriesKey)
                val timestamp = obj.getDouble("ts")
                require(timestamp.isFinite())
                val addon = obj.optionalString("addon")
                val bingeGroup = obj.optionalString("bingeGroup")
                out[seriesKey] = Choice(addon, bingeGroup, timestamp)
            }
            return out
        }

        private fun JSONObject.optionalString(key: String): String? =
            if (!has(key) || isNull(key)) null else getString(key)

        private fun appleReferenceSeconds(unixMs: Long): Double =
            unixMs / 1000.0 - APPLE_REFERENCE_UNIX_SECONDS
    }
}

/** Short-lived process memory of providers whose most recent source failed. */
object ProviderHealth {
    const val FAILURE_DECAY_MS = 600_000L
    const val MAX_PROVIDERS = 64

    private val lock = Any()
    private val failures = linkedMapOf<String, Long>()

    fun noteFailure(addonName: String, nowMs: Long = monotonicMs()) {
        val key = normalize(addonName) ?: return
        synchronized(lock) {
            failures[key] = nowMs
            pruneLocked(nowMs)
        }
    }

    fun penaltyActive(addonName: String?, nowMs: Long = monotonicMs()): Boolean {
        val key = normalize(addonName) ?: return false
        return synchronized(lock) {
            val failedAt = failures[key] ?: return@synchronized false
            nowMs - failedAt in 0 until FAILURE_DECAY_MS
        }
    }

    /** Immutable snapshot for an off-thread source-list rank. */
    fun activeAddons(nowMs: Long = monotonicMs()): Set<String> = synchronized(lock) {
        pruneLocked(nowMs)
        failures.keys.toSet()
    }

    internal fun clearForTests() = synchronized(lock) { failures.clear() }

    private fun pruneLocked(nowMs: Long) {
        failures.entries.removeAll { nowMs - it.value !in 0 until FAILURE_DECAY_MS }
        if (failures.size <= MAX_PROVIDERS) return
        failures.entries
            .sortedBy { it.value }
            .take(failures.size - MAX_PROVIDERS)
            .forEach { failures.remove(it.key) }
    }

    private fun normalize(addonName: String?): String? =
        addonName?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }

    private fun monotonicMs(): Long = System.nanoTime() / 1_000_000L
}
