package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.VortXSyncDoc
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual pure helper/parser/profile codec, synthetic source bytes. No JNI, transport, checkpoint,
 * authenticated account, durable receipt, or device proof. Authored but UNRUN in this packet. */
class NativeWebsiteRosterProjectionTest {
    private fun b(value: String) = value.toByteArray(Charsets.UTF_8)
    private fun project(value: String) = NativeWebsiteRosterProjection.project(b(value))
    private fun accepted(value: String) = requireNotNull(project(value))

    @Test fun `each Apple website channel independently admits a detached full owner roster`() {
        val sources = listOf(
            """{"addons":[]}""", """{"apiKeys":{}}""", """{"addonOrder":[]}""",
            """{"removedAddons":{}}""", """{"webAddonRemovals":[]}""",
            """{"vortx":{"deletedAddons":[]}}""", """{"vortx":{"deletedAddonsTs":{}}}""",
            """{"webProgress":{"owner":[]}}""", """{"webProgress":{"removed":{"owner":[]}}}""",
        )
        for (source in sources) {
            val candidate = OHJson.Obj(accepted(source))
            val vortx = candidate.obj("vortx")
            val rows = OHJson.array(vortx.raw("roster"))
            assertEquals(source, 1, rows.size)
            val row = OHJson.Obj(rows.single())
            assertEquals(UserProfile.OWNER_ID, row.text("id"))
            assertEquals("Main", row.text("name"))
            assertEquals("🍿", row.text("avatar"))
            assertArrayEquals(b("true"), row.raw("isOwner"))
            assertArrayEquals(b("false"), row.raw("usesOwnAccount"))
            assertArrayEquals(b("false"), row.raw("isKids"))
            assertArrayEquals(b("false"), row.raw("familyEdit"))
            assertTrue(row.obj("addonPreferences").keys.isEmpty())
            assertArrayEquals(b("0"), vortx.raw("rosterModified"))
            assertFalse(candidate.keys.contains("nativeSync"))
            assertFalse(candidate.keys.contains("nativeAccountBootstrap"))
        }
    }

    @Test fun `new row uses the actual full profile codec without tolerant input reconstruction`() {
        val row = OHJson.array(OHJson.Obj(accepted("""{"addons":[]}""")).obj("vortx").raw("roster")).single()
        val expected = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
        val expectedWire = expected.encode().put("addonPreferences", JSONObject()).toString().toByteArray(Charsets.UTF_8)
        assertTrue(OHJson.equal(expectedWire, row))
        assertEquals(expected, UserProfile.decodeProfile(JSONObject(OHJson.utf8(row))))
    }

    @Test fun `all unedited account and nested vortx values retain their exact raw tokens`() {
        val original = b("""{
          "addons":[{"transportUrl":"https://fixture.invalid/config/manifest.json","name":"[RD] fixture","future":1.2300e+2}],
          "apiKeys":{"tmdb":"synthetic-only","metadata":{"future":-0.0}},
          "addonOrder":["https://fixture.invalid/config/manifest.json"],
          "removedAddons":{"fixture":1.0000},
          "webProgress":{"owner":[],"byProfile":{},"removed":{"byProfile":{}},"future":9007199254740993},
          "futureRoot":{"huge":18446744073709551615,"fraction":9007199254740992.1,"text":"\u0061\/b","array":[-0,1.2300e+2]},
          "vortx":{"deletedAddons":[],"deletedAddonsTs":{},"futureNested":{"settings":null,"roster":[1],"zero":-0.0,"large":18446744073709551615}}
        }""")
        val before = original.copyOf()
        val source = OHJson.Obj(original)
        val candidate = OHJson.Obj(requireNotNull(NativeWebsiteRosterProjection.project(original)))
        assertEquals(source.keys, candidate.keys)
        for (key in source.keys - "vortx") assertArrayEquals(key, source.raw(key), candidate.raw(key))
        val oldVortx = source.obj("vortx"); val newVortx = candidate.obj("vortx")
        assertEquals(oldVortx.keys + setOf("roster", "rosterModified"), newVortx.keys)
        for (key in oldVortx.keys) assertArrayEquals(key, oldVortx.raw(key), newVortx.raw(key))
        assertArrayEquals(before, original)
    }

    @Test fun `output is detached deterministic and never mutates caller input`() {
        val original = b("""{ "apiKeys" : {}, "future" : [1.000,-0.0] }""")
        val before = original.copyOf()
        val first = requireNotNull(NativeWebsiteRosterProjection.project(original))
        val second = requireNotNull(NativeWebsiteRosterProjection.project(original))
        assertNotSame(first, second)
        assertArrayEquals(first, second)
        first.fill(0)
        assertArrayEquals(before, original)
        assertArrayEquals(second, requireNotNull(NativeWebsiteRosterProjection.project(original)))
        // A candidate is now a real roster carrier, so it cannot be projected a second time.
        assertNull(NativeWebsiteRosterProjection.project(second))
    }

