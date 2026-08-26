package com.vortx.android.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Adversarial coverage for the updater trust policy (SEC-01): host confusion, scheme downgrades, redirect
 * abuse, malformed or hostile feeds, and signer pinning. Everything here runs on plain values, exactly the
 * way [UpdatePolicy] consumes them in production.
 */
class UpdatePolicyTest {

    private val pinnedSigner = "90DD0859BE63569B31F40BF93D3E3629094535013F3489C22BEE3B4655E0006A"

    private fun appcast(
        androidJson: String?,
        schemaVersion: Int = 2,
    ): String {
        val androidEntry = androidJson ?: "null"
        return """
            {
              "schemaVersion": $schemaVersion,
              "_generatedFromTag": "v0.3.15",
              "ios": {"build": 189},
              "tvos": {"build": 189},
              "mac": {"build": 189},
              "android": $androidEntry
            }
        """.trimIndent()
    }

    private fun androidEntry(
        apk: String = "https://github.com/VortXTV/VortX/releases/download/v0.3.15/VortX-0.3.15-phone.apk",
        url: String? = apk,
        size: Any? = 123_456_789L,
        sha256: String = "a".repeat(64),
        signer: String = pinnedSigner,
        build: Any = 189,
        prerelease: String = "false",
        signed: String = "true",
        version: String = "\"0.3.15\"",
    ): String = """
        {
          "tag": "v0.3.15",
          "version": $version,
          "build": ${build},
          "name": "VortX 0.3.15",
          "notes": "Stability fixes.",
          "prerelease": $prerelease,
          "signed": $signed,
          "apk": "$apk",
          "url": ${url?.let { "\"$it\"" } ?: "null"},
          "size": ${size},
          "sha256": "$sha256",
          "signer": "$signer"
        }
    """.trimIndent()

    // ------------------------------------------------------------------
    // Artifact URL policy: host confusion and scheme abuse
    // ------------------------------------------------------------------

    @Test
    fun acceptsExactlyTheAllowListedHttpsArtifactHosts() {
        val good = listOf(
            "https://github.com/VortXTV/VortX/releases/download/v0.3.15/VortX.apk",
            "https://objects.githubusercontent.com/some/object/path",
            "https://release-assets.githubusercontent.com/some/asset",
            "https://vortx.tv/appcast.json",
        )
        good.forEach { url -> assertEquals(url, UpdatePolicy.validateArtifactUrl(url)) }
    }

    @Test
    fun rejectsNonHttpsSchemesAndLookalikes() {
        val bad = listOf(
            "http://github.com/VortXTV/VortX/releases/download/v0.3.15/VortX.apk", // downgrade
            "HTTPS://github.com/x", // non-exact scheme: refused rather than case-folded
            "ftp://github.com/x",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "//github.com/x", // protocol-relative has no scheme of its own
            "https://github.com\\@evil.example/x", // backslash smuggling attempt
        )
        bad.forEach { url -> assertNull("expected rejection: $url", UpdatePolicy.validateArtifactUrl(url)) }
    }

    @Test
    fun rejectsHostConfusionTricks() {
        val bad = listOf(
            "https://evil.example/VortX.apk",
            "https://github.com.evil.example/VortX.apk", // suffix spoof
            "https://evil.github.com/VortX.apk", // subdomain spoof
            "https://github.com-vortx.example/VortX.apk",
            "https://192.168.1.10/VortX.apk", // raw IP
            "https://[::1]/VortX.apk", // IPv6 loopback
            "https://github.com@evil.example/VortX.apk", // userinfo confusion
            "https://user:pass@github.com/VortX.apk", // credentialed URL
            "https://github.com:8443/VortX.apk", // odd port
            "https://github.com/x?cachebust=1", // query not allowed on published artifacts
            "https://github.com/x#frag",
            "https://github.com", // no path
            "not a url at all",
            "",
        )
        bad.forEach { url -> assertNull("expected rejection: $url", UpdatePolicy.validateArtifactUrl(url)) }
    }

    @Test
    fun normalizesAnUppercaseButOtherwiseLegitimateHost() {
        // Host case folds (DNS names are case-insensitive); everything else stays strict.
        assertEquals(
            "https://GitHub.com/VortXTV/VortX/releases/download/v1/a.apk",
            UpdatePolicy.validateArtifactUrl("https://GitHub.com/VortXTV/VortX/releases/download/v1/a.apk"),
        )
    }

    // ------------------------------------------------------------------
    // Redirect hop policy
    // ------------------------------------------------------------------

    private val releaseUrl = "https://github.com/VortXTV/VortX/releases/download/v0.3.15/VortX-phone.apk"

