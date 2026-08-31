package com.vortx.android.communityjs

import androidx.media3.common.C
import java.io.IOException
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CommunityJsMedia3DataSourceTest {
    @Test
    fun `matching 206 range starts at requested position`() {
        assertEquals(
            CommunityJsMedia3ResponsePlan(skipBytes = 0L, remaining = 12L),
            communityJsMedia3ResponsePlan(
                position = 48L,
                requestedLength = C.LENGTH_UNSET.toLong(),
                responseCode = 206,
                contentRange = "bytes 48-59/60",
                responseLength = 12L,
            ),
        )
    }

    @Test(expected = IOException::class)
    fun `mismatched 206 range fails deterministically`() {
        communityJsMedia3ResponsePlan(
            position = 48L,
            requestedLength = C.LENGTH_UNSET.toLong(),
            responseCode = 206,
            contentRange = "bytes 47-59/60",
            responseLength = 13L,
        )
    }

    @Test
    fun `200 range fallback skips requested position and honors bounded length`() {
        assertEquals(
            CommunityJsMedia3ResponsePlan(skipBytes = 5L, remaining = 3L),
            communityJsMedia3ResponsePlan(
                position = 5L,
                requestedLength = 3L,
                responseCode = 200,
                contentRange = null,
                responseLength = 20L,
            ),
        )
    }

    @Test
    fun `finite early eof throws while unknown response eof remains normal`() {
        assertEquals(C.RESULT_END_OF_INPUT, communityJsMedia3ReadResult(C.RESULT_END_OF_INPUT, C.LENGTH_UNSET.toLong()))
        try {
            communityJsMedia3ReadResult(C.RESULT_END_OF_INPUT, remaining = 1L)
            throw AssertionError("Expected finite response EOF to throw")
        } catch (_: IOException) {
            // Expected: a Content-Length or requested range promises more bytes.
        }
    }

    @Test
    fun `redirect policy and header forwarding retain only safe scoped values`() {
        val root = "https://93.184.216.34/master.m3u8".toHttpUrl()
        val providerHeaders = mapOf("Authorization" to "provider-secret", "X-Provider" to "provider-value")
        val media3Headers = mapOf("Accept" to "video/*", "Range" to "bytes=5-", "X-Drop" to "untrusted")

        assertEquals(
            mapOf("Authorization" to "provider-secret", "X-Provider" to "provider-value", "Accept" to "video/*", "Range" to "bytes=5-"),
            communityJsMedia3RequestHeaders(root, "https://93.184.216.34/segment.ts".toHttpUrl(), providerHeaders, media3Headers),
        )
        assertEquals(
            mapOf("Accept" to "video/*", "Range" to "bytes=5-"),
            communityJsMedia3RequestHeaders(root, "https://8.8.8.8/segment.ts".toHttpUrl(), providerHeaders, media3Headers),
        )
        assertFalse(communityJsMedia3RequestHeaders(root, root, providerHeaders, media3Headers).containsKey("X-Drop"))

        val redirect = CommunityJsHttpPolicy.redirect(root, root, "/segment.ts", 302, "GET", null)
        assertEquals("https://93.184.216.34/segment.ts", redirect?.url?.toString())
        assertEquals("GET", redirect?.method)
        assertNull(CommunityJsHttpPolicy.redirect(root, root, "http://93.184.216.34/segment.ts", 302, "GET", null))
        assertTrue(redirect != null)
    }
}
