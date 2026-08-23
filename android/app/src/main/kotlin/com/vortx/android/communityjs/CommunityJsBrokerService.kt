package com.vortx.android.communityjs

import android.app.Service
import android.content.Intent
import android.os.IBinder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Isolated interpreter process. It has no credentials, encrypted store, or direct network client. */
class CommunityJsBrokerService : Service() {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "community-js-broker").apply { isDaemon = true } }
    private val cancelled = ConcurrentHashMap<String, AtomicBoolean>()

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
            val cancelledFlag = AtomicBoolean(false)
            cancelled[token] = cancelledFlag
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
                cancelled.remove(token)
                runCatching { callback.complete(token, envelope) }
            }
        }

        override fun cancel(token: String) {
            cancelled[token]?.set(true)
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder
    override fun onDestroy() { cancelled.values.forEach { it.set(true) }; executor.shutdownNow(); super.onDestroy() }

    private companion object {
        const val MAX_SOURCE_BYTES = 1_000_000
        const val MAX_SETTINGS_BYTES = 64 * 1024
        const val EMPTY_RESPONSE = "{\"status\":0,\"statusText\":\"Unavailable\",\"body\":\"\",\"headers\":{}}"
        const val FAILURE_ENVELOPE = "{\"ok\":false,\"error\":\"Provider execution failed\"}"
    }
}