    @Test fun `empty unknown-only and wrong-shaped website channels grant no owner`() {
        val sources = listOf("{}", """{"future":[],"vortx":{"future":{}}}""",
            """{"addons":null}""", """{"addons":{}}""", """{"apiKeys":[]}""",
            """{"addonOrder":"[]"}""", """{"removedAddons":[]}""", """{"webAddonRemovals":{}}""",
            """{"vortx":{"deletedAddons":{}}}""", """{"vortx":{"deletedAddonsTs":[]}}""",
            """{"webProgress":{"owner":{}}}""", """{"webProgress":{"removed":{"owner":{}}}}""",
            """{"webProgress":{"byProfile":{},"removed":{"byProfile":{}}}}""")
        for (source in sources) assertNull(source, project(source))
    }

    @Test fun `present app and native carriers refuse even when null empty or malformed`() {
        val carriers = setOf("settings", "nativeSync", "nativeAccountBootstrap", "nativeHostPreferences",
            "nativeOwnerHistorySources", "nativeProviderCredentials", "profileEdits", "profileEditEvents",
            "profileEditResults", "webAddonEdits", "websiteAddonEditPending") + nativeMigrationSidecars
        for (carrier in carriers) for (value in listOf("null", "{}", "[]", "0", "false", "\"opaque\"")) {
            val source = OHJson.Obj().set("addons", b("[]")).set(carrier, b(value)).encoded()
            assertNull("$carrier=$value", NativeWebsiteRosterProjection.project(source))
        }
        assertNull(project("""{"addons":[],"\u0073ettings":null}"""))
    }

    @Test fun `present vortx profile ownership carriers are never replaced or inferred away`() {
        val carriers = listOf("roster", "rosterModified", "profiles", "byProfile", "deletedProfiles", "activeProfile",
            "ownerWatched", "library", "deletedLibrary", "deletedLibraryTs", "updatedAt", "addons", "addonsOwnedAt", "mediaServers", "iptv")
        for (carrier in carriers) for (value in listOf("null", "{}", "[]", "0", "false", "\"opaque\"")) {
            val source = OHJson.Obj().set("apiKeys", b("{}")).set("vortx", OHJson.Obj().set(carrier, b(value)).encoded()).encoded()
            assertNull("$carrier=$value", NativeWebsiteRosterProjection.project(source))
        }
        assertNull(project("""{"addons":[],"vortx":{"roster":[{"id":"foreign","isOwner":true}]}}"""))
        assertNull(project("""{"addons":[],"vortx":{"\u0072oster":null}}"""))
    }

    @Test fun `invalid namespaces and profile-specific progress cannot hide behind a website channel`() {
        for (value in listOf("null", "[]", "0", "false", "\"opaque\"")) {
            assertNull(project("""{"addons":[],"vortx":$value}"""))
            assertNull(project("""{"addons":[],"webProgress":$value}"""))
            assertNull(project("""{"addons":[],"webProgress":{"removed":$value}}"""))
        }
        for (value in listOf("null", "[]", "0", "false", "\"opaque\"", "{\"profile\":[]}")) {
            assertNull(project("""{"addons":[],"webProgress":{"byProfile":$value}}"""))
            assertNull(project("""{"addons":[],"webProgress":{"removed":{"byProfile":$value}}}"""))
        }
        assertNotNull(project("""{"addons":[],"webProgress":{"byProfile":{},"removed":{"byProfile":{}}}}"""))
    }

    @Test fun `unknown nested names do not become profile ownership evidence`() {
        val source = """{"addons":[],"future":{"settings":null,"nativeSync":{},"byProfile":{"unknown":[]}},"vortx":{"future":{"roster":null}}}"""
        val original = OHJson.Obj(b(source)); val candidate = OHJson.Obj(accepted(source))
        assertArrayEquals(original.raw("future"), candidate.raw("future"))
        assertArrayEquals(original.obj("vortx").raw("future"), candidate.obj("vortx").raw("future"))
    }

    @Test fun `classification does not silently repair unrelated malformed channel content`() {
        // Apple classifies by at least one known channel shape; full channel-content admission is
        // still owed by the real native receive. No unrelated input is removed or defaulted here.
        val original = OHJson.Obj(b("""{"apiKeys":{},"addons":null,"removedAddons":["future"],"future":-0}"""))
        val candidate = OHJson.Obj(requireNotNull(NativeWebsiteRosterProjection.project(original.encoded())))
        for (key in original.keys) assertArrayEquals(key, original.raw(key), candidate.raw(key))
    }

    @Test fun `strict ingress rejects duplicate keys malformed JSON and invalid Unicode`() {
        val invalid = listOf(
            "[]", "null", """{"addons":[],"addons":[]}""",
            """{"addons":[],"future":{"x":1,"x":2}}""",
            """{"addons":[],"future":{"é":1,"e\u0301":2}}""",
            """{"addons":[],"future":"\uD800"}""",
            """{"addons":[],"future":01}""", """{"addons":[]} trailing""",
        )
        for (source in invalid) {
            val result = runCatching { project(source) }
            assertTrue("Invalid input must throw: $source", result.isFailure)
        }
        val invalidUtf8 = b("{\"addons\":[],\"future\":\"") + byteArrayOf(0xc0.toByte(), 0xaf.toByte()) + b("\"}")
        val result = runCatching { NativeWebsiteRosterProjection.project(invalidUtf8) }
        assertTrue(result.isFailure)
    }

