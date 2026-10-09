package com.vortx.android.usenet

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/** One request per ordered provider array: article fallback belongs to Rust, not host-level singletons. */
internal object NativeNzbRouting {
    suspend fun resolve(
        mirrors: List<String>, addonServers: List<String>, savedServers: List<String>,
        confirmedCached: Set<String>?, torBoxConfigured: Boolean,
        timeoutMs: Long = 60_000, isCurrent: () -> Boolean,
        local: suspend (List<String>, List<String>) -> NativeNzbPlayback,
        torBox: suspend (String) -> String?,
    ): NativeNzbPlayback? {
        var retained: NativeNzbPlayback? = null
        var transferred = false
        try {
            val result = withTimeout(timeoutMs) {
                val urls = NativeNzbInputs.mirrors(null, mirrors)
                require(urls.isNotEmpty()) { "NZB mirrors are missing" }
                val addon = NativeNzbInputs.servers(addonServers)
                val saved = NativeNzbInputs.servers(savedServers)
                coroutineScope {
                    val work = async {
                        suspend fun current() {
                            currentCoroutineContext().ensureActive()
                            if (!isCurrent()) throw CancellationException("Usenet playback owner changed")
                        }
                        current()
                        // A positively cached TorBox mirror is an intentional cloud selection; do not start NNTP.
                        val cached = urls.firstOrNull { confirmedCached?.contains(it) == true }
                        if (cached != null && torBoxConfigured) {
                            val result = torBox(cached)
                            current()
                            return@async result?.let { NativeNzbPlayback(it, AutoCloseable {}, isLocal = false) }
                        }
                        var failedLocal = false
                        for (servers in listOf(addon, saved).filter { it.isNotEmpty() }) {
                            current()
                            val value = try { local(urls, servers) }
                            catch (cancel: CancellationException) { throw cancel }
                            catch (_: Exception) { failedLocal = true; continue }
                            retained = value
                            current()
                            return@async value
                        }
                        current()
                        if (torBoxConfigured && (confirmedCached == null || cached != null)) {
                            val result = torBox(cached ?: urls.first())
                            current()
                            return@async result?.let { NativeNzbPlayback(it, AutoCloseable {}, isLocal = false) }
                        }
                        if (failedLocal) throw NativeNzbTransport.Unavailable()
                        null
                    }
                    val monitor = launch {
                        while (isActive) {
                            delay(50)
                            if (!isCurrent()) {
                                work.cancel(CancellationException("Usenet playback owner changed"))
                                return@launch
                            }
                        }
                    }
                    try { work.await() } finally { monitor.cancel() }
                }
            }
            currentCoroutineContext().ensureActive()
            if (!isCurrent()) throw CancellationException("Usenet playback owner changed")
            transferred = true
            return result
        } finally {
            if (!transferred) retained?.lease?.close()
        }
    }
}
