package com.vortx.android.usenet

import com.vortx.android.diagnostics.DiagnosticsLog
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
        timeoutMs: Long = 110_000, isCurrent: () -> Boolean,
        local: suspend (List<String>, List<String>) -> NativeNzbPlayback,
        /** The cloud leg; `allowCreate` false means reuse an existing TorBox job only, never start a download. */
        torBox: suspend (url: String, allowCreate: Boolean) -> String?,
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
                            val result = torBox(cached, true)
                            current()
                            DiagnosticsLog.log("usenet", "route=torbox_cached outcome=${if (result != null) "ready" else "none"}")
                            return@async result?.let { NativeNzbPlayback(it, AutoCloseable {}, isLocal = false) }
                        }
                        var failedLocal = false
                        for ((route, servers) in listOf("addon" to addon, "saved" to saved).filter { it.second.isNotEmpty() }) {
                            current()
                            val value = try { local(urls, servers) }
                            catch (cancel: CancellationException) { throw cancel }
                            catch (error: Exception) {
                                failedLocal = true
                                DiagnosticsLog.log("usenet", "route=$route servers=${servers.size} outcome=failed reason=${
                                    if (error is NativeNzbTransport.SelectionUnmatched) "selection_unmatched" else "unavailable"}")
                                continue
                            }
                            retained = value
                            current()
                            DiagnosticsLog.log("usenet", "route=$route servers=${servers.size} outcome=playing")
                            return@async value
                        }
                        current()
                        if (torBoxConfigured && (confirmedCached == null || cached != null)) {
                            // With their own providers saved, a play never starts a new TorBox download; an
                            // existing or finished TorBox job for this NZB is still used.
                            val allowCreate = saved.isEmpty()
                            val result = torBox(cached ?: urls.first(), allowCreate)
                            current()
                            DiagnosticsLog.log("usenet", "route=torbox allow_create=$allowCreate local_failed=$failedLocal " +
                                "outcome=${if (result != null) "ready" else "none"}")
                            return@async result?.let { NativeNzbPlayback(it, AutoCloseable {}, isLocal = false) }
                        }
                        DiagnosticsLog.log("usenet", "route=none addon_servers=${addon.size} saved_servers=${saved.size} " +
                            "torbox=$torBoxConfigured local_failed=$failedLocal")
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
