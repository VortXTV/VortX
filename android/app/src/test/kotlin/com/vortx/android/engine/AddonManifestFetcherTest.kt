package com.vortx.android.engine

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.UnknownHostException

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
            "2002:7f00:0001::",
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

        override fun execute(url: HttpUrl): ManifestTransportResponse {
            requestedUrls += url.toString()
            return remaining.removeFirst()
        }
    }
}
