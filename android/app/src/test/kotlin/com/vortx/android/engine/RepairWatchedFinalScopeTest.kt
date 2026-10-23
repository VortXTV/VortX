package com.vortx.android.engine

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.Deflater
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Standalone fixtures for the actual complete VortxAccountScope and encrypted store.
 * No native runtime is supplied or stubbed here: admission-return/write proof is narrower than
 * full-session hydrate/publication/dispatch proof, which remains a separate HOLD. */
class RepairWatchedFinalScopeTest {
    @Test fun `actual active profile projection keys remain excluded from account settings`() {
        val expected = setOf("stremiox.catalog.hidden", "stremiox.catalog.order",
            "vortx.discover.hiddenCategories", "vortx.discover.regionPreference", "vortx.discover.filters",
            "vortx.collections.selectedProviders", "vortx.collections.providerOrder",
            "vortx.tabs.hide.live", "vortx.tabs.hide.discover", "vortx.tabs.hide.library", "vortx.tabs.hide.search",
            "vortx.home.showCollectionsHub", "vortx.discover.showCollectionsHub",
            "vortx.home.continueWatching.source", "vortx.home.continueWatching.window")
        assertEquals(expected, com.vortx.android.profile.ProfileDiscoveryPreferencesStore.activeProjectionKeys)
        for (key in expected) assertFalse("Active profile key must not sync globally: $key",
            com.vortx.android.backup.SettingsBackup.isSyncable(key))
        assertTrue("Ordinary syncable global must remain enabled",
            com.vortx.android.backup.SettingsBackup.isSyncable("stremiox.autoSkip"))
    }

    @Test fun `actual scope and encrypted store preserve an absent watched journal`() {
        val directory = WatchedFinalFixture.directory("absent")
        val snapshot = WatchedFinalFixture.snapshot(JSONObject())
        val scope = WatchedFinalFixture.scope
        assertEquals(scope.accountID, scope.validateSnapshot(snapshot).getJSONObject("nativeSync").getString("scope"))
        VortxEncryptedCheckpointStore(directory) { WatchedFinalFixture.key }.commit(scope, snapshot)
        val cold = VortxEncryptedCheckpointStore(directory) { WatchedFinalFixture.key }.read(scope)
        assertEquals(snapshot, cold)
        assertFalse(JSONObject(cold!!).getJSONObject("hostDocument").has(NativeWatchedMigrationStorage.SOURCES))
    }

    @Test fun `legacy inline and pooled journals survive actual cold checkpoint admission without byte rewriting`() {
        for (pooled in listOf(false, true)) {
            val journal = WatchedFinalFixture.journal(pooled)
            val snapshot = WatchedFinalFixture.snapshot(journal)
            val directory = WatchedFinalFixture.directory(if (pooled) "pooled" else "inline")
            val scope = WatchedFinalFixture.scope
            scope.validateSnapshot(snapshot)
            NativeHostDocument.requireCredentialFree(journal)
            VortxEncryptedCheckpointStore(directory) { WatchedFinalFixture.key }.commit(scope, snapshot)
            val sealedBefore = WatchedFinalFixture.files(directory)
            val cold = VortxEncryptedCheckpointStore(directory) { WatchedFinalFixture.key }.read(scope)
            assertNotNull(cold)
            assertEquals("read must return exact committed raw bytes", snapshot, cold)
            assertEquals("read must not rewrite the sealed checkpoint", sealedBefore, WatchedFinalFixture.files(directory))
            val retained = JSONObject(cold!!).getJSONObject("hostDocument")
            assertEquals("legacy representation is not silently rewritten", pooled, retained.has(NativeWatchedMigrationStorage.SOURCES))
            val storage = NativeWatchedMigrationStorage.read(retained)
            storage.requireScope(scope)
            assertEquals(1, storage.sources().length())
            assertEquals(1, storage.records(NativeWatchedMigrationStorage.EVIDENCE).length())
            assertEquals(1, storage.records(NativeWatchedMigrationStorage.PENDING).length())
            assertEquals(1, storage.unresolvedCount)
            for (kind in listOf(NativeWatchedMigrationStorage.EVIDENCE, NativeWatchedMigrationStorage.PENDING)) {
                assertArrayEquals(WatchedFinalFixture.source, Base64.getDecoder().decode(
                    storage.inlineRecords(kind).getJSONObject(0).getString("sourceDocumentBase64")))
            }
        }
    }