    @Test
    fun acceptsAllowListedAbsoluteAndRelativeRedirects() {
        val current = java.net.URL(releaseUrl)
        val absolute = "https://objects.githubusercontent.com/object/bin"
        assertEquals(absolute, UpdatePolicy.resolveRedirect(current, absolute)?.toString())
        assertEquals(
            "https://github.com/next",
            UpdatePolicy.resolveRedirect(current, "/next")?.toString(),
        )
        assertEquals(absolute, UpdatePolicy.resolveRedirect(current, "  $absolute  ")?.toString())
        // Signed object-store targets carry query strings; hops may keep them.
        val signed = "https://objects.githubusercontent.com/object/bin?X-Amz-Signature=abc"
        assertEquals(signed, UpdatePolicy.resolveRedirect(current, signed)?.toString())
    }

    @Test
    fun refusesDowngradesAndOffHostHops() {
        val current = java.net.URL(releaseUrl)
        listOf(
            "http://objects.githubusercontent.com/object/bin", // downgrade mid-chain
            "https://evil.example/bin",
            "https://github.com.evil.example/bin",
            "https://user@evil.example/bin",
            "",
            "not a url",
            "https://github.com:8080/bin",
        ).forEach { location ->
            assertNull("expected hop refusal: $location", UpdatePolicy.resolveRedirect(current, location))
        }
    }

    // ------------------------------------------------------------------
    // Fingerprint + digest handling
    // ------------------------------------------------------------------

    @Test
    fun fingerprintNotationsNormalizeToThePinnedCompactForm() {
        assertEquals(pinnedSigner, UpdatePolicy.normalizeFingerprint(pinnedSigner))
        assertEquals(
            pinnedSigner,
            UpdatePolicy.normalizeFingerprint("90:DD:08:59:BE:63:56:9B:31:F4:0B:F9:3D:3E:36:29:" +
                "09:45:35:01:3F:34:89:C2:2B:EE:3B:46:55:E0:00:6A"),
        )
        assertEquals(pinnedSigner, UpdatePolicy.normalizeFingerprint(pinnedSigner.lowercase()))
        assertNull(UpdatePolicy.normalizeFingerprint("90DD")) // too short
        assertNull(UpdatePolicy.normalizeFingerprint("z".repeat(64))) // not hex
        assertNull(UpdatePolicy.normalizeFingerprint(""))
    }

    @Test
    fun digestComparisonIsNullSafeAndExact() {
        // digestEquals is byte-exact on purpose: case normalization belongs to normalizeFingerprint /
        // normalizeDigest, which every production call site runs first.
        assertTrue(UpdatePolicy.digestEquals("ab", "ab"))
        assertFalse(UpdatePolicy.digestEquals("AB", "ab"))
        assertFalse(UpdatePolicy.digestEquals("ab", "ac"))
        assertFalse(UpdatePolicy.digestEquals(null, "ab"))
        assertFalse(UpdatePolicy.digestEquals("ab", null))
    }

    // ------------------------------------------------------------------
    // Feed evaluation
    // ------------------------------------------------------------------

    @Test
    fun wellFormedNewerStableAndroidEntryYieldsAFullyVerifiedOffer() {
        val decision = UpdatePolicy.evaluateFeed(appcast(androidEntry()), currentBuild = 188)
        val offer = decision as UpdatePolicy.UpdateDecision.Offer
        val release = offer.release
        assertEquals("0.3.15", release.version)
        assertEquals(189, release.build)
        assertEquals("0.3.15.189", release.key)
        assertEquals("VortX 0.3.15", release.name)
        assertEquals("a".repeat(64), release.sha256)
        assertEquals(pinnedSigner, release.signerSha256)
        assertEquals(123_456_789L, release.sizeBytes)
        assertTrue(release.artifactUrl.startsWith("https://github.com/"))
    }

    @Test
    fun olderEqualOrMissingEntriesAreSimplyNone() {
        assertTrue(UpdatePolicy.evaluateFeed(appcast(androidEntry(build = 188)), 188)
            is UpdatePolicy.UpdateDecision.None)
        assertTrue(UpdatePolicy.evaluateFeed(appcast(androidEntry(build = 100)), 188)
            is UpdatePolicy.UpdateDecision.None)
        assertTrue(UpdatePolicy.evaluateFeed(appcast(null), 188) is UpdatePolicy.UpdateDecision.None)
        assertTrue(UpdatePolicy.evaluateFeed("{\"android\":null}", 188) is UpdatePolicy.UpdateDecision.None)
        assertTrue(UpdatePolicy.evaluateFeed("{}", 188) is UpdatePolicy.UpdateDecision.None)
    }

