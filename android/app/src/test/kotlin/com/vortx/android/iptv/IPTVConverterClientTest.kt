package com.vortx.android.iptv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Request-shape + result-mapping tests for [IPTVConverterClient]. These target the PURE seams
/// ([IPTVConverterClient.registerBodyM3U] / [IPTVConverterClient.registerBodyXtream] /
/// [IPTVConverterClient.revokePath] / [IPTVConverterClient.mapRegisterResult]), so they need no network and
/// no `org.json` on the classpath: they assert the request body the client would send matches the Apple
/// `IPTVConverterClient` byte-for-byte (same keys, same nesting, same omission rules) and that the worker
/// response is mapped to the same typed result.
class IPTVConverterClientTest {

    // ---- M3U request shape ----

    @Test
    fun `m3u body carries only m3u_url when no epg or name`() {
        val body = IPTVConverterClient.registerBodyM3U("https://p.example/pl.m3u", xmltvUrl = null, name = null)
        assertEquals(setOf("m3u_url"), body.keys)
        assertEquals("https://p.example/pl.m3u", body["m3u_url"])
    }

    @Test
    fun `m3u body adds xmltv_url and name only when non-empty`() {
        val body = IPTVConverterClient.registerBodyM3U(
            url = "https://p.example/pl.m3u",
            xmltvUrl = "https://p.example/xmltv.php",
            name = "My IPTV",
        )
        assertEquals("https://p.example/pl.m3u", body["m3u_url"])
        assertEquals("https://p.example/xmltv.php", body["xmltv_url"])
        assertEquals("My IPTV", body["name"])
    }

    @Test
    fun `m3u body omits blank xmltv_url and name`() {
        val body = IPTVConverterClient.registerBodyM3U("https://p.example/pl.m3u", xmltvUrl = "", name = "")
        assertFalse(body.containsKey("xmltv_url"))
        assertFalse(body.containsKey("name"))
    }

    // ---- Xtream request shape ----

    @Test
    fun `xtream body nests host user pass under xtream`() {
        val body = IPTVConverterClient.registerBodyXtream(
            host = "http://panel.example.com:8080",
            user = "alice",
            pass = "s3cret",
            xmltvUrl = null,
            name = null,
        )
        assertEquals(setOf("xtream"), body.keys)
        @Suppress("UNCHECKED_CAST")
        val xtream = body["xtream"] as Map<String, Any?>
        assertEquals("http://panel.example.com:8080", xtream["host"])
        assertEquals("alice", xtream["user"])
        assertEquals("s3cret", xtream["pass"])
    }

    @Test
    fun `xtream body adds xmltv_url and name alongside the nested login`() {
        val body = IPTVConverterClient.registerBodyXtream(
            host = "http://panel.example.com:8080",
            user = "alice",
            pass = "s3cret",
            xmltvUrl = "https://p.example/xmltv.php",
            name = "Living room",
        )
        assertEquals("https://p.example/xmltv.php", body["xmltv_url"])
        assertEquals("Living room", body["name"])
        assertTrue(body["xtream"] is Map<*, *>)
    }

    // ---- Paths ----

    @Test
    fun `register path matches the worker route`() {
        assertEquals("register", IPTVConverterClient.REGISTER_PATH)
    }

    @Test
    fun `revoke path is c slug revoke`() {
        assertEquals("c/abc123/revoke", IPTVConverterClient.revokePath("abc123"))
    }

    // ---- Result mapping ----

    @Test
    fun `transport failure maps to network error`() {
        val result = IPTVConverterClient.mapRegisterResult(status = 0, slug = null, manifestUrl = null, errorCode = null)
        assertTrue(result.isFailure)
        assertTrue(result.exceptionOrNull() is IPTVConverterClient.ClientError.Network)
    }

    @Test
    fun `2xx with slug and manifest maps to success`() {
        val result = IPTVConverterClient.mapRegisterResult(
            status = 200,
            slug = "slug1",
            manifestUrl = "https://iptv.vortx.tv/c/slug1/manifest.json",
            errorCode = null,
        )
        assertTrue(result.isSuccess)
        val reg = result.getOrNull()
        assertEquals("slug1", reg?.slug)
        assertEquals("https://iptv.vortx.tv/c/slug1/manifest.json", reg?.manifestUrl)
    }

    @Test
    fun `2xx spanning the whole success range still maps to success`() {
        val result = IPTVConverterClient.mapRegisterResult(299, "s", "https://iptv.vortx.tv/c/s/manifest.json", null)
        assertTrue(result.isSuccess)
    }

    @Test
    fun `2xx missing slug maps to bad response`() {
        val result = IPTVConverterClient.mapRegisterResult(200, slug = null, manifestUrl = "https://m", errorCode = null)
        assertTrue(result.isFailure)
        assertTrue(result.exceptionOrNull() is IPTVConverterClient.ClientError.BadResponse)
        assertNull(result.getOrNull())
    }

    @Test
    fun `2xx missing manifest maps to bad response`() {
        val result = IPTVConverterClient.mapRegisterResult(200, slug = "s", manifestUrl = null, errorCode = null)
        assertTrue(result.exceptionOrNull() is IPTVConverterClient.ClientError.BadResponse)
    }

    @Test
    fun `xtream_auth_failed code maps to the friendly xtream error`() {
        val result = IPTVConverterClient.mapRegisterResult(400, slug = null, manifestUrl = null, errorCode = "xtream_auth_failed")
        assertTrue(result.exceptionOrNull() is IPTVConverterClient.ClientError.XtreamAuthFailed)
    }

    @Test
    fun `other error code maps to server error carrying the code`() {
        val result = IPTVConverterClient.mapRegisterResult(500, slug = null, manifestUrl = null, errorCode = "playlist_unreachable")
        val error = result.exceptionOrNull()
        assertTrue(error is IPTVConverterClient.ClientError.Server)
        assertEquals("playlist_unreachable", (error as IPTVConverterClient.ClientError.Server).code)
    }

    @Test
    fun `non-2xx with no error code falls back to the raw status`() {
        val result = IPTVConverterClient.mapRegisterResult(503, slug = null, manifestUrl = null, errorCode = null)
        val error = result.exceptionOrNull()
        assertTrue(error is IPTVConverterClient.ClientError.Server)
        assertEquals("503", (error as IPTVConverterClient.ClientError.Server).code)
    }
}