    @Test fun `existing parser nesting and input byte budgets apply before projection`() {
        val deep = "{\"addons\":[],\"future\":" + "[".repeat(130) + "0" + "]".repeat(130) + "}"
        val depthResult = runCatching { project(deep) }
        assertTrue(depthResult.isFailure)
        val oversized = ByteArray(OHJson.MAX + 1)
        val sizeResult = runCatching { NativeWebsiteRosterProjection.project(oversized) }
        assertTrue(sizeResult.isFailure)
    }

    @Test fun `ordinary receive snapshot and full roster resolver accept the generated owner without changing outbound bytes`() {
        val original = b("""{ "addons":[], "future":"\u0061", "vortx":{"futureNumber":1.2300e+2} }""")
        val before = original.copyOf()
        val candidate = requireNotNull(NativeWebsiteRosterProjection.project(original))
        val candidateBefore = candidate.copyOf()
        val snapshot = nativeWatchedDocumentSnapshot(NativeProfileOverlayWitness.parseAccountDocument(candidate))
        try {
            val document = NativeProfileOverlayWitness.parseDocument(snapshot)
            val parsed = VortXSyncDoc.parse(document)
            assertTrue(parsed.rosterIsLossless)
            val resolved = SettingsBackup.resolveRosterForPull(document.opt("settings"),
                parsed.roster.takeIf { parsed.rosterIsLossless }, parsed.rosterModifiedSeconds, parsed.rosterIsLossless)
            val roster = requireNotNull(resolved.roster)
            assertEquals(1, roster.size)
            assertEquals(UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true), roster.single())
            assertTrue(roster.single().isOwner)
            assertEquals(UserProfile.OWNER_ID, roster.single().id)
            assertEquals(0.0, requireNotNull(resolved.modifiedSeconds), 0.0)
            val rawCandidate = OHJson.Obj(candidate)
            assertArrayEquals(OHJson.Obj(original).raw("future"), rawCandidate.raw("future"))
            assertArrayEquals(OHJson.Obj(original).obj("vortx").raw("futureNumber"), rawCandidate.obj("vortx").raw("futureNumber"))
            // The actual snapshot intentionally normalizes this string. It must never replace
            // the exact projected bytes returned by the helper or later submitted for CAS.
            assertFalse(rawCandidate.raw("future").contentEquals(OHJson.Obj(snapshot).raw("future")))
            assertArrayEquals(candidateBefore, candidate)
            assertArrayEquals(before, original)
        } finally { snapshot.fill(0) }
    }

    @Test fun `depth 65 through 128 cannot escape the ordinary receive snapshot limit`() {
        fun source(depth: Int) = b("{\"addons\":[],\"future\":" + "[".repeat(depth - 1) + "0" + "]".repeat(depth - 1) + "}")
        // These controls are within both the raw parser and authenticated account-ingress bounds.
        // V1 returned a candidate even though ordinary native apply's snapshot later refused it.
        for (depth in listOf(65, 96, 128)) {
            val original = source(depth)
            OHJson.Obj(original)
            NativeProfileOverlayWitness.parseAccountDocument(original)
            val ordinary = runCatching { nativeWatchedDocumentSnapshot(NativeProfileOverlayWitness.parseAccountDocument(original)) }
            assertTrue("ordinary snapshot must reject depth $depth", ordinary.isFailure)
            val projected = runCatching { NativeWebsiteRosterProjection.project(original) }
            assertTrue("projection must reject depth $depth before returning", projected.isFailure)
        }
        assertNotNull(NativeWebsiteRosterProjection.project(source(64)))
    }

    @Test fun `100k node budget applies to projected output including the new owner row`() {
        fun source(items: Int) = b("{\"addons\":[],\"future\":[" + List(items) { "0" }.joinToString(",") + "]}")
        // Five structural/key nodes plus the array items: the original itself has exactly
        // 100,000 nodes and passes ordinary parsing, but adding the roster exceeds the budget.
        val atLimit = source(99_995)
        NativeProfileOverlayWitness.parseDocument(atLimit)
        val projectedAtLimit = runCatching { NativeWebsiteRosterProjection.project(atLimit) }
        assertTrue("projected additions must count against the node budget", projectedAtLimit.isFailure)

        val beyondLimit = source(99_996)
        OHJson.Obj(beyondLimit)
        NativeProfileOverlayWitness.parseAccountDocument(beyondLimit)
        val ordinary = runCatching { nativeWatchedDocumentSnapshot(NativeProfileOverlayWitness.parseAccountDocument(beyondLimit)) }
        assertTrue(ordinary.isFailure)
        val projectedBeyondLimit = runCatching { NativeWebsiteRosterProjection.project(beyondLimit) }
        assertTrue(projectedBeyondLimit.isFailure)
        assertNotNull(NativeWebsiteRosterProjection.project(source(98_000)))
    }
}