    @Test
    fun prereleasesStaySilentButAMistypedPrereleaseFlagIsMalformed() {
        assertTrue(UpdatePolicy.evaluateFeed(appcast(androidEntry(prerelease = "true")), 188)
            is UpdatePolicy.UpdateDecision.None)
        assertTrue(UpdatePolicy.evaluateFeed(appcast(androidEntry(prerelease = "\"yes\"")), 188)
            is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun hostileOrBrokenEntriesFailClosedWithoutOfferingAnything() {
        val cases: List<Pair<String, String>> = listOf(
            "build is a numeric string" to appcast(androidEntry(build = "\"190\"")),
            "build is zero" to appcast(androidEntry(build = "0")),
            "build missing" to appcast("{\"signed\":true,\"version\":\"1\",\"size\":5,\"sha256\":\"${"a".repeat(64)}\",\"signer\":\"$pinnedSigner\",\"apk\":\"https://github.com/x\"}"),
            "not marked signed" to appcast(androidEntry(signed = "false")),
            "signed mistyped" to appcast(androidEntry(signed = "\"true\"")),
            "no artifact url at all" to appcast(androidEntry(apk = "", url = null)),
            "apk and url disagree" to appcast(
                androidEntry(
                    apk = "https://github.com/a.apk",
                    url = "https://evil.example/b.apk",
                ),
            ),
            "artifact off host" to appcast(androidEntry(apk = "https://evil.example/a.apk")),
            "sha256 too short" to appcast(androidEntry(sha256 = "abcd")),
            "sha256 not hex" to appcast(androidEntry(sha256 = "g".repeat(64))),
            "sha256 missing" to appcast(androidEntry(sha256 = "")),
            "signer not pinned" to appcast(androidEntry(signer = "e".repeat(64))),
            "signer garbage" to appcast(androidEntry(signer = "::")),
            "size zero" to appcast(androidEntry(size = "0")),
            "size negative" to appcast(androidEntry(size = "-5")),
            "size mistyped" to appcast(androidEntry(size = "\"123\"")),
            "version missing" to appcast(androidEntry(version = "\"\"")),
            "notes oversized" to appcast(
                """{"tag":"v0.3.15","version":"0.3.15","build":189,"name":"n","notes":"${"x".repeat(20_001)}",""" +
                    """"prerelease":false,"signed":true,"apk":"https://github.com/a.apk",""" +
                    """"size":5,"sha256":"${"a".repeat(64)}","signer":"$pinnedSigner"}""",
            ),
        )
        cases.forEach { (label, feed) ->
            val decision = UpdatePolicy.evaluateFeed(feed, currentBuild = 188)
            assertTrue(
                "expected Malformed for [$label], got $decision",
                decision is UpdatePolicy.UpdateDecision.Malformed,
            )
        }
    }

    @Test
    fun oversizeArtifactSizeIsRefusedBeforeAnyDownload() {
        val tooBig = UpdatePolicy.MAX_ARTIFACT_BYTES + 1
        val decision = UpdatePolicy.evaluateFeed(appcast(androidEntry(size = "$tooBig")), currentBuild = 188)
        assertTrue(decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun brokenJsonAndOversizeManifestsNeverOffer() {
        assertTrue(UpdatePolicy.evaluateFeed("{not json", 188) is UpdatePolicy.UpdateDecision.Malformed)
        assertTrue(UpdatePolicy.evaluateFeed("", 188) is UpdatePolicy.UpdateDecision.Malformed)
        assertTrue(
            UpdatePolicy.evaluateFeed("[1,2,3]", 188) is UpdatePolicy.UpdateDecision.Malformed,
        )
        val oversize = " ".repeat(UpdatePolicy.MAX_MANIFEST_BYTES + 1)
        assertTrue(UpdatePolicy.evaluateFeed(oversize, 188) is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun androidEntryOfTheWrongJsonTypeIsMalformed() {
        assertTrue(
            UpdatePolicy.evaluateFeed("""{"android":[1,2]}""", 188)
                is UpdatePolicy.UpdateDecision.Malformed,
        )
        assertTrue(
            UpdatePolicy.evaluateFeed("""{"android":"coming soon"}""", 188)
                is UpdatePolicy.UpdateDecision.Malformed,
        )
    }

    @Test
    fun colonSeparatedPublishedSignerStillPinsCorrectly() {
        val colonForm = "90:DD:08:59:BE:63:56:9B:31:F4:0B:F9:3D:3E:36:29:" +
            "09:45:35:01:3F:34:89:C2:2B:EE:3B:46:55:E0:00:6A"
        val offer = UpdatePolicy.evaluateFeed(appcast(androidEntry(signer = colonForm)), 188)
            as UpdatePolicy.UpdateDecision.Offer
        assertFalse(offer.release.signerSha256.contains(':'))
        assertEquals(pinnedSigner, offer.release.signerSha256)
    }
}
