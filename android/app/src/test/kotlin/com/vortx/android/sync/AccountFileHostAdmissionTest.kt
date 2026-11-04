package com.vortx.android.sync

import com.vortx.android.backup.BinaryPlist
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxRuntimeBindings
import java.util.concurrent.CancellationException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Synthetic cold binding. The real file helper, strict JSON and plist parsers and gate all execute. */
class AccountFileHostAdmissionTest {
    private val owner = "00000000-0000-0000-0000-00000000A11C"
    private val child = "10000000-0000-0000-0000-000000000001"
    private val scope = VortxAccountScope("account.synthetic", owner)
    private val digest = "e9" + "0".repeat(62)

    private fun raw(text: String): ByteArray = OHJson.literal(text)
    private fun quoted(text: String): ByteArray = OHJson.quote(text)
    private fun encoded(bytes: ByteArray): ByteArray = quoted(OHJson.b64(bytes))
    private fun json(vararg fields: Pair<String, ByteArray>): ByteArray =
        OHJson.Obj().apply { fields.forEach { (key, value) -> set(key, value) } }.encoded()

    private fun profile(id: String, name: String): ByteArray {
        val account = if (id == owner) json("kind" to quoted("local_only"))
            else json("kind" to quoted("shared"), "value" to quoted(owner))
        return json("id" to quoted(id), "name" to quoted(name), "owner" to raw((id == owner).toString()),
            "account" to account, "parental" to raw("""{"kids":false,"familyEdit":false}"""),
            "settings" to raw("{}"), "addons" to quoted("share_primary"))
    }

    private fun native(): ByteArray {
        val primary = profile(owner, "[RD] Synthetic Owner")
        val secondary = profile(child, "[Kids] Synthetic Child")
        fun register(row: ByteArray): ByteArray = json("profile" to row, "fieldClocks" to raw("{}"))
        val material = json("schemaVersion" to raw("1"), "roster" to OHJson.array(listOf(primary, secondary)),
            "deletedProfileIds" to raw("[]"), "addons" to raw("{}"), "libraries" to raw("{}"),
            "watches" to raw("{}"), "identityLinks" to raw("{}"))
        return json("schemaVersion" to raw("1"), "scope" to quoted(scope.accountID), "ownerProfileId" to quoted(owner),
            "profiles" to json(owner to register(primary), child to register(secondary)),
            "addons" to raw("{}"), "libraries" to raw("{}"), "watches" to raw("{}"),
            "legacyImport" to json("schemaVersion" to raw("1"), "fingerprint" to quoted(digest), "baseline" to material),
            "ownAccountSources" to raw("{}"))
    }

    private fun candidate(vararg fields: Pair<String, ByteArray>, nativeBytes: ByteArray = native()): ByteArray =
        json("nativeSync" to nativeBytes, *fields)

    private inner class Bindings : VortxRuntimeBindings {
        var created = 0
        var freed = 0
        var merged: ByteArray? = null
        var normalizedNative: ByteArray? = null
        var extraState: Pair<String, ByteArray>? = null
        var onState: (() -> Unit)? = null
        var onFree: (() -> Unit)? = null
        val actions = mutableListOf<String>()

        override fun create(ownerId: String, ownerName: String): Long {
            check(ownerId == owner && ownerName.isNotBlank())
            return (++created).toLong()
        }

        override fun dispatch(handle: Long, action: String): String {
            check(handle == created.toLong())
            val parsed = OHJson.Obj(raw(action))
            val type = parsed.text("type")
            actions += type
            when (type) {
                "bind_sync_scope" -> check(parsed.text("scope") == scope.accountID)
                "merge_native_sync" -> merged = parsed.raw("document")
                else -> error("Unexpected cold action")
            }
            return """{"ok":true}"""
        }

        override fun state(handle: Long): String {
            check(handle == created.toLong())
            onState?.invoke()
            val presentation = json("id" to quoted(owner), "owner" to raw("true"), "deleted" to raw("false"))
            val state = OHJson.Obj(json("activeProfileId" to quoted(owner),
                "roster" to json("profiles" to json(owner to presentation)),
                "libraries" to json(owner to raw("{}")),
                "nativeSync" to (normalizedNative ?: requireNotNull(merged))))
            extraState?.let { (key, value) -> state.set(key, value) }
            return OHJson.utf8(state.encoded())
        }

        override fun free(handle: Long) {
            check(handle == created.toLong() && freed < created)
            freed++
            onFree?.invoke()
        }

        override fun hydrate(snapshot: String): Long = error("Selected files cannot hydrate a mounted session")
        override fun resolve(handle: Long, request: String): String? = error("No selected-file resolve")
        override fun delta(handle: Long): String? = error("No selected-file delta or ACK")
    }

