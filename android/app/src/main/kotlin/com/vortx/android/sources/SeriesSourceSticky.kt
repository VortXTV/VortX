package com.vortx.android.sources

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.MainThread
import com.vortx.android.profile.ProfileStore
import org.json.JSONObject

/**
 * Remembers the source a viewer selected by hand for a series. The record is a ranking preference, never a
 * playback lock: a later episode may still fall through to any other provider when the remembered one is absent
 * or unhealthy. Storage uses the same per-profile key and JSON shape as Apple.
 */
class SeriesSourceSticky(
    context: Context,
    private val activeProfileId: () -> String = {
        ProfileStore.sharedOrNull()?.activeProfileId ?: DEFAULT_PROFILE
    },
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    data class Preference(val addon: String?, val bingeGroup: String?)

    internal data class Choice(
        val addon: String?,
        val bingeGroup: String?,
        val timestamp: Double,
    ) {
        fun preference(): Preference = Preference(addon, bingeGroup)
    }

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
    private val lock = Any()
    private var cachedProfile: String? = null
    private var cache: Map<String, Choice>? = null

    /** Record only explicit viewer picks. Automatic selection and failover callers must never call this. */
    @MainThread
    fun record(seriesKey: String, addon: String?, bingeGroup: String?) {
        if (seriesKey.isBlank() || (addon.isNullOrBlank() && bingeGroup.isNullOrBlank())) return
        val loaded = loaded()
        val updated = loaded.second.toMutableMap().apply {
            put(
                seriesKey,
                Choice(
                    addon = addon?.takeIf { it.isNotBlank() },
                    bingeGroup = bingeGroup?.takeIf { it.isNotBlank() },
                    timestamp = appleReferenceSeconds(nowMs()),
                ),
            )
        }
        val pruned = prune(updated)
        synchronized(lock) {
            cachedProfile = loaded.first
            cache = pruned
        }
        prefs.edit().putString(storageKey(loaded.first), encode(pruned)).apply()
        // Deliberately no StreamRanking.invalidateCaches(): stickiness is applied outside the score memo.
    }

    /** Thread-safe read; callers snapshot the immutable result before an off-thread rank pass. */
    fun preference(seriesKey: String): Preference? {
        if (seriesKey.isBlank()) return null
        return loaded().second[seriesKey]?.preference()
    }

    private fun loaded(): Pair<String, Map<String, Choice>> {
        val profile = activeProfileId().ifBlank { DEFAULT_PROFILE }
        synchronized(lock) {
            if (cachedProfile == profile) cache?.let { return profile to it }
        }

        val raw = prefs.getString(storageKey(profile), null)
        val decoded = if (raw == null) {
            emptyMap()
        } else {
            runCatching { decode(raw) }.getOrElse {
                quarantineOnce(profile, raw)
                emptyMap()
            }
        }
        synchronized(lock) {
            cachedProfile = profile
            cache = decoded
        }
        return profile to decoded
    }

    private fun quarantineOnce(profile: String, raw: String) {
        val key = storageKey(profile) + QUARANTINE_SUFFIX
        if (!prefs.contains(key)) prefs.edit().putString(key, raw).apply()
    }

    internal companion object {
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