    @Test fun `actual preference and website validators remain active beside watched journal admission`() {
        val good = JSONObject(WatchedFinalFixture.snapshot(WatchedFinalFixture.journal(true)))
        val scope = WatchedFinalFixture.scope
        scope.validateSnapshot(good.toString())
        val wrongSync = JSONObject(good.toString())
        wrongSync.getJSONObject("nativeSync").put("scope", "foreign.outer")
        WatchedFinalFixture.rejected { scope.validateSnapshot(wrongSync.toString()) }
        val deletedOwner = JSONObject(good.toString())
        deletedOwner.getJSONObject("roster").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).put("deleted", true)
        WatchedFinalFixture.rejected { scope.validateSnapshot(deletedOwner.toString()) }
        val badHost = JSONObject(good.toString())
        badHost.getJSONObject("nativeHostPreferenceState").put("actor", "not-an-actor")
        WatchedFinalFixture.rejected { scope.validateSnapshot(badHost.toString()) }
        val badGlobal = JSONObject(good.toString())
        val hostState = badGlobal.getJSONObject("nativeHostPreferenceState")
        hostState.put("counter", 1)
        hostState.getJSONObject("document").getJSONObject("globals").getJSONObject("fields")
            .put("stremiox.autoSkip", JSONObject().put("clock", 1).put("actor", "10000000-0000-0000-0000-000000000001").put("value", "not-a-bool"))
        WatchedFinalFixture.rejected { scope.validateSnapshot(badGlobal.toString()) }
        val badWebsite = JSONObject(good.toString()).put("websiteProfileEditPending", JSONObject().put("events", "not-an-array"))
        WatchedFinalFixture.rejected { scope.validateSnapshot(badWebsite.toString()) }
        val badAddon = JSONObject(good.toString()).put("websiteAddonEditPending", JSONObject().put("events", "not-an-array"))
        WatchedFinalFixture.rejected { scope.validateSnapshot(badAddon.toString()) }
        val credential = JSONObject(good.toString()).put("password", "must-not-be-native-state")
        WatchedFinalFixture.rejected { scope.validateSnapshot(credential.toString()) }
    }

    @Test fun `actual scope rejects tampered pooled source before checkpoint write`() {
        val journal = WatchedFinalFixture.journal(true)
        val pool = journal.getJSONObject(NativeWatchedMigrationStorage.SOURCES)
        pool.put(pool.keys().next(), Base64.getEncoder().encodeToString("{}".toByteArray()))
        val directory = WatchedFinalFixture.directory("tampered")
        var keyLookups = 0
        val store = VortxEncryptedCheckpointStore(directory) { keyLookups += 1; WatchedFinalFixture.key }
        WatchedFinalFixture.rejected { store.commit(WatchedFinalFixture.scope, WatchedFinalFixture.snapshot(journal)) }
        assertEquals(0, keyLookups)
        assertTrue(WatchedFinalFixture.files(directory).isEmpty())
    }
}

/** Eight behavioral cases, also run alone after removing ONLY the scope-fence line from the
 * generated real scope class. All eight must then fail; compilation errors are not negatives. */
class RepairWatchedFinalScopeFenceTest {
    @Test fun `inline foreign account cold checkpoint is not admitted`() = cold(false, false)
    @Test fun `pooled foreign account cold checkpoint is not admitted`() = cold(true, false)
    @Test fun `inline foreign owner pending cold checkpoint is not admitted`() = cold(false, true)
    @Test fun `pooled foreign owner pending cold checkpoint is not admitted`() = cold(true, true)
    @Test fun `inline foreign account commit is rejected before seal or replacement`() = commit(false, false)
    @Test fun `pooled foreign account commit is rejected before seal or replacement`() = commit(true, false)
    @Test fun `inline foreign owner pending commit is rejected before seal or replacement`() = commit(false, true)
    @Test fun `pooled foreign owner pending commit is rejected before seal or replacement`() = commit(true, true)