    private fun admitted(bytes: ByteArray, bindings: Bindings = Bindings()) {
        val before = bytes.copyOf()
        AccountFileHostAdmission.requireCandidate(bytes, scope, bindings) {}
        assertArrayEquals(before, bytes)
        assertArrayEquals(OHJson.Obj(before).raw("nativeSync"), bindings.merged)
        assertEquals(listOf("bind_sync_scope", "merge_native_sync"), bindings.actions)
        assertEquals(1, bindings.created)
        assertEquals(1, bindings.freed)
    }

    private fun refused(bytes: ByteArray, reason: AccountFileHostAdmission.Reason, bindings: Bindings = Bindings()) {
        val before = bytes.copyOf()
        val error = runCatching {
            AccountFileHostAdmission.requireCandidate(bytes, scope, bindings) {}
        }.exceptionOrNull()
        assertTrue(error is AccountFileHostAdmission.Failure)
        assertEquals(reason, (error as AccountFileHostAdmission.Failure).reason)
        assertFalse(error.message.orEmpty().contains("fixture-hidden"))
        assertArrayEquals(before, bytes)
        assertEquals(bindings.created, bindings.freed)
    }

    private fun roster(): ByteArray = OHJson.array(listOf(
        json("id" to quoted(owner), "name" to quoted("[RD] Synthetic Owner"), "avatar" to quoted("[")),
        json("id" to quoted(child), "name" to quoted("{Family} Synthetic Child"), "avatar" to quoted("{")),
    ))

    private fun settings(payload: ByteArray): ByteArray = json(
        "format" to quoted("vortx-backup"), "schema" to raw("1"), "payloadBase64" to encoded(payload),
        "futureEnvelope" to raw("""{"ordinary":true}"""),
    )

    @Test fun qualifiedLegacyAndNativeNamesKeepTheExactCandidateAndUnknownLexemes() {
        val descriptor = raw("""{"transportUrl":"https://例え.example/manifest.json","name":"[TB⚡] Comet",
            "manifest":{"id":"fixture","version":"1","name":"[RD] [4K] Torrentio","description":"{Public} Manifest"}}""")
        val legacy = json("roster" to roster(),
            "library" to OHJson.array(listOf(
                raw("""{"id":"fixture","type":"movie","name":"[Oshi no Ko]: The Movie"}"""),
                json("id" to quoted("graphemes"), "type" to quoted("movie"),
                    "name" to quoted("[" + "e\u0301".repeat(48) + "] International label")),
            )),
            "addons" to raw("""[{"transportUrl":"HTTPS://example.invalid/manifest.json","name":"[RD] Summary"}]"""))
        val envelope = " \n { \"nativeSync\" : " + OHJson.utf8(native()) + ", \"vortx\" : " + OHJson.utf8(legacy) +
            ", \"future\" : { \"descriptor\" : " + OHJson.utf8(descriptor) +
            ", \"lexemes\":[-0.0,1.2300,9223372036854775807,1e300] } } \n"
        admitted(raw(envelope))
    }

