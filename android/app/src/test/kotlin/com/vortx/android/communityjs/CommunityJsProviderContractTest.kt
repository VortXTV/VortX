package com.vortx.android.communityjs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.Job

class CommunityJsProviderContractTest {
    @Test
    fun fixtureProviderMapsASelectableDirectSourceWithHeadersAndSubtitles() {
        val provider = CommunityJsProviderStore.Provider(
            id = "fixture",
            name = "Fixture provider",
            supportedTypes = setOf("movie"),
            code = "module.exports.getStreams = () => []",
            enabled = true,
        )
        val group = CommunityJsProviderSource.mapGroup(
            provider,
            listOf(
                CommunityJsRuntime.ProviderStream(
                    name = "Fixture source",
                    title = "Example feature",
                    url = "https://93.184.216.34/media.m3u8",
                    quality = "1080p",
                    size = "1.2 GB",
                    headers = mapOf("Referer" to "https://93.184.216.34/"),
                    subtitles = listOf(CommunityJsRuntime.Subtitle("https://93.184.216.34/sub.vtt", "en", "English", emptyMap())),
                ),
            ),
        )

        assertNotNull(group)
        val stream = requireNotNull(group).streams.single()
        assertEquals("1080p", stream.quality)
        assertEquals("https://93.184.216.34/media.m3u8", stream.url)
        assertEquals("https://93.184.216.34/", stream.requestHeaders["Referer"])
        assertEquals(listOf("https://93.184.216.34/sub.vtt"), stream.externalSubtitles)
    }

    @Test
    fun networkPolicyRejectsLocalTargetsAndAcceptsAPublicLiteral() {
        assertFalse(CommunityJsUrlPolicy.isPublicHttpUrl("http://127.0.0.1:8080/stream"))
        assertFalse(CommunityJsUrlPolicy.isPublicHttpUrl("http://192.168.1.10/stream"))
        assertFalse(CommunityJsUrlPolicy.isPublicHttpsUrl("https://localhost/manifest.json"))
        assertTrue(CommunityJsUrlPolicy.isPublicHttpUrl("https://93.184.216.34/stream"))
    }

    @Test
    fun `refresh replacement cancels the prior provider invocation deterministically`() {
        val owner = CommunityJsRefreshJobOwner()
        val first = Job()
        val second = Job()

        owner.replace(first)
        owner.replace(second)

        assertTrue(first.isCancelled)
        assertFalse(second.isCancelled)
        owner.cancel()
        assertTrue(second.isCancelled)
    }

    @Test
    fun `new generation fences stale provider publication`() {
        val fence = CommunityJsGenerationFence()
        fence.begin(41)
        fence.begin(42)

        assertFalse(fence.publishIfCurrent(41) { error("stale request published") })
        assertTrue(fence.publishIfCurrent(42) {})
        fence.invalidate()
        assertFalse(fence.publishIfCurrent(42) { error("invalidated request published") })
    }
}
