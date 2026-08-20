package com.vortx.android.communityjs

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CommunityJsBrokerInstrumentationTest {
    @Test
    fun commonJsPromiseCompletesInIsolatedBroker() = runBlocking {
        val runtime = CommunityJsRuntime(InstrumentationRegistry.getInstrumentation().targetContext, timeoutMs = 5_000)
        val provider = CommunityJsProviderStore.Provider(
            id = "fixture",
            name = "Fixture",
            supportedTypes = setOf("movie"),
            code = """
                const crypto = require('crypto-js');
                module.exports.getStreams = async (id, type) => {
                  await Promise.resolve();
                  if (crypto.SHA256('x').toString() !== 'x') throw new Error('crypto contract');
                  return [{
                    name: 'Málaga', title: type + '-' + id,
                    url: 'https://93.184.216.34/video.m3u8', quality: '1080p', size: '42',
                    headers: {Referer: 'https://93.184.216.34/'},
                    subtitles: [{url: 'https://93.184.216.34/sub.vtt', language: 'es'}]
                  }];
                };
            """.trimIndent(),
            enabled = true,
        )

        val result = runtime.execute(CommunityJsRuntime.Invocation(provider, "123", "movie", null, null))

        assertTrue(result is CommunityJsRuntime.Result.Success)
        val stream = (result as CommunityJsRuntime.Result.Success).streams.single()
        assertEquals("Málaga", stream.name)
        assertEquals("movie-123", stream.title)
        assertEquals("1080p", stream.quality)
        assertEquals("es", stream.subtitles.single().language)
    }

    @Test
    fun synchronousLoopIsInterrupted() = runBlocking {
        val runtime = CommunityJsRuntime(InstrumentationRegistry.getInstrumentation().targetContext, timeoutMs = 300)
        val provider = CommunityJsProviderStore.Provider(
            id = "loop", name = "Loop", supportedTypes = setOf("movie"),
            code = "module.exports.getStreams = () => { while (true) {} };",
            enabled = true,
        )

        val started = android.os.SystemClock.elapsedRealtime()
        val result = runtime.execute(CommunityJsRuntime.Invocation(provider, "123", "movie", null, null))
        val elapsed = android.os.SystemClock.elapsedRealtime() - started

        assertTrue(result is CommunityJsRuntime.Result.Failure)
        assertTrue("interruption should be bounded, was $elapsed ms", elapsed < 5_000)
    }

    @Test
    fun cancellationInterruptsARunningBrokerInvocation() = runBlocking {
        val runtime = CommunityJsRuntime(InstrumentationRegistry.getInstrumentation().targetContext, timeoutMs = 5_000)
        val provider = CommunityJsProviderStore.Provider(
            id = "cancel", name = "Cancel", supportedTypes = setOf("movie"),
            code = "module.exports.getStreams = () => { while (true) {} };",
            enabled = true,
        )
        val invocation = async { runtime.execute(CommunityJsRuntime.Invocation(provider, "123", "movie", null, null)) }

        delay(100)
        invocation.cancel()
        invocation.join()

        assertTrue(invocation.isCancelled)
    }
}