    @Test fun originalAndNormalizedSourcesAreCheckedIndependently() {
        val selected = OHJson.Obj(native()).set("dormant", raw("""{"archive":[{"account":{"kind":"own","value":"fixture-hidden"}}]}""")).encoded()
        val normalizationWouldHide = Bindings().apply { normalizedNative = native() }
        refused(candidate(nativeBytes = selected), AccountFileHostAdmission.Reason.UNSUPPORTED_SOURCE, normalizationWouldHide)
        assertEquals(1, normalizationWouldHide.freed)
        assertArrayEquals(selected, normalizationWouldHide.merged)

        val normalizedOnly = Bindings().apply {
            extraState = "unrelatedSlot" to raw("""{"account":{"kind":"pending_own"}}""")
        }
        refused(candidate(), AccountFileHostAdmission.Reason.UNSUPPORTED_SOURCE, normalizedOnly)
        assertEquals(1, normalizedOnly.freed)
        for (entry in listOf("nativeProviderCredentials" to raw("null"), "ownAccountSourceHistory" to raw("""{"fixture":true}"""),
            "account" to raw("""{"kind":"shared","value":null}"""))) {
            val original = OHJson.Obj(native()).set("dormant", json(entry)).encoded()
            refused(candidate(nativeBytes = original), AccountFileHostAdmission.Reason.UNSUPPORTED_SOURCE)
        }
        val ownerSlot = json(owner to raw("""{"value":{"account":"local_only"}}"""))
        admitted(candidate(nativeBytes = OHJson.Obj(native()).set("dormant", ownerSlot).encoded()))
    }

    @Test fun strictSettingsDataQualifiesRosterAndSeriesAndRecursesIntoPlistValues() {
        val choices = json("fixture-series" to raw("""{"addon":"[TB⚡] Comet","ts":1.25,"resolution":1080}"""))
        val array = requireNotNull(BinaryPlist.encode(listOf("ordinary", true)))
        val scalar = raw("<plist><integer>3</integer></plist>")
        val domain = linkedMapOf("stremiox.profiles" to roster(), "stremiox.seriesSourceSticky.$child" to choices,
            "futureArray" to array, "futureScalar" to scalar)
        val backup = settings(requireNotNull(BinaryPlist.encode(domain)))
        admitted(candidate("settings" to encoded(backup), "future" to encoded(backup),
            "binary" to encoded(requireNotNull(BinaryPlist.encode(mapOf("ordinary" to "家族"))))))
    }

    @Test fun qualifiedContextsDoNotFlowIntoSiblingsWrongPathsOrDecodedText() {
        val hidden = OHJson.b64(raw("""{"token":"fixture-hidden"}"""))
        for (title in listOf("[RD] - $hidden", "[RD]: \uFEFF$hidden", "[true] {\"token\":\"fixture-hidden\"}",
            "[RD]no separator", "[RD]\uFEFF[4K] Comet", "[R\u202ED] Name",
            "[" + "e\u0301".repeat(65) + "] Name", "[RD] [4K] {\"token\":\"fixture-hidden\"}",
            OHJson.b64(raw("[RD]")))) {
            val legacy = json("library" to OHJson.array(listOf(json("id" to quoted("fixture"),
                "type" to quoted("movie"), "name" to quoted(title)))))
            refused(candidate("vortx" to legacy), AccountFileHostAdmission.Reason.INVALID_HOST)
        }
        val stray = raw("""{"id":"$owner","name":"[Opaque] Fixture","avatar":"A"}""")
        val sibling = raw("""[{"id":"$owner","name":"[RD] Owner","avatar":"A","future":{"name":"[Opaque] Fixture"}}]""")
        refused(candidate("future" to stray), AccountFileHostAdmission.Reason.INVALID_HOST)
        refused(candidate("vortx" to json("roster" to sibling)), AccountFileHostAdmission.Reason.INVALID_HOST)
        val fakeData = requireNotNull(BinaryPlist.encode(mapOf("unrelated" to roster())))
        refused(candidate("settings" to encoded(settings(fakeData))), AccountFileHostAdmission.Reason.INVALID_HOST)

        val unqualifiedNative = OHJson.Obj(native()).set("profiles",
            json(owner to json("profile" to profile(owner, "[RD] Owner")))).encoded()
        refused(candidate(nativeBytes = unqualifiedNative), AccountFileHostAdmission.Reason.INVALID_HOST)
    }

