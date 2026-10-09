package com.vortx.android.usenet

import com.vortx.android.debrid.DebridCoordinator
import com.vortx.android.engine.EngineState
import com.vortx.android.engine.usenetResolveTarget
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeNzbInputsTest {
    private fun stream(value: JSONObject) = EngineState.parseStreamGroups(JSONObject().put("streams", JSONArray()
        .put(JSONObject().put("request", JSONObject().put("base", "https://addon.invalid/manifest.json"))
            .put("content", JSONObject().put("type", "Ready").put("content", JSONArray().put(value))))).toString()).single().streams.single()

    @Test fun `plural-only source is Usenet and preserves raw ordered credentials and mirrors`() {
        val urls = listOf("https://one.invalid/API?Key=SeCrEt", "https://two.invalid/config%2Ftoken/file.nzb")
        val servers = listOf("nntps://user%40host:p%3Ass+word@one.invalid:563/12", "nntp://two.invalid:119/4")
        val source = stream(JSONObject().put("nzbUrls", JSONArray(urls)).put("servers", JSONArray(servers)).put("infoHash", "not-a-torrent"))
        assertTrue(source.isUsenet); assertFalse(source.isTorrent)
        assertEquals(urls, source.usenetUrls); assertEquals(servers, source.usenetServers)
        val target = source.usenetResolveTarget(null)
        assertEquals(urls, target.nzbUrls); assertEquals(servers, target.servers)
        val candidate = DebridCoordinator.DebridCandidate(source = source)
        assertEquals(urls, candidate.usenetUrls); assertEquals(servers, candidate.orderedUsenetServers)
        for (value in listOf(source, target, candidate)) {
            assertFalse(value.toString().contains("SeCrEt")); assertFalse(value.toString().contains("p%3Ass"))
        }
    }

    @Test fun `single locator remains first without duplicate mirror and direct URL stays direct`() {
        val source = stream(JSONObject().put("url", "https://direct.invalid/media")
            .put("nzbUrl", "https://one.invalid/nzb").put("nzbUrls", JSONArray(listOf("https://two.invalid/nzb", "https://one.invalid/nzb"))))
        assertEquals(listOf("https://one.invalid/nzb", "https://two.invalid/nzb"), source.usenetUrls)
        assertFalse(source.isUsenet)
    }

    @Test fun `malformed and oversized transport arrays fail without credential diagnostics or truncation`() {
        for (servers in listOf(List(17) { "nntps://u:SECRET@provider.invalid:563/4" },
            listOf("https://u:SECRET@provider.invalid/4"), listOf("nntps://u:SECRET@provider.invalid/0"),
            listOf("nntps://u:SECRET%0A@provider.invalid/4"), listOf("nntps://u:SECRET%FF@provider.invalid/4"))) {
            try { NativeNzbInputs.servers(servers); fail("Invalid servers accepted") }
            catch (e: IllegalArgumentException) { assertFalse(e.toString().contains("SECRET")); assertNull(e.cause) }
        }
        assertThrows(IllegalArgumentException::class.java) { NativeNzbInputs.mirrors(null, List(9) { "https://example.invalid/$it" }) }
        assertThrows(IllegalArgumentException::class.java) { NativeNzbInputs.mirrors("https://u:SECRET@example.invalid/nzb", emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { NativeNzbInputs.strings(JSONObject().put("servers", JSONArray().put(42)), "servers") }
    }

    @Test fun `all sixteen enabled saved providers encoded in order without storing URLs`() {
        val saved = (1..16).map { UsenetProviderServer(id = "$it", name = "Fixture", host = "server$it.invalid", port = 563,
            username = "user@name", password = "pass:+ /", maxConnections = it, useSSL = true) }
        val urls = NativeNzbInputs.saved(saved)
        assertEquals(16, urls.size)
        assertEquals("nntps://user%40name:pass%3A%2B%20%2F@server1.invalid:563/1", urls.first())
        assertTrue(urls.last().endsWith("@server16.invalid:563/16"))
        assertEquals(15, NativeNzbInputs.saved(saved.mapIndexed { index, value -> value.copy(enabled = index != 0) }).size)
    }
}
