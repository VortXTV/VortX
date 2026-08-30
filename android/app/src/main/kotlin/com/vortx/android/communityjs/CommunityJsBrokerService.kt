package com.vortx.android.communityjs

import android.app.Service
import android.content.Intent
import android.os.IBinder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Isolated interpreter process. It has no credentials, encrypted store, or direct network client. */
class CommunityJsBrokerService : Service() {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "community-js-broker").apply { isDaemon = true } }
    private val cancellations = CommunityJsCancellationRegistry()

    private val binder = object : ICommunityJsBroker.Stub() {
        override fun execute(
            token: String,
            code: String,
            tmdbId: String,
            mediaType: String,
            settingsJson: String,
            season: Int,
            episode: Int,
            timeoutMs: Long,
            memoryLimitBytes: Long,
            callback: ICommunityJsBrokerCallback,
        ) {
            if (token.length > 128 || code.toByteArray().size > MAX_SOURCE_BYTES || settingsJson.toByteArray().size > MAX_SETTINGS_BYTES) return
            val cancelledFlag = cancellations.begin(token) ?: return
            executor.execute {
                val host = object : CommunityJsRuntime.NativeFetch {
                    override fun fetch(url: String, optionsJson: String, remainingTimeoutMs: Long): String =
                        runCatching { callback.fetch(token, url, optionsJson, remainingTimeoutMs) }
                            .getOrDefault(EMPTY_RESPONSE)

                    override fun isCancelled(): Boolean = cancelledFlag.get() || runCatching { callback.isCancelled(token) }.getOrDefault(true)
                }
                val envelope = runCatching {
                    CommunityJsNative.evaluate(host, code, tmdbId, mediaType, settingsJson, season, episode, timeoutMs, memoryLimitBytes)
                }.getOrDefault(FAILURE_ENVELOPE)
                cancellations.finish(token, cancelledFlag)
                runCatching { callback.complete(token, envelope) }
            }
        }

        override fun cancel(token: String) {
            cancellations.cancel(token)
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder
    override fun onDestroy() { cancellations.cancelAll(); executor.shutdownNow(); super.onDestroy() }

    private companion object {
        const val MAX_SOURCE_BYTES = 1_000_000
        const val MAX_SETTINGS_BYTES = 64 * 1024
        const val EMPTY_RESPONSE = "{\"status\":0,\"statusText\":\"Unavailable\",\"body\":\"\",\"headers\":{}}"
        const val FAILURE_ENVELOPE = "{\"ok\":false,\"error\":\"Provider execution failed\"}"
    }
}

/**
 * Keeps bounded cancel-before-execute tombstones for the maximum expected Binder reordering horizon.
 * Active invocation flags are a distinct entry type and are never removed by tombstone pruning.
 */
internal class CommunityJsCancellationRegistry(
    private val clockMs: () -> Long = { System.nanoTime() / 1_000_000L },
    private val tombstoneHorizonMs: Long = DEFAULT_TOMBSTONE_HORIZON_MS,
    private val maxTombstones: Int = DEFAULT_MAX_TOMBSTONES,
) {
    private sealed interface Entry {
        data class Active(val flag: AtomicBoolean) : Entry
        data class Tombstone(val createdAtMs: Long, val order: Long) : Entry
    }

    private val lock = Any()
    private val entries = mutableMapOf<String, Entry>()
    private var nextOrder = 0L

    init {
        require(tombstoneHorizonMs >= 0L)
        require(maxTombstones >= 0)
    }

    fun begin(token: String): AtomicBoolean? = synchronized(lock) {
        pruneTombstones(clockMs())
        when (entries[token]) {
            null -> AtomicBoolean(false).also { entries[token] = Entry.Active(it) }
            is Entry.Active, is Entry.Tombstone -> null
        }
    }

    fun cancel(token: String) = synchronized(lock) {
        val now = clockMs()
        pruneTombstones(now)
        when (val entry = entries[token]) {
            is Entry.Active -> entry.flag.set(true)
            is Entry.Tombstone, null -> {
                entries[token] = Entry.Tombstone(now, nextOrder++)
                enforceTombstoneCapacity()
            }
        }
    }

    fun finish(token: String, flag: AtomicBoolean) = synchronized(lock) {
        val entry = entries[token]
        if (entry is Entry.Active && entry.flag === flag) entries.remove(token)
    }

    fun cancelAll() = synchronized(lock) {
        entries.values.forEach { entry -> if (entry is Entry.Active) entry.flag.set(true) }
    }

    internal fun activeCountForTesting(): Int = synchronized(lock) {
        entries.values.count { it is Entry.Active }
    }

    internal fun tombstoneCountForTesting(): Int = synchronized(lock) {
        entries.values.count { it is Entry.Tombstone }
    }

    override fun toString(): String = synchronized(lock) {
        "CommunityJsCancellationRegistry(active=${entries.values.count { it is Entry.Active }}, " +
            "tombstones=${entries.values.count { it is Entry.Tombstone }})"
    }

    private fun pruneTombstones(now: Long) {
        entries.entries.removeAll { (_, entry) ->
            entry is Entry.Tombstone && now >= entry.createdAtMs &&
                now - entry.createdAtMs >= tombstoneHorizonMs
        }
    }

    private fun enforceTombstoneCapacity() {
        val overflow = entries.values.count { it is Entry.Tombstone } - maxTombstones
        if (overflow <= 0) return
        entries.entries.asSequence()
            .mapNotNull { (token, entry) -> (entry as? Entry.Tombstone)?.let { token to it } }
            .sortedWith(compareBy({ it.second.createdAtMs }, { it.second.order }))
            .take(overflow)
            .map { it.first }
            .toList()
            .forEach(entries::remove)
    }

    private companion object {
        const val DEFAULT_TOMBSTONE_HORIZON_MS = 120_000L
        const val DEFAULT_MAX_TOMBSTONES = 1_024
    }
}