    @Test fun credentialsStayInTheAuthenticatedOriginalAndShapeChecksRemainStrict() {
        val providerKeys = raw("""{"provider":"fixture-hidden","metadata":{"alias":"fixture-hidden"}}""")
        val configuredIdentity = json("https://例え.example/credential_token" to raw("""{"ordinary":true}"""))
        val credentialPlist = requireNotNull(BinaryPlist.encode(mapOf("password" to "fixture-hidden", "ordinary" to true)))
        admitted(candidate("apiKeys" to providerKeys, "configured" to configuredIdentity,
            "future" to encoded(credentialPlist), "futureText" to encoded(raw("""{"token":"fixture-hidden","ordinary":true}"""))))
        for (wrong in listOf("null", "[]", """{"provider":{}}""", """{"metadata":{"alias":false}}""",
            """{"metadata":null}""")) {
            refused(candidate("apiKeys" to raw(wrong)), AccountFileHostAdmission.Reason.INVALID_HOST)
        }
        val suspicious = requireNotNull(BinaryPlist.encode(mapOf("unknownCredential" to "fixture-hidden", "日本" to true)))
        refused(candidate("future" to encoded(suspicious)), AccountFileHostAdmission.Reason.INVALID_HOST)
        refused(candidate("future" to encoded(raw("""{"unsupported_token":"fixture-hidden"}"""))),
            AccountFileHostAdmission.Reason.INVALID_HOST)
    }

    @Test fun strictEncodedViewsRejectMalformedDuplicateAndOpaqueValues() {
        for (charsetName in listOf("UTF-8", "UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE")) {
            val charset = charset(charsetName)
            val safe = """{"ordinary":"家族","exact":1.2300}""".toByteArray(charset)
            val hidden = """{"ordinary":"家族","unknownSecret":"fixture-hidden"}""".toByteArray(charset)
            val duplicate = """{"é":true,"e\u0301":false}""".toByteArray(charset)
            admitted(candidate("future" to encoded(safe)))
            refused(candidate("future" to encoded(hidden)), AccountFileHostAdmission.Reason.INVALID_HOST)
            refused(candidate("future" to encoded(duplicate)), AccountFileHostAdmission.Reason.INVALID_HOST)
        }
        val invalidUtf8Json = raw("{\"ordinary\":\"") + byteArrayOf(0xff.toByte())
        val corruptBinary = raw("bplist00") + byteArrayOf(0xff.toByte())
        for (bad in listOf(invalidUtf8Json, corruptBinary, raw("""{"token":"unfinished"""),
            raw("( ordinary, other )"))) {
            refused(candidate("future" to encoded(bad)), AccountFileHostAdmission.Reason.INVALID_HOST)
        }
        val opaqueDomain = requireNotNull(BinaryPlist.encode(mapOf("unknown" to byteArrayOf(0, 0xff.toByte(), 0))))
        refused(candidate("settings" to encoded(settings(opaqueDomain))), AccountFileHostAdmission.Reason.INVALID_HOST)
        val external = raw("""<!DOCTYPE plist SYSTEM "file:///never-open"><plist><dict/></plist>""")
        refused(candidate("settings" to encoded(settings(external))), AccountFileHostAdmission.Reason.INVALID_HOST)
        val cycle = raw("bplist00") + byteArrayOf(0xa1.toByte(), 0, 8, 0, 0, 0, 0, 0, 0, 1, 1) +
            ByteArray(7) + byteArrayOf(1) + ByteArray(8) + ByteArray(7) + byteArrayOf(10)
        refused(candidate("future" to encoded(cycle)), AccountFileHostAdmission.Reason.INVALID_HOST)
    }

