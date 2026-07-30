package com.vortx.android.engine

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

class AddonManifestFetcherTest {
    @Test
    fun privateAndEncodedAddressesAreBlocked() {
        val blocked = listOf(
            "127.0.0.1",
            "2130706433",
            "0.0.0.0",
            "10.0.0.1",
            "100.64.0.1",
            "169.254.169.254",
            "172.16.0.1",
            "192.168.0.1",
            "::1",
            "fc00::1",
            "fe80::1",
            "::ffff:127.0.0.1",
            "64:ff9b::7f00:1",
            "64:ff9b:1::1",
            "100::1",
            "100:0:0:1::1",
            "2001:2::1",
            "2001:db8::1",
            "2002:7f00:0001::",
            "3fff::1",
            "5f00::1",
        )

        blocked.forEach { literal ->
            val result = runCatching { PublicAddressPolicy.requirePublic(literal) }
            assertTrue("$literal must be blocked", result.exceptionOrNull() is UnknownHostException)
        }
    }

    @Test
    fun publicLiteralIsAllowed() {
        val address = PublicAddressPolicy.requirePublic("93.184.216.34")

        assertEquals(listOf(InetAddress.getByName("93.184.216.34")), address)
    }

    @Test
    fun redirectToPrivateHostIsRejectedBeforeSecondRequest() {
        val transport = RecordingTransport(
            listOf(ManifestTransportResponse(302, location = "http://internal.test/manifest.json")),
        )
        val fetcher = AddonManifestFetcher(
            timeoutMs = 1,
            hostValidator = validatorBlocking("internal.test"),
            transport = transport,
        )

        assertNull(fetcher.fetch("https://public.test/manifest.json"))
        assertEquals(listOf("public.test"), transport.requestedHosts)
    }

    @Test
    fun relativePublicRedirectCanReturnManifest() {
        val transport = RecordingTransport(
            listOf(
                ManifestTransportResponse(302, location = "/v2/manifest.json"),
                ManifestTransportResponse(200, body = """{"id":"example","name":"Example"}"""),
            ),
        )
        val fetcher = AddonManifestFetcher(
            timeoutMs = 1,
            hostValidator = {},
            transport = transport,
        )

        val manifest = fetcher.fetch("https://public.test/manifest.json")

        assertNotNull(manifest)
        assertEquals("example", manifest?.getString("id"))
        assertEquals(
            listOf(
                "https://public.test/manifest.json",
                "https://public.test/v2/manifest.json",
            ),
            transport.requestedUrls,
        )
    }

    @Test
    fun invalidManifestIsRejected() {
        val transport = RecordingTransport(
            listOf(ManifestTransportResponse(200, body = """{"id":"missing-name"}""")),
        )
        val fetcher = AddonManifestFetcher(
            timeoutMs = 1,
            hostValidator = {},
            transport = transport,
        )

        assertNull(fetcher.fetch("https://public.test/manifest.json"))
    }

    @Test
    fun manifestClientDisablesSystemProxies() {
        val client = buildAddonManifestClient(1_000)

        assertEquals(Proxy.NO_PROXY, client.proxy)
    }

    @Test
    fun timeoutBudgetIsSharedAcrossRedirects() {
        var now = 0L
        val transport = object : ManifestTransport {
            var calls = 0
            val timeouts = mutableListOf<Long>()

            override fun execute(url: HttpUrl, timeoutMs: Long): ManifestTransportResponse {
                calls += 1
                timeouts += timeoutMs
                now += TimeUnit.MILLISECONDS.toNanos(600)
                return ManifestTransportResponse(302, location = "/hop-$calls")
            }
        }
        val fetcher = AddonManifestFetcher(
            timeoutMs = 1_000,
            hostValidator = {},
            transport = transport,
            nanoTime = { now },
        )

        assertNull(fetcher.fetch("https://public.test/manifest.json"))
        assertEquals(2, transport.calls)
        assertEquals(listOf(1_000L, 400L), transport.timeouts)
    }

    private fun validatorBlocking(blockedHost: String): (String) -> Unit = { host ->
        if (host == blockedHost) throw UnknownHostException("blocked")
    }

    private class RecordingTransport(
        responses: List<ManifestTransportResponse>,
    ) : ManifestTransport {
        private val remaining = ArrayDeque(responses)
        val requestedUrls = mutableListOf<String>()
        val requestedHosts: List<String>
            get() = requestedUrls.map { it.toHttpUrl().host }

        override fun execute(url: HttpUrl, timeoutMs: Long): ManifestTransportResponse {
            requestedUrls += url.toString()
            return remaining.removeFirst()
        }
    }
}
