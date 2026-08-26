package com.vortx.android.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URL
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * SEC-05 boundary contract for the Android edge-auth helper (local JVM suite).
 *
 * WHAT THIS LOCKS IN (mirrors Apple app/Tests/EdgeAuthBoundaryTests.swift):
 *  1. The shared client HMAC is abuse-friction/attribution telemetry ONLY: in an UNPROVISIONED build
 *     (the unit-test context resolves no VORTX_EDGE_SECRET field, so the secret is "") every endpoint
 *     degrades safely: header signing stamps the observe-mode empty-key shape, query signing fails open,
 *     non-gated hosts are never touched. Nothing treats possession of the secret as privilege.
 *  2. The provisioning pipeline is total: absent/malformed/placeholder blobs collapse to "" (never
 *     sign-with-garbage) and maskedValue <-> deMaskedSecret round-trip exactly, byte-for-byte with
 *     Apple (golden blobs below were generated from the Swift implementation).
 *  3. Layer separation: NO short-lived-token (MOAT/X-VX-Moat) machinery lives here; privileged
 *     authorization stays with the server-issued token seam (MoatToken + api.vortx.tv issuer +
 *     worker moat_auth.ts), never with this shared secret.
 *
 * NOTE: the strict empty-key signature assertions double as a provisioning tripwire. If a build later
 * injects a real VORTX_EDGE_SECRET BuildConfig field, these JVM tests resolve a NON-empty secret and the
 * equality checks will fail by design; update them to the provisioned contract deliberately, never
 * silently.
 */
class VortXEdgeAuthTest {

    // Golden MASKED blobs generated from the Apple implementation (same mask fragments on both platforms).
    private val goldenVector1 = "abababababababababababababababababababababababababababababababab"
    private val goldenMasked1 =
        "yP+3xKu8K3gLyoMaawgbAJeQ96DPmPf0GBMcNxITA1jI/7fEq7wreAvKgxprCBsAl5D3oM+Y9/QYExw3EhMDWA=="
    private val goldenVector2 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private val goldenMasked2 =
        "mazklf7rfC1SkYMaaQ4fBMbDpPGaz6ChQUgcNxAVB1yZrOSV/ut8LVKRgxppDh8ExsOk8ZrPoKFBSBw3EBUHXA=="

