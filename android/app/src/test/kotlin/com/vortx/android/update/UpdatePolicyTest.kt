package com.vortx.android.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Adversarial coverage for the updater trust policy (SEC-01): host confusion, scheme downgrades, redirect
 * abuse, malformed or hostile feeds, signer pinning, schema version enforcement, flavor/engine gates,
 * and split container isolation. Everything here runs on plain values, exactly the way [UpdatePolicy]
 * consumes them in production.
 */
class UpdatePolicyTest {

    private val pinnedSigner = "FC22B87ECD9E4FA26930A1C3E227D8F7D918C646B216032B5DA820EF1AC218CA"

    /** Single seam for feed evaluation in tests: running build 188, flavor "full", app com.vortx.android. */
    private fun evaluate(
        feed: String,
        currentBuild: Int = 188,
        flavor: String = "full",
    ): UpdatePolicy.UpdateDecision =
        UpdatePolicy.evaluateFeed(feed, currentBuild, flavor, "com.vortx.android")

    // ------------------------------------------------------------------
    // Split container builders (schemaVersion 2 is mandatory)
    // ------------------------------------------------------------------

    /**
     * Build a valid worker-style flavor entry. Defaults produce a fully valid entry for the given flavor
     * with correct engine mapping (mpv for full, media3 for play).
     */
    private fun flavorEntry(
        flavorKey: String,
        build: Any = 189,
        version: String = "\"0.3.15\"",
        name: String = "\"VortX 0.3.15\"",
        notes: String = "\"Stability fixes.\"",
        prerelease: String = "false",
        signed: String = "true",
        apk: String = "https://github.com/VortXTV/VortX/releases/download/v0.3.15/VortX-0.3.15-$flavorKey-universal.apk",
        url: String? = apk,
        size: Any = 123_456_789L,
        sha256: String = "a".repeat(64),
        signer: String = pinnedSigner,
        applicationId: String = "\"com.vortx.android\"",
        engine: String? = if (flavorKey == "play") "media3" else "mpv",
        extraFields: String = "",
    ): String {
        val engineField = if (engine != null) """"engine": "$engine",""" else ""
        val urlField = if (url != null) """"url": "$url",""" else ""
        return """{
            "tag": "v0.3.15",
            "version": $version,
            "build": $build,
            "name": $name,
            "notes": $notes,
            "prerelease": $prerelease,
            "signed": $signed,
            "apk": "$apk",
            $urlField
            "size": $size,
            "sha256": "$sha256",
            "signer": "$signer",
            "applicationId": $applicationId,
            "flavor": "$flavorKey",
            ${engineField}
            "artifactType": "apk"$extraFields
        }""".trimIndent()
    }

    /**
     * Build a schemaVersion 2 split appcast. Either flavor may be null (missing from container) or a
     * raw JSON string (valid or hostile).
     */
    private fun splitAppcast(
        fullEntry: String?,
        playEntry: String?,
        schemaVersion: Any = 2,
    ): String {
        val parts = mutableListOf<String>()
        if (fullEntry != null) parts.add("\"full\": $fullEntry")
        if (playEntry != null) parts.add("\"play\": $playEntry")
        val androidBody = parts.joinToString(", ")
        return """{
            "schemaVersion": $schemaVersion,
            "_generatedFromTag": "v0.3.15",
            "ios": {"build": 189},
            "tvos": {"build": 189},
            "mac": {"build": 189},
            "android": { $androidBody }
        }""".trimIndent()
    }

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
            UpdatePolicy.normalizeFingerprint("FC:22:B8:7E:CD:9E:4F:A2:69:30:A1:C3:E2:27:D8:F7:" +
                "D9:18:C6:46:B2:16:03:2B:5D:A8:20:EF:1A:C2:18:CA"),
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
    // Schema version enforcement
    // ------------------------------------------------------------------

