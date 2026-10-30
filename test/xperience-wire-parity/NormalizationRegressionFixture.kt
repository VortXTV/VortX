package com.vortx.android.xperience

/** Portable source proposal adapted from the frozen V2 JUnit cases; no main or external framework. */
internal object XperienceTransportIdentityRegression {
    private fun candidate(raw: String) = XperienceAddonBinding.Candidate.fromInstalled(
        XperienceAddonBinding.InstalledDescriptor("fixture.addon", raw,
            listOf(XperienceAddonBinding.Catalog("movie", "popular", true, false, true))))

    private fun portableIdentityKeepsOpaqueHostsAndExactEscapes() {
        val cases = listOf(
            "HTTPS://CATALOG.EXAMPLE.INVALID:0443/manifest.json?x=a%2Fb&x=two+words&" to "https://catalog.example.invalid:443/manifest.json?x=a%2Fb&x=two+words&",
            "https://catalog.example.invalid:/manifest.json?" to "https://catalog.example.invalid/manifest.json?",
            "https://caf\u00e9.example.invalid/caf\u00e9/manifest.json?q=cafe\u0301" to "https://caf\u00e9.example.invalid/caf%C3%A9/manifest.json?q=cafe%CC%81",
            "https://\u65e5\u672c.example.invalid/\uD83D\uDE00/manifest.json?x=%2f&x=%2F" to "https://\u65e5\u672c.example.invalid/%F0%9F%98%80/manifest.json?x=%2f&x=%2F",
            "https://%63ATALOG.example.invalid/config%2fone/manifest.json?x=%aF" to "https://%63atalog.example.invalid/config%2fone/manifest.json?x=%aF",
            "http://10.23.45.67:8080/manifest.json" to "http://10.23.45.67:8080/manifest.json",
            "https://100.101.102.103/manifest.json" to "https://100.101.102.103/manifest.json",
            "https://[2001:0DB8:0000:0000:0000:0000:0000:0001]:0443/manifest.json" to "https://[2001:0db8:0000:0000:0000:0000:0000:0001]:443/manifest.json",
            "https://[FE80::1%25FixtureZone]/manifest.json" to "https://[fe80::1%25FixtureZone]/manifest.json",
            "https://[::ffff:192.0.2.1]/manifest.json" to "https://[::ffff:192.0.2.1]/manifest.json",
            "https://[::]/manifest.json" to "https://[::]/manifest.json",
            "https://[::1]/manifest.json" to "https://[::1]/manifest.json",
            "https://[1::]/manifest.json" to "https://[1::]/manifest.json",
            "https://[::192.0.2.1]/manifest.json" to "https://[::192.0.2.1]/manifest.json",
            "https://[1:2:3:4:5:6:192.0.2.1]/manifest.json" to "https://[1:2:3:4:5:6:192.0.2.1]/manifest.json")
        cases.forEach { (raw, expected) ->
            val value = candidate(raw)
            check(value.canonicalTransport.toByteArray(Charsets.UTF_8).contentEquals(expected.toByteArray(Charsets.UTF_8)))
            check(com.vortx.android.engine.OHJson.sha(expected.toByteArray(Charsets.UTF_8)) == value.transportFingerprint)
        }
        listOf(
            "https://caf\u00e9.example.invalid/manifest.json" to "https://xn--caf-dma.example.invalid/manifest.json",
            "https://caf\u00e9.example.invalid/manifest.json" to "https://cafe\u0301.example.invalid/manifest.json",
            "https://%63atalog.example.invalid/manifest.json" to "https://catalog.example.invalid/manifest.json",
            "https://catalog.example.invalid/manifest.json" to "https://catalog.example.invalid:443/manifest.json",
            "https://catalog.example.invalid/manifest.json" to "https://catalog.example.invalid/manifest.json?",
            "https://catalog.example.invalid/a%2fb/manifest.json" to "https://catalog.example.invalid/a%2Fb/manifest.json",
            "https://[fe80::1%25FixtureZone]/manifest.json" to "https://[fe80::1%25fixturezone]/manifest.json"
        ).forEach { (left, right) -> check(candidate(left).transportFingerprint != candidate(right).transportFingerprint) }
    }

