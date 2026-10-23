package com.vortx.android.engine

import com.vortx.android.sync.VortXSyncDoc
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject
import java.net.UnknownHostException

class AddonSelfHostedPolicyTest {
    @Test
    fun restoredPrivateDescriptorsRetainUnknownFields() {
        for (host in listOf("192.168.50.20", "100.64.1.2", "[fd7a:115c:a1e0::1]")) {
            val url = "https://$host/manifest.json"
            val raw = JSONObject().put("transportUrl", url)
                .put("manifest", JSONObject().put("id", "local").put("name", "Local").put("futureField", "kept"))
            val restored = VortXSyncDoc.addonDescriptor(raw)
            assertNotNull(url, restored)
            assertEquals("kept", restored!!.raw.getJSONObject("manifest").getString("futureField"))
        }
        for (host in listOf("169.254.169.254", "100.100.100.200", "[fd00:ec2::254]")) {
            val raw = JSONObject().put("transportUrl", "http://$host/manifest.json")
                .put("manifest", JSONObject().put("id", "bad").put("name", "Bad"))
            assertNull(VortXSyncDoc.addonDescriptor(raw))
        }
    }

    @Test
    fun chosenLocalAndTailnetOriginsInstallWithoutWeakeningPublicPolicy() {
        val origins = listOf(
            "http://127.0.0.1:7000/manifest.json",
            "http://10.1.2.3:7000/manifest.json",
            "http://172.16.0.2/manifest.json",
            "http://192.168.50.2/manifest.json",
            "https://100.64.1.2/manifest.json",
            "http://[::1]:7000/manifest.json",
            "https://[fd7a:115c:a1e0::1234]/manifest.json",
            "http://[64:ff9b::a01:203]/manifest.json",
        )
        for (origin in origins) {
            val received = mutableListOf<HttpUrl>()
            val transport = object : ManifestTransport {
                override fun execute(url: HttpUrl, timeoutMs: Long): ManifestTransportResponse =
                    error("Fetcher must forward the selected origin")
                override fun executeAddon(url: HttpUrl, timeoutMs: Long, origin: HttpUrl): ManifestTransportResponse {
                    received += origin
                    return ManifestTransportResponse(200, body = """{"id":"local","name":"Local"}""")
                }
            }
            assertNotNull(origin, AddonManifestFetcher(1_000, transport = transport).fetch(origin))
            assertEquals(listOf(origin.toHttpUrl()), received)
            assertTrue("Public policy still rejects ${origin.toHttpUrl().host}",
                runCatching { PublicAddressPolicy.requirePublic(origin.toHttpUrl().host) }
                    .exceptionOrNull() is UnknownHostException)
        }
    }

    @Test
    fun sameOriginRelativeRedirectKeepsPrivateEndpoint() {
        val urls = mutableListOf<String>()
        val fetcher = AddonManifestFetcher(1_000, transport = ManifestTransport { url, _ ->
            urls += url.toString()
            if (urls.size == 1) ManifestTransportResponse(302, location = "/v2/manifest.json")
            else ManifestTransportResponse(200, body = """{"id":"local","name":"Local"}""")
        })
        assertNotNull(fetcher.fetch("https://100.64.1.2/manifest.json"))
        assertEquals(listOf("https://100.64.1.2/manifest.json", "https://100.64.1.2/v2/manifest.json"), urls)
    }

    @Test
    fun changedPrivateHostPortOrSchemeIsRejectedBeforeTransport() {
        for (redirect in listOf(
            "https://100.64.1.3/manifest.json",
            "https://100.64.1.2:8443/manifest.json",
            "http://100.64.1.2/manifest.json",
        )) {
            var requests = 0
            val fetcher = AddonManifestFetcher(1_000, transport = ManifestTransport { _, _ ->
                requests++
                ManifestTransportResponse(302, location = redirect)
            })
            assertNull(redirect, fetcher.fetch("https://100.64.1.2/manifest.json"))
            assertEquals(1, requests)
        }
    }

    @Test
    fun metadataLinkLocalUnspecifiedAndMulticastRemainBlocked() {
        val urls = listOf(
            "http://0.0.0.0/manifest.json",
            "http://169.254.169.254/manifest.json",
            "http://100.100.100.200/manifest.json",
            "http://224.0.0.1/manifest.json",
            "http://[::]/manifest.json",
            "http://[fe80::1]/manifest.json",
            "http://[fd00:ec2::254]/manifest.json",
            "http://[::ffff:100.100.100.200]/manifest.json",
            "http://[64:ff9b::6464:64c8]/manifest.json",
        )
        var requests = 0
        val fetcher = AddonManifestFetcher(1_000, transport = ManifestTransport { _, _ ->
            requests++
            ManifestTransportResponse(200, body = """{"id":"bad","name":"Bad"}""")
        })
        urls.forEach { assertNull(it, fetcher.fetch(it)) }
        assertEquals(0, requests)
    }
}