    @Test
    fun schemaVersion2IsAccepted() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), flavorEntry("play")))
        assertTrue("expected Offer, got $decision", decision is UpdatePolicy.UpdateDecision.Offer)
    }

    @Test
    fun schemaVersionMissingIsMalformed() {
        val feed = """{"android":{"full":${flavorEntry("full")}}}"""
        val decision = evaluate(feed)
        assertTrue("expected Malformed for missing schemaVersion, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun schemaVersion1IsRejected() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), null, schemaVersion = 1))
        assertTrue("expected Malformed for schemaVersion 1, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun schemaVersion3IsRejected() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), null, schemaVersion = 3))
        assertTrue("expected Malformed for schemaVersion 3, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun schemaVersionStringIsRejected() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), null, schemaVersion = "\"2\""))
        assertTrue("expected Malformed for string schemaVersion, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    // ------------------------------------------------------------------
    // Flat legacy object rejection
    // ------------------------------------------------------------------

    @Test
    fun flatLegacyAndroidEntryIsRejectedAsMalformed() {
        // A flat entry carries "build" directly on the android object; this was the pre-split shape.
        // It must be rejected even if all fields are otherwise valid.
        val flatEntry = flavorEntry("full").let { entry ->
            // Wrap as a flat android object (no split container keys)
            """{"schemaVersion": 2, "android": $entry}"""
        }
        val decision = evaluate(flatEntry)
        assertTrue("expected Malformed for flat legacy entry, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
        val reason = (decision as UpdatePolicy.UpdateDecision.Malformed).reason
        assertTrue("reason should mention flat legacy, got: $reason",
            reason.contains("flat legacy"))
    }

    @Test
    fun flatLegacyEntryWithPlayFlavorIsAlsoRejected() {
        val flatPlay = flavorEntry("play")
        val feed = """{"schemaVersion": 2, "android": $flatPlay}"""
        val decision = evaluate(feed, flavor = "play")
        assertTrue("expected Malformed for flat play entry, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    // ------------------------------------------------------------------
    // Flavor selection and isolation
    // ------------------------------------------------------------------

    @Test
    fun fullFlavorSelectsFullEntryOnly() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), flavorEntry("play")), flavor = "full")
        val offer = decision as UpdatePolicy.UpdateDecision.Offer
        assertEquals("0.3.15", offer.release.version)
        assertEquals(189, offer.release.build)
        assertTrue("artifact should be full flavor",
            offer.release.artifactUrl.contains("full"))
        assertFalse("artifact should NOT be play flavor",
            offer.release.artifactUrl.contains("play"))
    }

    @Test
    fun playFlavorSelectsPlayEntryOnly() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), flavorEntry("play")), flavor = "play")
        val offer = decision as UpdatePolicy.UpdateDecision.Offer
        assertEquals("0.3.15", offer.release.version)
        assertTrue("artifact should be play flavor",
            offer.release.artifactUrl.contains("play"))
        assertFalse("artifact should NOT be full flavor",
            offer.release.artifactUrl.contains("full-universal"))
    }

    @Test
    fun siblingOnlyFullOffersNothingForPlay() {
        // Only full published; play device sees None, not Malformed.
        val decision = evaluate(splitAppcast(flavorEntry("full"), null), flavor = "play")
        assertTrue("expected None when only sibling published, got $decision",
            decision is UpdatePolicy.UpdateDecision.None)
    }

    @Test
    fun siblingOnlyPlayOffersNothingForFull() {
        val decision = evaluate(splitAppcast(null, flavorEntry("play")), flavor = "full")
        assertTrue("expected None when only sibling published, got $decision",
            decision is UpdatePolicy.UpdateDecision.None)
    }

    @Test
    fun nullOwnFlavorInContainerIsNoneNotMalformed() {
        val feed = """{"schemaVersion": 2, "android": {"full": null, "play": ${flavorEntry("play")}}}"""
        val decision = evaluate(feed, flavor = "full")
        assertTrue("expected None for null own flavor, got $decision",
            decision is UpdatePolicy.UpdateDecision.None)
    }

    @Test
    fun malformedSiblingNeverBlocksTheHealthyFlavor() {
        // The play entry is hostile garbage; a full-flavor device still gets its valid offer.
        val hostilePlay = """{"build":"nope","signed":"yes"}"""
        val decision = evaluate(splitAppcast(flavorEntry("full"), hostilePlay), flavor = "full")
        assertTrue("healthy full should survive hostile play sibling, got $decision",
            decision is UpdatePolicy.UpdateDecision.Offer)

        // Mirror image: a play device hits the hostile child and refuses.
        val playDecision = evaluate(splitAppcast(flavorEntry("full"), hostilePlay), flavor = "play")
        assertTrue("hostile play entry should be Malformed for play device, got $playDecision",
            playDecision is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun containerWithOnlyUnknownKeysOffersNothing() {
        val feed = """{"schemaVersion": 2, "android": {"tablet": {"build": 999}}}"""
        assertTrue(evaluate(feed) is UpdatePolicy.UpdateDecision.None)
        val emptyFeed = """{"schemaVersion": 2, "android": {}}"""
        assertTrue(evaluate(emptyFeed) is UpdatePolicy.UpdateDecision.None)
    }

    @Test
    fun nonObjectChildrenAreRejectedForTheirFlavor() {
        val stringChild = """{"schemaVersion": 2, "android": {"full": "soon", "play": ${flavorEntry("play")}}}"""
        assertTrue(evaluate(stringChild) is UpdatePolicy.UpdateDecision.Malformed)

        val arrayChild = """{"schemaVersion": 2, "android": {"full": [1], "play": ${flavorEntry("play")}}}"""
        assertTrue(evaluate(arrayChild) is UpdatePolicy.UpdateDecision.Malformed)
    }

    // ------------------------------------------------------------------
    // Unknown flavor rejection
    // ------------------------------------------------------------------

    @Test
    fun unsupportedFlavorIsRejectedBeforeParsing() {
        val feed = splitAppcast(flavorEntry("full"), flavorEntry("play"))
        val decision = evaluate(feed, flavor = "tablet")
        assertTrue("expected Malformed for unknown flavor, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
        val reason = (decision as UpdatePolicy.UpdateDecision.Malformed).reason
        assertTrue("reason should mention unsupported flavor, got: $reason",
            reason.contains("unsupported flavor"))
    }

    @Test
    fun emptyFlavorIsRejected() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), null), flavor = "")
        assertTrue("expected Malformed for empty flavor, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    // ------------------------------------------------------------------
    // Mismatched flavor field
    // ------------------------------------------------------------------

    @Test
    fun containerChildDeclaringAnotherFlavorIsRejected() {
        // The entry under "full" claims to be the play artifact: mislabeled payload, refuse.
        val mislabeled = flavorEntry("full").replace("\"flavor\": \"full\"", "\"flavor\": \"play\"")
        val decision = evaluate(splitAppcast(mislabeled, null))
        assertTrue("expected Malformed for mismatched flavor, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
        val reason = (decision as UpdatePolicy.UpdateDecision.Malformed).reason
        assertTrue("reason should mention mismatched flavor, got: $reason",
            reason.contains("mismatched flavor"))
    }

    // ------------------------------------------------------------------
    // Engine enforcement
    // ------------------------------------------------------------------

    @Test
    fun fullFlavorRequiresMpvEngine() {
        // Correct engine: accepted.
        val correct = evaluate(splitAppcast(flavorEntry("full", engine = "mpv"), null))
        assertTrue("full with mpv should be Offer, got $correct",
            correct is UpdatePolicy.UpdateDecision.Offer)

        // Wrong engine: rejected.
        val wrongEngine = evaluate(splitAppcast(flavorEntry("full", engine = "media3"), null))
        assertTrue("full with media3 should be Malformed, got $wrongEngine",
            wrongEngine is UpdatePolicy.UpdateDecision.Malformed)
        val reason = (wrongEngine as UpdatePolicy.UpdateDecision.Malformed).reason
        assertTrue("reason should mention engine mismatch, got: $reason",
            reason.contains("engine"))
    }

    @Test
    fun playFlavorRequiresMedia3Engine() {
        // Correct engine: accepted.
        val correct = evaluate(splitAppcast(null, flavorEntry("play", engine = "media3")), flavor = "play")
        assertTrue("play with media3 should be Offer, got $correct",
            correct is UpdatePolicy.UpdateDecision.Offer)

        // Wrong engine: rejected.
        val wrongEngine = evaluate(splitAppcast(null, flavorEntry("play", engine = "mpv")), flavor = "play")
        assertTrue("play with mpv should be Malformed, got $wrongEngine",
            wrongEngine is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun missingEngineFieldIsRejected() {
        val noEngine = flavorEntry("full", engine = null)
        val decision = evaluate(splitAppcast(noEngine, null))
        assertTrue("expected Malformed for missing engine, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
        val reason = (decision as UpdatePolicy.UpdateDecision.Malformed).reason
        assertTrue("reason should mention missing engine, got: $reason",
            reason.contains("missing required engine"))
    }

    @Test
    fun emptyEngineFieldIsRejected() {
        val emptyEngine = flavorEntry("full", engine = "")
        val decision = evaluate(splitAppcast(emptyEngine, null))
        assertTrue("expected Malformed for empty engine, got $decision",
            decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    // ------------------------------------------------------------------
    // Feed evaluation: standard positive and negative cases
    // ------------------------------------------------------------------

    @Test
    fun wellFormedNewerStableAndroidEntryYieldsAFullyVerifiedOffer() {
        val decision = evaluate(splitAppcast(flavorEntry("full"), flavorEntry("play")), currentBuild = 188)
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
        assertTrue(evaluate(splitAppcast(flavorEntry("full", build = 188), null), 188)
            is UpdatePolicy.UpdateDecision.None)
        assertTrue(evaluate(splitAppcast(flavorEntry("full", build = 100), null), 188)
            is UpdatePolicy.UpdateDecision.None)
        assertTrue(evaluate("""{"schemaVersion": 2}""", 188) is UpdatePolicy.UpdateDecision.None)
        assertTrue(evaluate("""{"schemaVersion": 2, "android": null}""", 188) is UpdatePolicy.UpdateDecision.None)
    }

    @Test
    fun prereleasesStaySilentButAMistypedPrereleaseFlagIsMalformed() {
        assertTrue(evaluate(splitAppcast(flavorEntry("full", prerelease = "true"), null), 188)
            is UpdatePolicy.UpdateDecision.None)
        assertTrue(evaluate(splitAppcast(flavorEntry("full", prerelease = "\"yes\""), null), 188)
            is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun hostileOrBrokenEntriesFailClosedWithoutOfferingAnything() {
        val cases: List<Pair<String, String>> = listOf(
            "build is a numeric string" to splitAppcast(flavorEntry("full", build = "\"190\""), null),
            "build is zero" to splitAppcast(flavorEntry("full", build = "0"), null),
            "build missing" to splitAppcast(
                """{"tag":"v1","version":"1","name":"n","notes":"","prerelease":false,"signed":true,"apk":"https://github.com/x","size":5,"sha256":"${"a".repeat(64)}","signer":"$pinnedSigner","applicationId":"com.vortx.android","flavor":"full","engine":"mpv","artifactType":"apk"}""",
                null,
            ),
            "not marked signed" to splitAppcast(flavorEntry("full", signed = "false"), null),
            "signed mistyped" to splitAppcast(flavorEntry("full", signed = "\"true\""), null),
            "no artifact url at all" to splitAppcast(
                flavorEntry("full", apk = "", url = null),
                null,
            ),
            "apk and url disagree" to splitAppcast(
                flavorEntry("full", apk = "https://github.com/a.apk", url = "https://github.com/b.apk"),
                null,
            ),
            "artifact off host" to splitAppcast(
                flavorEntry("full", apk = "https://evil.example/a.apk"),
                null,
            ),
            "sha256 too short" to splitAppcast(flavorEntry("full", sha256 = "abcd"), null),
            "sha256 not hex" to splitAppcast(flavorEntry("full", sha256 = "g".repeat(64)), null),
            "sha256 missing" to splitAppcast(flavorEntry("full", sha256 = ""), null),
            "signer not pinned" to splitAppcast(flavorEntry("full", signer = "e".repeat(64)), null),
            "signer garbage" to splitAppcast(flavorEntry("full", signer = "::"), null),
            "size zero" to splitAppcast(flavorEntry("full", size = "0"), null),
            "size negative" to splitAppcast(flavorEntry("full", size = "-5"), null),
            "size mistyped" to splitAppcast(flavorEntry("full", size = "\"123\""), null),
            "version missing" to splitAppcast(flavorEntry("full", version = "\"\""), null),
            "notes oversized" to splitAppcast(
                flavorEntry("full", notes = "\"${"x".repeat(20_001)}\""),
                null,
            ),
        )
        cases.forEach { (label, feed) ->
            val decision = evaluate(feed, currentBuild = 188)
            assertTrue(
                "expected Malformed for [$label], got $decision",
                decision is UpdatePolicy.UpdateDecision.Malformed,
            )
        }
    }

    @Test
    fun oversizeArtifactSizeIsRefusedBeforeAnyDownload() {
        val tooBig = UpdatePolicy.MAX_ARTIFACT_BYTES + 1
        val decision = evaluate(splitAppcast(flavorEntry("full", size = "$tooBig"), null), currentBuild = 188)
        assertTrue(decision is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun brokenJsonAndOversizeManifestsNeverOffer() {
        assertTrue(evaluate("{not json", 188) is UpdatePolicy.UpdateDecision.Malformed)
        assertTrue(evaluate("", 188) is UpdatePolicy.UpdateDecision.Malformed)
        assertTrue(
            evaluate("[1,2,3]", 188) is UpdatePolicy.UpdateDecision.Malformed,
        )
        val oversize = " ".repeat(UpdatePolicy.MAX_MANIFEST_BYTES + 1)
        assertTrue(evaluate(oversize, 188) is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun androidEntryOfTheWrongJsonTypeIsMalformed() {
        assertTrue(
            evaluate("""{"schemaVersion": 2, "android": [1, 2]}""", 188)
                is UpdatePolicy.UpdateDecision.Malformed,
        )
        assertTrue(
            evaluate("""{"schemaVersion": 2, "android": "coming soon"}""", 188)
                is UpdatePolicy.UpdateDecision.Malformed,
        )
    }

    @Test
    fun colonSeparatedPublishedSignerStillPinsCorrectly() {
        val colonForm = "FC:22:B8:7E:CD:9E:4F:A2:69:30:A1:C3:E2:27:D8:F7:" +
            "D9:18:C6:46:B2:16:03:2B:5D:A8:20:EF:1A:C2:18:CA"
        val offer = evaluate(splitAppcast(flavorEntry("full", signer = colonForm), null))
            as UpdatePolicy.UpdateDecision.Offer
        assertFalse(offer.release.signerSha256.contains(':'))
        assertEquals(pinnedSigner, offer.release.signerSha256)
    }

    @Test
    fun containerChildWithForeignApplicationIdIsRejected() {
        val foreign = flavorEntry("full", applicationId = "\"com.evil.repack\"")
        assertTrue(evaluate(splitAppcast(foreign, null)) is UpdatePolicy.UpdateDecision.Malformed)
    }

    @Test
    fun bothFlavorsProduceIndependentOffers() {
        val feed = splitAppcast(flavorEntry("full"), flavorEntry("play"))

        val fullOffer = evaluate(feed, flavor = "full") as UpdatePolicy.UpdateDecision.Offer
        assertTrue(fullOffer.release.artifactUrl.contains("full"))

        val playOffer = evaluate(feed, flavor = "play") as UpdatePolicy.UpdateDecision.Offer
        assertTrue(playOffer.release.artifactUrl.contains("play"))
    }
}