    private fun malformedInputsRejectWithoutParserRepair() {
        listOf(
            "https://user@catalog.example.invalid/manifest.json", "https://catalog.example.invalid/manifest.json#",
            "https://catalog.example.invalid:0/manifest.json", "https://catalog.example.invalid:65536/manifest.json",
            "https://catalog.example.invalid:999999999999999999999999/manifest.json",
            "https://catalog.example.invalid/a b/manifest.json", "https://catalog.example.invalid/a\tb/manifest.json",
            "https://catalog.example.invalid/a\u0085b/manifest.json", "https://catalog.example.invalid/a%GG/manifest.json",
            "https://catalog.example.invalid/a%/manifest.json", "https://catalog.example.invalid/manifest.json?x=%GG",
            "https://[2001:db8::1/manifest.json", "https://[1::2::3]/manifest.json", "https://[192.0.2.1::]/manifest.json",
            "https://[:1::2]/manifest.json", "https://[1::2:]/manifest.json",
            "https://[fe80::1%FixtureZone]/manifest.json", "https://[fe80::1%25]/manifest.json",
            "https://catalog.example.invalid/\uD800/manifest.json"
        ).forEach { raw ->
            try { candidate(raw); throw AssertionError("Invalid configured transport admitted") }
            catch (failure: IllegalArgumentException) { check("Invalid installed registry" == failure.message) }
        }
    }

    private fun validLongConfiguredQueriesAndCheckedCapacityRemainSeparateFromNetworkAdmission() {
        for (count in listOf(5000, 20000)) {
            val raw = "https://catalog.example.invalid/manifest.json?token=" + "a".repeat(count)
            val value = candidate(raw)
            check(raw == value.canonicalTransport)
            check(com.vortx.android.engine.OHJson.sha(raw.toByteArray(Charsets.UTF_8)) == value.transportFingerprint)
        }
        val raw = "https://catalog.example.invalid/manifest.json?token=" + "\u00e9".repeat(6000)
        val expected = "https://catalog.example.invalid/manifest.json?token=" + "%C3%A9".repeat(6000)
        check(candidate(raw).canonicalTransport.toByteArray(Charsets.UTF_8).contentEquals(expected.toByteArray(Charsets.UTF_8)))
        val maximumSourceCount = Int.MAX_VALUE / 3
        check(maximumSourceCount * 3 == XperienceAddonBinding.transportIdentityCapacity(maximumSourceCount))
        for (count in listOf(-1, maximumSourceCount + 1, Int.MAX_VALUE)) {
            try {
                XperienceAddonBinding.transportIdentityCapacity(count)
                throw AssertionError("Unrepresentable identity capacity admitted")
            } catch (failure: IllegalArgumentException) { check("Invalid installed registry" == failure.message) }
        }
    }

    private fun changedSavedIdentityRequiresExplicitRebind() {
        val source = XperienceCollections.parse("""[{"id":"c","title":"C","folders":[{"id":"f","title":"F","sources":[{"provider":"addon","addonId":"fixture.addon","type":"movie","catalogId":"popular"}]}]}]""".toByteArray(Charsets.UTF_8))
            .collections.single().folders.single().sources.single()
        val current = candidate("https://catalog.example.invalid:0443/manifest.json")
        val old = XperienceAddonBinding.Mapping("fixture.addon", "81bf75fe86e3ad3f26b698641413ab168dadfa7dfad91c8cc92690eaf971dde4")
        check(XperienceAddonBinding.Resolution.MappingUnavailable ==
            XperienceAddonBinding.resolve(source, listOf(current), old))
        check(XperienceAddonBinding.Resolution.Resolved(current) ==
            XperienceAddonBinding.resolve(source, listOf(current), current.mapping))
    }

    fun run() {
        portableIdentityKeepsOpaqueHostsAndExactEscapes()
        malformedInputsRejectWithoutParserRepair()
        validLongConfiguredQueriesAndCheckedCapacityRemainSeparateFromNetworkAdmission()
        changedSavedIdentityRequiresExplicitRebind()
    }
}