    private fun cold(pooled: Boolean, foreignOwner: Boolean) {
        val directory = WatchedFinalFixture.directory("foreign-cold")
        val scope = WatchedFinalFixture.scope
        val invalid = WatchedFinalFixture.snapshot(WatchedFinalFixture.foreignJournal(pooled, foreignOwner))
        // Fixture-only corruption: valid AES-GCM under the real enclosing scope's key and AAD.
        // It cannot be misreported as merely an authentication failure. The actual store decrypts
        // this valid sealed payload and must reject the inner watched account/owner authority.
        val sealed = WatchedFinalFixture.seal(scope, invalid)
        File(directory, "native-state-v1-${scope.digest}.sealed").writeBytes(sealed)
        val before = WatchedFinalFixture.files(directory)
        var keyLookups = 0
        var admittedReturns = 0
        val store = VortxEncryptedCheckpointStore(directory) { keyLookups += 1; WatchedFinalFixture.key }
        val failure = WatchedFinalFixture.rejected {
            store.read(scope)
            admittedReturns += 1 // Read-return witness only; not an invented native publish stub.
        }
        assertTrue(failure.message.orEmpty().contains("another account scope"))
        assertEquals("actual AES decrypt must have occurred", 1, keyLookups)
        assertEquals("invalid cold state must not return to a caller", 0, admittedReturns)
        assertEquals("cold rejection must leave original encrypted bytes and files intact", before, WatchedFinalFixture.files(directory))
    }

    private fun commit(pooled: Boolean, foreignOwner: Boolean) {
        val directory = WatchedFinalFixture.directory("foreign-commit")
        val scope = WatchedFinalFixture.scope
        val good = WatchedFinalFixture.snapshot(WatchedFinalFixture.journal(pooled))
        val original = VortxEncryptedCheckpointStore(directory) { WatchedFinalFixture.key }
        original.commit(scope, good)
        original.remember(scope)
        val before = WatchedFinalFixture.files(directory)
        var keyLookups = 0
        val store = VortxEncryptedCheckpointStore(directory) { keyLookups += 1; WatchedFinalFixture.key }
        val invalid = WatchedFinalFixture.snapshot(WatchedFinalFixture.foreignJournal(pooled, foreignOwner))
        val failure = WatchedFinalFixture.rejected { store.commit(scope, invalid) }
        assertTrue(failure.message.orEmpty().contains("another account scope"))
        assertEquals("invalid commit must fail before encryption/key lookup", 0, keyLookups)
        assertEquals("invalid commit must not replace state or locator or leave pending files", before, WatchedFinalFixture.files(directory))
        assertEquals(good, original.read(scope))
        assertEquals(scope, original.discover(scope.accountID))
    }
}

private object WatchedFinalFixture {
    val scope = VortxAccountScope("account.fixture", "00000000-0000-0000-0000-00000000A11C")
    private const val foreignOwner = "00000000-0000-0000-0000-00000000BEEF"
    val key = SecretKeySpec(ByteArray(32) { (it * 13).toByte() }, "AES")
    private val manifest = JSONObject().put("id", "catalog").put("name", "Original catalog").put("version", "1.0.0")
        .put("resources", JSONArray().put("meta")).put("types", JSONArray().put("series")).put("idPrefixes", JSONArray().put("series-"))
        .toString().toByteArray(Charsets.UTF_8)
    val source: ByteArray = JSONObject().put("vortx", JSONObject().put("library", JSONArray().also { rows ->
        repeat(2) { index -> rows.put(JSONObject().put("id", "series-$index").put("type", "series")
            .put("watched", "series-$index:1:1:1:${zlibOne()}")) }
    }).put("addons", JSONArray().put(JSONObject().put("transportUrl", "https://catalog.example/manifest.json")
        .put("manifest", JSONObject(String(manifest, Charsets.UTF_8)))))).toString().toByteArray(Charsets.UTF_8)