    /** Independent HMAC-SHA256 with an EMPTY key (JCE needs the standard 64-byte zero-padded block). */
    private fun hmacEmptyKeyHex(message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(ByteArray(64), "HmacSHA256"))
        return mac.doFinal(message.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    @Test
    fun nonGatedHostsAreNeverStamped() {
        assertNull(VortXEdgeAuth.signingHeaders("GET", URL("https://api.vortx.tv/v1/sync")))
        assertNull(VortXEdgeAuth.signingHeaders("GET", URL("https://example.com/logo.png")))
        assertNull(VortXEdgeAuth.signingHeaders("POST", URL("https://api.trakt.tv/oauth/token")))
    }

    @Test
    fun observeModeHeaderShapeMatchesWorkerContract() {
        val headers = VortXEdgeAuth.signingHeaders(
            "get",
            URL("https://skip.vortx.tv/skip?ids=a,b"),
        ) ?: throw AssertionError("gated host must be stamped")

        assertEquals("k1", headers.kid)
        val nowSec = System.currentTimeMillis() / 1000L
        assertTrue("ts is unix seconds inside the skew window", headers.ts.toLong() in (nowSec - 300)..(nowSec + 300))
        assertTrue("sig is 64 lowercase hex", headers.sig.length == 64 && headers.sig == headers.sig.lowercase())
        assertEquals(
            "empty-key signature matches METHOD\\npath\\nts",
            hmacEmptyKeyHex("GET\n/skip\n${headers.ts}"),
            headers.sig,
        )
    }

    @Test
    fun signedPathStaysPercentEncodedForWorkerParity() {
        val headers = VortXEdgeAuth.signingHeaders("GET", URL("https://trickplay.vortx.tv/tp/a%20b"))
            ?: throw AssertionError("gated host must be stamped")
        // java.net.URL.getPath() keeps the encoding UNDECODED, matching the workers' url.pathname.
        assertEquals(hmacEmptyKeyHex("GET\n/tp/a%20b\n${headers.ts}"), headers.sig)
    }

    @Test
    fun bodyBoundSignatureCoversMethodPathTsAndDigest() {
        val body = """{"ack":true}""".toByteArray(Charsets.UTF_8)
        val headers = VortXEdgeAuth.signingHeadersIncludingBody(
            "POST",
            URL("https://add.vortx.tv/pair"),
            body,
        ) ?: throw AssertionError("gated host must be stamped")

        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(body)
            .joinToString("") { "%02x".format(it) }
        assertEquals(digest, headers.bodyHash)
        assertEquals(VortXEdgeAuth.bodyHeaderName(), "X-VX-Body")
        assertEquals(
            hmacEmptyKeyHex("POST\n/pair\n${headers.ts}\n$digest"),
            headers.sig,
        )
    }

    @Test
    fun headerNamesExposeOnlyTheFrictionTriplePlusBodyHash() {
        assertEquals("X-VX-Ts", VortXEdgeAuth.tsHeaderName())
        assertEquals("X-VX-Kid", VortXEdgeAuth.kidHeaderName())
        assertEquals("X-VX-Sig", VortXEdgeAuth.sigHeaderName())
        // Layer separation: this object must NEVER grow token stamping (MoatToken owns X-VX-Moat).
        val exposed = listOf(
            VortXEdgeAuth.tsHeaderName(),
            VortXEdgeAuth.kidHeaderName(),
            VortXEdgeAuth.sigHeaderName(),
            VortXEdgeAuth.bodyHeaderName(),
        )
        assertTrue(exposed.none { it.contains("Moat", ignoreCase = true) })
    }

    @Test
    fun signedUrlFailsOpenWhenUnprovisioned() {
        val gated = "https://erdb.vortx.tv/logo/tt123.png"
        assertEquals(gated, VortXEdgeAuth.signedUrl(gated))
        assertEquals(gated, VortXEdgeAuth.signedUrl(URL(gated)).toString())
        val foreign = "https://example.com/logo.png?v=2"
        assertEquals(foreign, VortXEdgeAuth.signedUrl(foreign))
        val broken = "::::not-a-url"
        assertEquals(broken, VortXEdgeAuth.signedUrl(broken))
    }

    @Test
    fun provisioningPipelineCollapsesInvalidBlobsToUnprovisioned() {
        assertEquals("", VortXEdgeAuth.deMaskedSecret(null))
        assertEquals("", VortXEdgeAuth.deMaskedSecret(""))
        assertEquals("", VortXEdgeAuth.deMaskedSecret("   \n "))
        assertEquals("", VortXEdgeAuth.deMaskedSecret("!!!not-base64!!!"))
        // Wrong length and non-hex payloads stay rejected even behind a correct mask.
        assertEquals("", VortXEdgeAuth.deMaskedSecret(VortXEdgeAuth.maskedValue("a".repeat(63))))
        assertEquals("", VortXEdgeAuth.deMaskedSecret(VortXEdgeAuth.maskedValue("z".repeat(64))))
        // A raw hex key pasted where the MASKED blob belongs collapses to unprovisioned.
        assertEquals("", VortXEdgeAuth.deMaskedSecret(goldenVector1))
    }

    @Test
    fun maskedValueRoundTripsAndAppliesTheMask() {
        for (vector in listOf(goldenVector1, goldenVector2)) {
            val masked = VortXEdgeAuth.maskedValue(vector)
            assertFalse(masked.isEmpty())
            assertFalse("mask must change the bytes", masked == vector)
            assertEquals("deterministic", masked, VortXEdgeAuth.maskedValue(vector))
            assertEquals("round-trip", vector, VortXEdgeAuth.deMaskedSecret(masked))
        }
    }

    @Test
    fun crossPlatformMaskGoldenParityWithApple() {
        // Byte-for-byte parity with the Apple helper: the SAME masked blob de-masks on both platforms.
        assertEquals(goldenVector1, VortXEdgeAuth.deMaskedSecret(goldenMasked1))
        assertEquals(goldenVector2, VortXEdgeAuth.deMaskedSecret(goldenMasked2))
        assertEquals(goldenMasked1, VortXEdgeAuth.maskedValue(goldenVector1))
        assertEquals(goldenMasked2, VortXEdgeAuth.maskedValue(goldenVector2))
    }
}
