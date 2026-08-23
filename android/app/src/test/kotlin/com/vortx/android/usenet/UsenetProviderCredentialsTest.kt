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
    fun `isValid rejects empty host login or out-of-range numbers`() {
        assertTrue(
            !UsenetProviderCredentials("", 563, "u", "p", 4, true).isValid,
        )
        assertTrue(!UsenetProviderCredentials("h", 0, "u", "p", 4, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "", "p", 4, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "u", "", 4, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "u", "p", 0, true).isValid)
        assertTrue(!UsenetProviderCredentials("h", 563, "u", "p", 101, true).isValid)
        assertTrue(UsenetProviderCredentials("h", 563, "u", "p", 4, false).isValid)
    }

    @Test
    fun `nntpServerURL percent-encodes separators in user and pass`() {
        val credentials = UsenetProviderCredentials(
            host = "news.example.com",
            port = 119,
            username = "a:b",
            password = "p@ss/w",
            maxConnections = 4,
            useSSL = false,
        )
        val url = credentials.nntpServerURL
        assertTrue(url.startsWith("nntp://a%3Ab:p%40ss%2Fw@news.example.com:119/4"))
        // Exactly one userinfo separator and one path separator outside encoded content.
        assertEquals(1, url.count { it == '@' })
    }

    @Test
    fun `fromJson of garbage yields an INVALID provider not a throw`() {
        val parsed = UsenetProviderCredentials.fromJson(org.json.JSONObject("""{"nope":1}"""))
        assertTrue(parsed == null || !parsed.isValid)
    }
}
