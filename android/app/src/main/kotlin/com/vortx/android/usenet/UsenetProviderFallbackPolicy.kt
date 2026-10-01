package com.vortx.android.usenet

import kotlinx.coroutines.CancellationException

/** Pure sequential fallback policy: priority order, cancellation propagation, and no disabled attempts. */
internal object UsenetProviderFallbackPolicy {
    class NoEnabledProviders : IllegalStateException("No enabled Usenet servers are configured")
    class AllProvidersFailed(val attemptedIds: List<String>, cause: Throwable?) :
        IllegalStateException("All configured Usenet servers failed readiness", cause)

    suspend fun <T> firstReady(
        servers: List<UsenetProviderServer>,
        stillCurrent: () -> Boolean,
        attempt: suspend (UsenetProviderServer) -> T,
    ): T {
        val enabled = servers.filter { it.enabled }
        if (enabled.isEmpty()) throw NoEnabledProviders()
        var lastError: Throwable? = null
        val attempted = mutableListOf<String>()
        for (server in enabled) {
            if (!stillCurrent()) throw CancellationException("Usenet owner or configuration changed")
            attempted += server.id
            try {
                val value = attempt(server)
                if (!stillCurrent()) throw CancellationException("Usenet owner or configuration changed")
                return value
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: Throwable) {
                lastError = failure
            }
        }
        throw AllProvidersFailed(attempted, lastError)
    }
}