    fun directory(label: String): File {
        val temporaryRoot = File(System.getProperty("java.io.tmpdir")).canonicalFile
        // The standalone runner sets this inside its retained workspace directory. Ordinary
        // Gradle/CI tests use their own temporary root, not a particular developer's home path.
        return Files.createTempDirectory(temporaryRoot.toPath(), "watched-$label-").toFile()
    }
    fun files(directory: File): Map<String, String> = directory.listFiles().orEmpty().associate { it.name to sha(it.readBytes()) }
    fun snapshot(journal: JSONObject): String {
        val id = scope.ownerProfileID
        val owner = JSONObject().put("id", id).put("owner", true).put("deleted", false)
        return JSONObject().put("roster", JSONObject().put("profiles", JSONObject().put(id, owner)))
            .put("activeProfileId", id).put("libraries", JSONObject().put(id, JSONObject()))
            .put("nativeSync", JSONObject().put("schemaVersion", 5).put("scope", scope.accountID).put("ownerProfileId", id)
                .put("profiles", JSONObject()).put("addons", JSONObject()).put("libraries", JSONObject()).put("watches", JSONObject()))
            .put("nativeHostPreferenceState", NativeHostPreferences.local(scope))
            .put("websiteProfileEditPending", JSONObject().put("events", JSONArray())).put("websiteProfileEditCertificates", JSONObject())
            .put("websiteAddonEditPending", JSONObject().put("events", JSONArray()))
            .put("hostDocument", journal).put("excludedCredentialPaths", JSONArray()).toString()
    }
    fun journal(pooled: Boolean): JSONObject = convert(journalFor(scope.accountID, scope.ownerProfileID), pooled)
    fun foreignJournal(pooled: Boolean, owner: Boolean): JSONObject {
        val result = if (owner) journalFor(scope.accountID, scope.ownerProfileID).also {
            // A valid accepted row cannot hide one pending row belonging to a foreign owner.
            it.put(NativeWatchedMigrationStorage.PENDING, journalFor(scope.accountID, foreignOwner)
                .getJSONArray(NativeWatchedMigrationStorage.PENDING))
        } else journalFor("account.foreign", scope.ownerProfileID)
        return convert(result, pooled)
    }
    private fun convert(inline: JSONObject, pooled: Boolean): JSONObject {
        val checked = NativeWatchedMigrationStorage.read(inline)
        return if (pooled) JSONObject().also(checked::writeTo) else inline
    }
    private fun journalFor(account: String, owner: String): JSONObject {
        val evidence = header(account, owner, 0).put("addon", JSONObject().put("transportUrl", "https://catalog.example/manifest.json")
            .put("manifestBase64", Base64.getEncoder().encodeToString(manifest)))
        val metadata = JSONObject().put("meta", JSONObject().put("id", "series-0").put("type", "series")
            .put("videos", JSONArray().put(JSONObject().put("id", "series-0:1:1").put("season", 1).put("episode", 1))))
            .toString().toByteArray(Charsets.UTF_8)
        evidence.put("metadataResponseBase64", Base64.getEncoder().encodeToString(metadata)).put("metadataResponseSha256", sha(metadata))
        val pending = header(account, owner, 1).put("reason", "episode_inventory_unavailable")
        return JSONObject().put(NativeWatchedMigrationStorage.EVIDENCE, JSONArray().put(evidence))
            .put(NativeWatchedMigrationStorage.PENDING, JSONArray().put(pending))
    }
    private fun header(account: String, owner: String, index: Int): JSONObject = JSONObject().put("schemaVersion", 1)
        .put("accountId", account).put("ownerProfileId", owner).put("profileId", owner)
        .put("sourceDocumentBase64", Base64.getEncoder().encodeToString(source)).put("sourceDocumentSha256", sha(source))
        .put("row", JSONObject().put("kind", "owner_library").put("index", index))
    fun seal(scope: VortxAccountScope, raw: String): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(scope.authenticatedData)
        require(cipher.iv.size == 12)
        return cipher.iv + cipher.doFinal(raw.toByteArray(Charsets.UTF_8))
    }
    fun rejected(block: () -> Unit): RuntimeException {
        val thrown = runCatching(block).exceptionOrNull()
        assertTrue("Expected actual production admission rejection, got $thrown", thrown is RuntimeException)
        return thrown as RuntimeException
    }
    private fun zlibOne(): String {
        val deflater = Deflater()
        return try {
            deflater.setInput(byteArrayOf(1)); deflater.finish()
            val output = ByteArray(64)
            Base64.getEncoder().encodeToString(output.copyOf(deflater.deflate(output)))
        } finally { deflater.end() }
    }
    private fun sha(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
