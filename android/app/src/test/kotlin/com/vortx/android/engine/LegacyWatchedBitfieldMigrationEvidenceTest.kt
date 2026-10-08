package com.vortx.android.engine

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

class LegacyWatchedBitfieldMigrationEvidenceTest {
    private val profile = "00000000-0000-0000-0000-00000000A11C"
    private val ownProfile = "10000000-0000-0000-0000-000000000001"
    private val manifest = """{"id":"catalog","name":"Original catalog","version":"1.0.0"}""".toByteArray()
    private val addon = LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon("https://catalog.example/manifest.json", manifest)

    @Test fun `captures source bound raw metadata evidence and bare watched IDs`() = runBlocking {
        val source = sharedSource(); val metadata = metadata()
        val scope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile, null, profile)
        var requests = 0
        val evidence = LegacyWatchedBitfieldMigrationEvidence.capture(scope, source,
            LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { true }) { request ->
                requests += 1
                LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata)
            }
        assertEquals(1, requests)
        assertEquals((1..5).map { "tt2934286:1:$it" }, evidence.watchedVideoIDs)
        assertArrayEquals(source, evidence.source); assertArrayEquals(metadata, evidence.metadata)
        assertEquals(digest(source), evidence.sourceSHA256); assertEquals(digest(metadata), evidence.metadataSHA256)
        assertEquals("/vortx/library/0", evidence.rowLocator.pointer)
        assertEquals((1..5).map { "tt2934286:1:$it" }, evidence.inventory.map { it.id })
        assertEquals(listOf(1_104_537_600_000L, 1_104_624_000_123L, 1_104_710_400_000L, 1_104_796_800_000L, 1_104_883_200_000L), evidence.inventory.map { it.releasedMs })
    }

    @Test fun `rejects descriptor mismatch metadata mismatch and duplicate raw keys`() = runBlocking {
        val scope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile, null, profile)
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope,
                """{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[]}}""".toByteArray(),
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { true }) { request ->
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
                }
        }
        val numericAddon = LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon("https://catalog.example/manifest.json", """{"id":"catalog","name":"Original catalog","rank":1}""".toByteArray())
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope,
                """{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","rank":1.0000000000000001}}]}}""".toByteArray(),
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), numericAddon, { true }) { request -> LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata()) }
        }
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope, sharedSource(),
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { true }) { request ->
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, """{"meta":{"id":"tt2934286","type":"series","videos":[{"id":"tt2934286:1:1","season":1.0000000000000001,"episode":1}]}}""".toByteArray())
                }
        }
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope, sharedSource(),
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { true }) { request ->
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, """{"meta":{"id":"tt2934286","type":"series","videos":[{"id":"tt2934286:1:1","season":1,"episode":1,"released":"2005-01-01T00:00:00.0001Z"}]}}""".toByteArray())
                }
        }
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope, sharedSource(),
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { true }) { request ->
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, """{"meta":{"id":"other","type":"series","videos":[]}}""".toByteArray())
                }
        }
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope, """{"vortx":{"library":[],"library":[]}}""".toByteArray(),
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { true }) { request ->
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
                }
        }
    }

    @Test fun `post fetch account admission is required`() = runBlocking {
        val scope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile, null, profile)
        var current = true
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope, sharedSource(),
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { current }) { request ->
                    current = false
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
                }
        }
    }

    /** Invalid scalars each alter a complete bitmap-addressable inventory, never just its anchor. */
    @Test fun `rejects strict scalar and utf8 identity mismatches after a valid inventory reaches them`() = runBlocking {
        val scope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile, null, profile)
        val seasonField = "\"season\":1,\"episode\":1,\"released\":\"2005-01-01T01:00:00+01:00\""
        expectFailure {
            capture(scope, sharedSource(), mutatedMetadata(seasonField, "\"season\":1.0000000000000001,\"episode\":1,\"released\":\"2005-01-01T01:00:00+01:00\""))
        }
        expectFailure {
            capture(scope, sharedSource(), mutatedMetadata("\"released\":\"2005-01-01T01:00:00+01:00\"", "\"released\":\"2005-01-01T00:00:00.0001Z\""))
        }
        expectFailure {
            capture(scope, sharedSource(), mutatedMetadata("\"released\":\"2005-01-01T01:00:00+01:00\"", "\"released\":\"10000-01-01T00:00:00Z\""))
        }

        val reorderedAddon = LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
            "https://catalog.example/manifest.json", """{"version":"1.0.0","name":"Original catalog","id":"catalog"}""".toByteArray())
        val reordered = LegacyWatchedBitfieldMigrationEvidence.capture(scope, sharedSource(),
            LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), reorderedAddon, { true }) { request ->
                LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
            }
        assertEquals(5, reordered.watchedVideoIDs.size)

        val precomposedAddon = LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
            "https://catalog.example/manifest.json", """{"id":"catalog","name":"é","version":"1.0.0"}""".toByteArray())
        val decomposedManifestSource = sharedSource().toString(Charsets.UTF_8)
            .replace("Original catalog", "e\\u0301").toByteArray()
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(scope, decomposedManifestSource,
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), precomposedAddon, { true }) { request ->
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
                }
        }

        val unicodeSource = """{"vortx":{"library":[{"id":"\u00e9","type":"series","watched":"\u00e9:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}}""".toByteArray()
        val unicodeMetadata = metadata().toString(Charsets.UTF_8)
            .replace("tt2934286", "\\u00e9")
            .replace("\"meta\":{\"id\":\"\\u00e9", "\"meta\":{\"id\":\"e\\u0301").toByteArray()
        expectFailure { capture(scope, unicodeSource, unicodeMetadata) }
    }

    @Test fun `accepts authenticated legacy root source with its exact root registry`() = runBlocking {
        val source = """{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}""".toByteArray()
        val evidence = LegacyWatchedBitfieldMigrationEvidence.capture(LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile, null, profile), source,
            LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedLegacyRootLibrary(0), addon, { true }) { request ->
                LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
            }
        assertEquals("/library/0", evidence.rowLocator.pointer)
        assertEquals(5, evidence.watchedVideoIDs.size)
    }

    @Test fun `canonicalizes only complete profile UUIDs`() {
        assertEquals(profile, LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile.lowercase(), null, profile).profileID)
        try { LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", "00000000-0000-0000-0000-1", null, profile) ; fail("Expected complete UUID rejection")
        } catch (_: IllegalArgumentException) { }
    }

    @Test fun `own account source requires a verified streaming uid`() = runBlocking {
        val library = Base64.getEncoder().encodeToString("""{"result":[{"_id":"tt2934286","type":"series","state":{"watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}}]}""".toByteArray())
        val addons = Base64.getEncoder().encodeToString("""{"result":{"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}}""".toByteArray())
        val source = """{"schemaVersion":1,"libraryResponseBase64":"$library","addonsResponseBase64":"$addons","profileOverlayBase64":"e30="}""".toByteArray()
        expectFailure {
            LegacyWatchedBitfieldMigrationEvidence.capture(LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", ownProfile, null, profile), source,
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.OwnAccountLibraryResponse(0), addon, { true }) { request ->
                    LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
                }
        }
        val evidence = LegacyWatchedBitfieldMigrationEvidence.capture(LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", ownProfile, "uid-a", profile), source,
            LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.OwnAccountLibraryResponse(0), addon, { true }) { request ->
                LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata())
            }
        assertEquals(5, evidence.watchedVideoIDs.size)
    }

    @Test fun `takes immutable evidence snapshots across and after fetch`() = runBlocking {
        val source = sharedSource(); val sourceBefore = source.copyOf()
        val manifestInput = manifest.copyOf()
        val mutableAddon = LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon("https://catalog.example/manifest.json", manifestInput)
        val metadata = metadata(); val metadataBefore = metadata.copyOf()
        val evidence = LegacyWatchedBitfieldMigrationEvidence.capture(LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile, null, profile), source,
            LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), mutableAddon, { true }) { request ->
                source[0] = 'x'.code.toByte(); manifestInput[0] = 'x'.code.toByte(); metadata[0] = 'x'.code.toByte()
                LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadataBefore)
            }
        assertArrayEquals(sourceBefore, evidence.source)
        assertArrayEquals(metadataBefore, evidence.metadata)
        val leakedSource = evidence.source; leakedSource[0] = 'x'.code.toByte()
        val leakedMetadata = evidence.metadata; leakedMetadata[0] = 'x'.code.toByte()
        assertArrayEquals(sourceBefore, evidence.source); assertArrayEquals(metadataBefore, evidence.metadata)
        assertEquals(digest(sourceBefore), evidence.sourceSHA256); assertEquals(digest(metadataBefore), evidence.metadataSHA256)
        assertArrayEquals(manifest, evidence.addon.manifest)
    }

    @Test fun `replays exact current and historical owner rows with explicit resolved owner`() {
        val owner = "00000000-0000-0000-0000-00000000BEEF"
        val source = JSONObject(sharedSource().toString(Charsets.UTF_8))
        val vortx = source.getJSONObject("vortx")
        val row = vortx.getJSONArray("library").getJSONObject(0)
        vortx.put("byProfile", JSONObject().put(owner, JSONObject().put("ownerHistory", JSONArray().put(row)))
            .put(profile, JSONObject().put("ownerHistory", JSONArray().put(row))))
        val bytes = source.toString().toByteArray()
        val scope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", owner, null, owner)
        for (sourceID in listOf(owner, profile)) {
            val locator = LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerHistory(0, sourceID)
            LegacyWatchedBitfieldMigrationEvidence.validateSource(scope, bytes, locator)
            val evidence = LegacyWatchedBitfieldMigrationEvidence.replay(scope, bytes, locator, addon, metadata()) { true }
            assertEquals(5, evidence.watchedVideoIDs.size)
            assertArrayEquals(bytes, evidence.source)
        }
        try {
            LegacyWatchedBitfieldMigrationEvidence.validateSource(scope, bytes,
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerHistory(0, ownProfile))
            fail("Foreign history must not be attributed to owner")
        } catch (_: IllegalArgumentException) { }
    }

    @Test fun `own overlay history requires exact authenticated scope and original own descriptor`() {
        val shared = JSONObject(sharedSource().toString(Charsets.UTF_8)).getJSONObject("vortx")
        val rows = shared.getJSONArray("library")
        val overlay = JSONObject().put("vortx", JSONObject().put("byProfile", JSONObject().put(ownProfile,
            JSONObject().put("library", rows).put("ownerHistory", rows))))
        fun encoded(value: JSONObject) = Base64.getEncoder().encodeToString(value.toString().toByteArray())
        val source = JSONObject().put("schemaVersion", 2)
            .put("libraryResponseBase64", encoded(JSONObject().put("result", JSONArray())))
            .put("addonsResponseBase64", encoded(JSONObject().put("result", JSONObject().put("addons", shared.getJSONArray("addons")))))
            .put("profileOverlayBase64", encoded(overlay)).toString().toByteArray()
        val scope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", ownProfile, "uid-a", profile)
        for (locator in listOf(LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.OwnAccountProfileLibrary(0),
                              LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.OwnAccountOwnerHistory(0))) {
            val evidence = LegacyWatchedBitfieldMigrationEvidence.replay(scope, source, locator, addon, metadata()) { true }
            assertEquals(5, evidence.watchedVideoIDs.size)
        }
        val wrongScope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", "20000000-0000-0000-0000-000000000002", "uid-a", profile)
        try { LegacyWatchedBitfieldMigrationEvidence.validateSource(wrongScope, source,
            LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.OwnAccountProfileLibrary(0)); fail("Foreign own overlay must fail")
        } catch (_: IllegalArgumentException) { }
    }

    @Test fun `original manifest extraction retains exact number lexemes`() {
        val source = sharedSource().toString(Charsets.UTF_8).replace("\"version\":\"1.0.0\"", "\"version\":\"1.0.0\",\"rank\":1.0000000000000001")
            .toByteArray()
        val locator = LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0)
        val original = LegacyWatchedBitfieldMigrationEvidence.originalAddons(source, locator).single()
        org.junit.Assert.assertTrue(original.manifest.toString(Charsets.UTF_8).contains("1.0000000000000001"))
        val scope = LegacyWatchedBitfieldMigrationEvidence.Scope("account-a", profile, null, profile)
        assertEquals(5, LegacyWatchedBitfieldMigrationEvidence.replay(scope, source, locator, original, metadata()) { true }.watchedVideoIDs.size)
    }

    private fun sharedSource() = """{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}}""".toByteArray()
    private fun metadata() = """{"meta":{"id":"tt2934286","type":"series","videos":[{"id":"tt2934286:1:5","season":1,"episode":5,"released":"2005-01-05T00:00:00Z"},{"id":"tt2934286:1:1","season":1,"episode":1,"released":"2005-01-01T01:00:00+01:00"},{"id":"tt2934286:1:2","season":1,"episode":2,"released":"2005-01-02T00:00:00.123Z"},{"id":"tt2934286:1:3","season":1,"episode":3,"released":"2005-01-03T00:00:00Z"},{"id":"tt2934286:1:4","season":1,"episode":4,"released":"2005-01-04T00:00:00Z"}]}}""".toByteArray()
    private fun mutatedMetadata(target: String, replacement: String): ByteArray {
        val original = metadata().toString(Charsets.UTF_8)
        require(original.contains(target)) { "Missing valid metadata fixture field" }
        return original.replaceFirst(target, replacement).toByteArray()
    }
    private suspend fun capture(scope: LegacyWatchedBitfieldMigrationEvidence.Scope, source: ByteArray, raw: ByteArray) =
        LegacyWatchedBitfieldMigrationEvidence.capture(scope, source,
            LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0), addon, { true }) { request ->
                LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, raw)
            }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private suspend fun expectFailure(action: suspend () -> Unit) { try { action(); fail("Expected migration evidence rejection") } catch (_: IllegalArgumentException) { } }
}
