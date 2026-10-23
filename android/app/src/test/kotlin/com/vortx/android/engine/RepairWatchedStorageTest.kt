package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.Deflater

/** Standalone regressions against the current production codec, producer and preflight. */
class RepairWatchedStorageTest {
    private val owner = "00000000-0000-0000-0000-00000000A11C"

    @Test fun `many source rows compact below strict archive limit while legacy expansion exceeds it`() {
        val source = largeSharedSource(24, 880_000)
        val records = (0 until 24).map { index -> evidenceRecord(source, index) }
        val legacy = JSONObject().put(NativeWatchedMigrationStorage.EVIDENCE, JSONArray(records))
        val expandedBytes = legacy.toString().toByteArray(Charsets.UTF_8)
        assertTrue("legacy-expanded archive must exceed 16 MiB", expandedBytes.size > 16_777_216)

        val compact = NativeWatchedMigrationStorage.read(legacy)
        val compactDocument = JSONObject().also(compact::writeTo)
        val compactBytes = nativeWatchedDocumentSnapshot(compactDocument)
        assertTrue("pooled compact archive should fit", compactBytes.size < 16_777_216)
        assertEquals(1, compact.sources().length())
        assertEquals(24, compact.records(NativeWatchedMigrationStorage.EVIDENCE).length())
        assertEquals(24, compact.inlineRecords(NativeWatchedMigrationStorage.EVIDENCE).length())
    }

    @Test fun `fresh producer pools one near megabyte source for twenty four accepted rows`() = kotlinx.coroutines.runBlocking {
        val scope = VortxAccountScope("account.fixture", owner)
        val sourceBytes = largeSharedSource(24, 880_000)
        val document = JSONObject(String(sourceBytes, Charsets.UTF_8))
        val producer = NativeWatchedMigrationProducer { request ->
            val videos = JSONArray().put(JSONObject().put("id", "${request.metaID}:1:1").put("season", 1).put("episode", 1))
            val metadata = JSONObject().put("meta", JSONObject().put("id", request.metaID).put("type", "series").put("videos", videos))
                .toString().toByteArray()
            LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata)
        }
        val batch = producer.prepare(scope, document,
            listOf(com.vortx.android.profile.UserProfile(id = owner, name = "Main", avatar = "🍿", isOwner = true)), isCurrent = { true })
        assertTrue(batch.isComplete)
        assertEquals(24, batch.archive().length())
        for (index in 0 until 24) {
            val raw = document.getJSONObject("vortx").getJSONArray("library").getJSONObject(index)
            assertEquals(listOf("series-$index:1:1"), batch.videoIDs(owner,
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(index), raw))
        }
        val storage = batch.storage()
        val host = JSONObject().also(storage::writeTo)
        assertEquals(1, storage.sources().length())
        assertEquals(24, storage.records(NativeWatchedMigrationStorage.EVIDENCE).length())
        assertTrue(nativeWatchedDocumentSnapshot(host).size < 16_777_216)
        assertTrue(batch.archive().toString().toByteArray().size > 16_777_216)

