package com.vortx.android.trickplay

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TmdbImdbResolverCancellationTest {

    @Test
    fun `cancelling a resolver request disconnects blocked HTTP I O`() = runBlocking {
        val control = CommunityTrickplayRequestControl()
        val connection = BlockingConnection()
        val result = async {
            TmdbImdbResolver.fetchExternalImdbId(
                media = "movie",
                tmdbId = "42",
                requestControl = control,
                openConnection = { connection },
            )
        }

        withTimeout(2_000L) { connection.responseStarted.await() }
        control.cancel()

        assertEquals(TmdbImdbResolution.TransportFailure, withTimeout(2_000L) { result.await() })
        assertTrue(connection.disconnected)
    }

    private class BlockingConnection : HttpURLConnection(URL("https://example.invalid")) {
        val responseStarted = CompletableDeferred<Unit>()
        private val release = CompletableDeferred<Unit>()
        var disconnected = false

        override fun getResponseCode(): Int = runBlocking {
            responseStarted.complete(Unit)
            release.await()
            throw IOException("disconnected")
        }

        override fun disconnect() {
            disconnected = true
            release.complete(Unit)
        }

        override fun usingProxy(): Boolean = false

        override fun connect() = Unit
    }
}
