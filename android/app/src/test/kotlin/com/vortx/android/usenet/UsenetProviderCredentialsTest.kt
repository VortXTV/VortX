package com.vortx.android.usenet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// Round-trip tests for [UsenetProviderCredentials] JSON (org.json ships with the platform and with
/// the JVM unit-test classpath via the jsonJvm dependency).
class UsenetProviderCredentialsTest {

    @Test
    fun `json round-trip preserves every field`() {
        val original = UsenetProviderCredentials(
            host = "news.example.com",
            port = 563,
            username = "user",
            password = "secret",
            maxConnections = 8,
            useSSL = true,
        )

        val restored = UsenetProviderCredentials.fromJson(original.toJson())

        assertEquals(original, restored)
        assertTrue(restored != null)
    }

    @Test
    fun `isValid rejects empty host login plaintext transport or out-of-range numbers`() {
        assertTrue(
            !UsenetProviderCredentials("", 563, "u", "p", 4, true).isValid,
        )
        assertTrue(!UsenetProviderCredentials("h", 0, "u", "p", 4, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "", "p", 4, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "u", "", 4, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "u", "p", 0, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "u", "p", 101, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "u", "p", 4, false).isValid)
    }

    @Test
    fun `endpoint never includes credential material`() {
        val credentials = UsenetProviderCredentials(
            host = "news.example.com",
            port = 119,
            username = "a:b",
            password = "p@ss/w",
            maxConnections = 4,
            useSSL = false,
        )
        val endpoint = credentials.nntpEndpoint
        assertEquals("nntp://news.example.com:119/4", endpoint)
        assertTrue("a:b" !in endpoint && "p@ss/w" !in endpoint)
        assertTrue("p@ss/w" !in credentials.toString())
    }

    @Test
    fun `fromJson of garbage yields an INVALID provider not a throw`() {
        val parsed = UsenetProviderCredentials.fromJson(org.json.JSONObject("""{"nope":1}"""))
        assertTrue(parsed == null || !parsed.isValid)
    }
}