        val preflight = NativeMigrationPreflight.create(scope, NativeHostDocument.archive(host), emptyList())
        val directory = java.nio.file.Files.createTempDirectory("repair-android-watched-pooled-restart-").toFile()
        val key = javax.crypto.spec.SecretKeySpec(ByteArray(32) { (it * 3).toByte() }, "AES")
        VortxEncryptedCheckpointStore(directory) { key }.commitPreflight(preflight, null)
        val reopened = VortxEncryptedCheckpointStore(directory) { key }.readPreflight(scope.accountID)!!
        val reloaded = NativeWatchedMigrationStorage.read(reopened.archive.getJSONObject("document"))
        assertEquals(preflight.raw, reopened.raw)
        assertEquals(1, reloaded.sources().length())
        assertEquals(24, reloaded.records(NativeWatchedMigrationStorage.EVIDENCE).length())
        assertTrue(reloaded.inlineRecords(NativeWatchedMigrationStorage.EVIDENCE).getJSONObject(23)
            .getString("sourceDocumentBase64").length > 1_000_000)
    }

    @Test fun `schema one dual reads and schema two rejects missing tampered or orphan sources`() {
        val source = largeSharedSource(1, 32)
        val legacy = JSONObject().put(NativeWatchedMigrationStorage.EVIDENCE, JSONArray().put(evidenceRecord(source, 0)))
        val compact = NativeWatchedMigrationStorage.read(legacy)
        assertEquals(1, compact.inlineRecords(NativeWatchedMigrationStorage.EVIDENCE).length())
        val pooled = JSONObject().also(compact::writeTo)

        val digest = compact.sources().keys().next()
        val missing = JSONObject(pooled.toString()).put(NativeWatchedMigrationStorage.SOURCES, JSONObject())
        expectFailure { NativeWatchedMigrationStorage.read(missing) }
        val tampered = JSONObject(pooled.toString())
        tampered.getJSONObject(NativeWatchedMigrationStorage.SOURCES).put(digest, "AAAA")
        expectFailure { NativeWatchedMigrationStorage.read(tampered) }
        val orphan = JSONObject(pooled.toString())
        orphan.getJSONObject(NativeWatchedMigrationStorage.SOURCES).put("0".repeat(64), "AAAA")
        expectFailure { NativeWatchedMigrationStorage.read(orphan) }
    }

    @Test fun `case alias duplicate identity and wrong scope or metadata are rejected`() {
        val source = largeSharedSource(1, 32)
        val evidence = evidenceRecord(source, 0)
        val compact = NativeWatchedMigrationStorage.read(JSONObject()
            .put(NativeWatchedMigrationStorage.EVIDENCE, JSONArray().put(evidence)))
        val pooled = JSONObject().also(compact::writeTo)
        val alias = JSONObject(pooled.toString())
        val rows = alias.getJSONArray(NativeWatchedMigrationStorage.EVIDENCE)
        rows.put(JSONObject(rows.getJSONObject(0).toString()).put("profileId", owner.lowercase()).put("ownerProfileId", owner.lowercase()))
        expectFailure { NativeWatchedMigrationStorage.read(alias) }

        val scoped = NativeWatchedMigrationStorage.read(pooled)
        expectFailure { scoped.requireScope(VortxAccountScope("account.other", owner)) }
        expectFailure { scoped.requireScope(VortxAccountScope("account.fixture", "00000000-0000-0000-0000-00000000BEEF")) }
        val wrongMetadata = JSONObject(pooled.toString())
        val row = wrongMetadata.getJSONArray(NativeWatchedMigrationStorage.EVIDENCE).getJSONObject(0)
        row.put("metadataResponseSha256", "f".repeat(64))
        expectFailure { NativeWatchedMigrationStorage.read(wrongMetadata) }
    }

    @Test fun `source and record bytes are retained without a mutable caller alias`() {
        val source = largeSharedSource(1, 32)
        val record = evidenceRecord(source, 0)
        val before = source.copyOf()
        val storage = NativeWatchedMigrationStorage.read(JSONObject()
            .put(NativeWatchedMigrationStorage.EVIDENCE, JSONArray().put(record)))
        source[0] = 'x'.code.toByte()
        record.put("accountId", "changed")
        assertTrue(Base64.getDecoder().decode(storage.sources().getString(storage.sources().keys().next())).contentEquals(before))
        assertFalse(storage.inlineRecords(NativeWatchedMigrationStorage.EVIDENCE).getJSONObject(0).getString("accountId") == "changed")
    }

    @Test fun `successful retry retains pending receipt while unresolved status reaches zero`() = kotlinx.coroutines.runBlocking {
        val scope = VortxAccountScope("account.fixture", owner)
        val document = JSONObject(String(largeSharedSource(1, 32), Charsets.UTF_8))
        val first = NativeWatchedMigrationProducer { error("offline fixture") }
            .prepare(scope, document, listOf(com.vortx.android.profile.UserProfile(id = owner, name = "Main", avatar = "🍿", isOwner = true)), isCurrent = { true })
        assertFalse(first.isComplete)
        val pendingStorage = first.storage()
        assertEquals(1, pendingStorage.unresolvedCount)

        val preflight = NativeMigrationPreflight.create(scope,
            NativeHostDocument.archive(JSONObject().also(pendingStorage::writeTo)), emptyList())
        val directory = java.nio.file.Files.createTempDirectory("repair-android-watched-pending-restart-").toFile()
        val key = javax.crypto.spec.SecretKeySpec(ByteArray(32) { (it * 5).toByte() }, "AES")
        VortxEncryptedCheckpointStore(directory) { key }.commitPreflight(preflight, null)
        val cold = VortxEncryptedCheckpointStore(directory) { key }.readPreflight(scope.accountID)!!
        val coldStorage = NativeWatchedMigrationStorage.read(cold.archive.getJSONObject("document"))
        assertEquals(1, coldStorage.unresolvedCount)

        val metadata = JSONObject().put("meta", JSONObject().put("id", "series-0").put("type", "series")
            .put("videos", JSONArray().put(JSONObject().put("id", "series-0:1:1").put("season", 1).put("episode", 1))))
            .toString().toByteArray()
        val retry = NativeWatchedMigrationProducer { request -> LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata) }
            .retryPending(scope, coldStorage, isCurrent = { true })
        val resolved = retry.storage()
        assertTrue(retry.isComplete)
        assertEquals(0, resolved.unresolvedCount)
        assertEquals(1, resolved.records(NativeWatchedMigrationStorage.PENDING).length())
        assertEquals(1, resolved.records(NativeWatchedMigrationStorage.EVIDENCE).length())
    }

    private fun largeSharedSource(count: Int, filler: Int): ByteArray {
        val rows = JSONArray()
        repeat(count) { index ->
            val id = "series-$index"
            rows.put(JSONObject().put("id", id).put("type", "series").put("watched", "$id:1:1:1:${zlibOne()}"))
        }
        val manifest = JSONObject().put("id", "catalog").put("name", "Original catalog").put("version", "1.0.0")
            .put("resources", JSONArray().put("meta")).put("types", JSONArray().put("series")).put("idPrefixes", JSONArray().put("series-"))
        val addons = JSONArray().put(JSONObject().put("transportUrl", "https://catalog.example/manifest.json").put("manifest", manifest))
        return JSONObject().put("vortx", JSONObject().put("library", rows).put("addons", addons))
            .put("fixturePadding", "x".repeat(filler)).toString().toByteArray()
    }

    private fun evidenceRecord(source: ByteArray, index: Int): JSONObject {
        val id = "series-$index"
        val metadata = JSONObject().put("meta", JSONObject().put("id", id).put("type", "series")
            .put("videos", JSONArray().put(JSONObject().put("id", "$id:1:1").put("season", 1).put("episode", 1))))
            .toString().toByteArray()
        val manifest = JSONObject().put("id", "catalog").put("name", "Original catalog").put("version", "1.0.0")
            .put("resources", JSONArray().put("meta")).put("types", JSONArray().put("series")).put("idPrefixes", JSONArray().put("series-"))
            .toString().toByteArray()
        val digest = sha256(source)
        return JSONObject().put("schemaVersion", 1).put("accountId", "account.fixture").put("profileId", owner)
            .put("ownerProfileId", owner).put("sourceDocumentBase64", Base64.getEncoder().encodeToString(source))
            .put("sourceDocumentSha256", digest).put("row", JSONObject().put("kind", "owner_library").put("index", index))
            .put("addon", JSONObject().put("transportUrl", "https://catalog.example/manifest.json")
                .put("manifestBase64", Base64.getEncoder().encodeToString(manifest)))
            .put("metadataResponseBase64", Base64.getEncoder().encodeToString(metadata))
            .put("metadataResponseSha256", sha256(metadata))
    }

    private fun zlibOne(): String {
        val deflater = Deflater()
        return try {
            deflater.setInput(byteArrayOf(1)); deflater.finish()
            val output = ByteArray(64); val length = deflater.deflate(output)
            Base64.getEncoder().encodeToString(output.copyOf(length))
        } finally { deflater.end() }
    }

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun expectFailure(block: () -> Unit) {
        try { block(); fail("Expected strict watched storage rejection") }
        catch (_: RuntimeException) { }
    }
}