    @Test fun encodedOpenStepEntryPrefixesAreRefusedWithoutRejectingOrdinarySemicolons() {
        fun tagged(payload: ByteArray): ByteArray {
            val label = "[RD] " + OHJson.b64(payload)
            val row = json("id" to quoted("fixture"), "type" to quoted("movie"), "name" to quoted(label))
            return candidate("vortx" to json("library" to OHJson.array(listOf(row))))
        }

        val encodedCarriers = listOf(
            "token;",
            "futureSecret;",
            "label; futureSecret;",
            "'futureSecret';",
            "\"\\U0074oken\";",
            " /* comment */ token;",
            " // comment\r\nfutureSecret;",
            "token /* comment */ ; // trailing comment",
            "label; // separating comment\u2028futureSecret;",
            "futureSecret = value; /* trailing comment */",
            "token; label=value; /* trailing comment */",
            "label=value; // separating comment\nfutureSecret;",
            "\"futureSecret\" /* between key and assignment */ = value; // trailing comment",
            "'futureSecret' // between key and assignment\u2028 = value; /* trailing comment */",
            "futureSecret =",
            "token;@",
        )
        for (carrier in encodedCarriers) {
            val payload = raw(carrier)
            refused(candidate("future" to encoded(payload)), AccountFileHostAdmission.Reason.INVALID_HOST)
            refused(tagged(payload), AccountFileHostAdmission.Reason.INVALID_HOST)
        }
        for (encoding in listOf("UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE")) {
            refused(candidate("future" to encoded("token;".toByteArray(charset(encoding)))),
                AccountFileHostAdmission.Reason.INVALID_HOST)
        }
        for (ordinary in listOf(raw("Scene; final chapter"), raw("The first scene; final chapter"), raw("A two-word label;"),
            raw("family; International viewing notes."), raw("International viewing notes; family = all."),
            raw("https://example.invalid/path?key=value;other=2"),
            byteArrayOf(0x01, '='.code.toByte(), ';'.code.toByte(), 0xff.toByte()))) {
            admitted(candidate("future" to encoded(ordinary)))
            admitted(tagged(ordinary))
        }
    }

    @Test fun typedIdentitiesDoNotExemptOrdinarySiblings() {
        val event = raw("""{"schemaVersion":1,"counter":"0","eventId":"${digest.take(32)}",
            "fingerprint":"$digest","observedClock":0}""")
        admitted(candidate("event" to event, "typedCarrierFingerprint" to quoted(digest)))
        refused(candidate("future" to quoted(digest)), AccountFileHostAdmission.Reason.INVALID_HOST)
        refused(candidate("event" to OHJson.Obj(event).set("extra", raw("true")).encoded()),
            AccountFileHostAdmission.Reason.INVALID_HOST)
        refused(candidate("event" to OHJson.Obj(event).set("counter", quoted("00")).encoded()),
            AccountFileHostAdmission.Reason.INVALID_HOST)
    }

    @Test fun rawMalformedScopeAndResourceLimitsRefuseBeforeBinding() {
        val malformed = Bindings()
        refused(raw("""{"nativeSync":{},"escaped":0,"\u0065scaped":1}"""),
            AccountFileHostAdmission.Reason.MALFORMED, malformed)
        assertEquals(0, malformed.created)
        val wrongScope = Bindings()
        val native = OHJson.Obj(native()).set("scope", quoted("account.other")).encoded()
        refused(candidate(nativeBytes = native), AccountFileHostAdmission.Reason.UNSUPPORTED_NATIVE, wrongScope)
        assertEquals(0, wrongScope.created)
        val over = Bindings()
        refused(ByteArray(AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES + 1), AccountFileHostAdmission.Reason.LIMIT, over)
        assertEquals(0, over.created)
        val nested = raw("[".repeat(70) + "null" + "]".repeat(70))
        val depth = Bindings()
        refused(candidate("future" to nested), AccountFileHostAdmission.Reason.LIMIT, depth)
        assertEquals(0, depth.created)
    }

    @Test fun retirementBeforeAllocationAfterNativeReturnAndDuringInspectionClosesOnce() {
        val before = Bindings()
        val cancelBefore = runCatching {
            AccountFileHostAdmission.requireCandidate(candidate(), scope, before) { throw CancellationException("fixture") }
        }.exceptionOrNull()
        assertTrue(cancelBefore is CancellationException)
        assertEquals(0, before.created)

        var current = true
        val after = Bindings().apply { onState = { current = false } }
        val cancelAfter = runCatching {
            AccountFileHostAdmission.requireCandidate(candidate(), scope, after) {
                if (!current) throw CancellationException("fixture")
            }
        }.exceptionOrNull()
        assertTrue(cancelAfter is CancellationException)
        assertEquals(1, after.freed)

        var released = false
        var checksAfterRelease = 0
        val inspection = Bindings().apply { onFree = { released = true } }
        val cancelInspection = runCatching {
            AccountFileHostAdmission.requireCandidate(candidate(), scope, inspection) {
                if (released && ++checksAfterRelease == 3) throw CancellationException("fixture")
            }
        }.exceptionOrNull()
        assertTrue(cancelInspection is CancellationException)
        assertEquals(1, inspection.freed)
    }
}
