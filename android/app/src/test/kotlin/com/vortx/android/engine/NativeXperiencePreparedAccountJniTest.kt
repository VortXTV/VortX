package com.vortx.android.engine

import com.vortx.android.xperience.XperienceCollections
import com.vortx.android.xperience.XperienceImportNamespace
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Authored UNRUN, separately selected REAL-JNI/actual Session and encrypted-store controls.
 * Only upstream source bytes/provider inputs are synthetic. Production replay/canonicalize/import
 * generate schema6 and its receipts; no authored source carrier/DTO substitutes for that account.
 * These methods are additional to the retained 87/32 roster, never retroactive JNI proof. */
class NativeXperiencePreparedAccountJniTest {
    private val owner = "7BFA570A-1F11-4455-9876-39F451725934"
    private val scope = VortxAccountScope("synthetic.xperience.scope", owner)
    private val uid = "synthetic-owner-uid"
    private fun b(value: String) = value.toByteArray(Charsets.UTF_8)
    private val accept = NativeOwnerHistoryVerifier { true } // Setup native inventory only; real app verifier validates receive.
    private fun edit() = XperienceImportNamespace.append(XperienceCollections.parse(b(
        """[{"id":"c","title":"Imported","folders":[],"future":{"n":1.0,"z":-0.0}}]""")),
        "Saved", UUID.fromString("00000000-0000-0000-0000-000000000101"))
    private class Authority : NativeOwnerHistoryAuthority {
        var active = true
        override fun <T> withActive(block: () -> T): T { check(active); return block().also { check(active) } }
    }
    private fun load() {
        assumeTrue("Exact reviewed host JNI required", System.getenv("VORTX_JNI_SYNC") == "1" && !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        check(VortxCore.isAvailable())
    }
    private inner class Fixture : AutoCloseable {
        val authority = Authority()
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "xperience-typed-").toFile()
        private val key = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val disk = VortxEncryptedCheckpointStore(directory) { key }
        var writes = 0
        val store = object : VortxCheckpointStore by disk {
            override fun compareAndCommitCheckpoint(scope: VortxAccountScope, expected: NativeCheckpointRead,
                snapshot: String): NativeCheckpointRead { writes++; return disk.compareAndCommitCheckpoint(scope, expected, snapshot) }
        }
        val transport = object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No resource request")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network")
        }
        lateinit var session: VortxNativeSession
        val unknown = b("{\"wide\":18446744073709551615,\"zero\":-0.0}")
        init {
            try {
                VortxNativeSession.open(scope, "Owner", VortxJniBindings, store, transport,
                    allowNewAccount = true, ownerHistoryAuthority = authority).close()
                val original = store.captureCheckpoint(scope)
                val source = OHJson.Obj().set("schemaVersion", b("1")).set("kind", OHJson.quote("vortx.owner-history.source/1"))
                    .set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(owner)).set("profileId", OHJson.quote(owner))
                    .set("verifiedStreamingUid", OHJson.quote(uid))
                    .set("libraryResponseBase64", OHJson.quote(OHJson.b64(b("""{"result":[{"_id":"historical","type":"movie","name":"History"}]}"""))))
                    .set("addonsResponseBase64", OHJson.quote(OHJson.b64(b("""{"result":{"addons":[]}}""")))).encoded()
                val archive = OHJson.Obj().set("schemaVersion", b("1")).set("kind", OHJson.quote("vortx.owner-history.archive/1"))
                    .set("sourceDocumentBase64", OHJson.quote(OHJson.b64(source))).set("metadataEvidenceBase64", b("[]")).encoded()
                val canonical = OHJson.Obj(checkNotNull(NativeOwnerHistoryJniBindings.canonicalize(
                    NativeOwnerHistorySources.replay(archive, scope, owner, uid, authority))))
                check(canonical.text("kind") == "owner_history_evidence")
                val parent = NativeOwnerHistoryRuntime.open(NativeOwnerHistoryJniBindings, b(checkNotNull(original.plaintext)), accept)
                fun request(runtime: NativeOwnerHistoryRuntime, kind: String, fence: ByteArray? = null, evidence: ByteArray? = null): OHJson.Obj {
                    val body = OHJson.Obj().set("kind", OHJson.quote(kind))
                    if (fence != null) body.set("fence", fence)
                    if (kind == "capture") body.set("profileId", OHJson.quote(owner)).set("authenticatedUid", OHJson.quote(uid))
                    if (evidence != null) body.set("evidence", evidence)
                    return OHJson.Obj(runtime.request(body.encoded(), 0, accept))
                }
                var child: NativeOwnerHistoryRuntime? = null
                lateinit var imported: ByteArray; lateinit var binding: ByteArray
                try {
                    val staged = parent.fork(request(parent, "capture").raw("fence"), accept); child = staged
                    val capture = request(staged, "capture"); binding = capture.obj("fence").raw("binding")
                    check(request(staged, "import", capture.raw("fence"), canonical.raw("evidence")).text("kind") == "source_candidate")
                    imported = request(staged, "checkpoint", request(staged, "capture").raw("fence")).raw("state")
                    check(OHJson.integer(OHJson.Obj(imported).obj("nativeSync").raw("schemaVersion")) == 6L)
                } finally { child?.let { check(it.close()) }; check(parent.close()) }
                val entry = OHJson.Obj().set("archiveBase64", OHJson.quote(OHJson.b64(archive))).set("receipt", canonical.raw("receipt"))
                    .set("capturedBinding", binding).set("profileId", OHJson.quote(owner)).set("verifiedStreamingUid", OHJson.quote(uid))
                val journal = OHJson.Obj().set("kind", OHJson.quote(NativeOwnerHistorySources.JOURNAL)).set("schemaVersion", b("1"))
                    .set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(owner))
                    .set("sources", OHJson.Obj().set(canonical.obj("receipt").text("sourceId"), entry.encoded()).encoded()).encoded()
                val local = OHJson.Obj().set("kind", OHJson.quote(NativeOwnerHistorySources.LOCAL))
                    .set("journalBase64", OHJson.quote(OHJson.b64(journal))).set("pending", b("{}")).encoded()
                NativeOwnerHistorySources.fromLocal(scope, local).validate(imported, NativeOwnerHistoryJniBindings, authority)
                val account = NativeOwnerHistoryAccount(OHJson.Obj().set("nativeSync", OHJson.Obj(imported).raw("nativeSync"))
                    .set(NativeOwnerHistoryAccount.ARCHIVE, NativeOwnerHistorySources.carrier(local, scope, uid))
                    .set("future", unknown).encoded())
                session = VortxNativeSession.openForOwnerHistoryTransfer(scope, original, VortxJniBindings, store, transport,
                    {}, {}, {}, { authority.active }, authority)
                session.receiveOwnerHistory(account, authority, NativeOwnerHistoryJniBindings, null)
                check(session.hasOwnerHistory() && !session.requiresRecovery()); writes = 0
            } catch (failure: Throwable) {
                if (::session.isInitialized) runCatching { session.close() }
                directory.deleteRecursively(); throw failure
            }
        }
        fun operation(): VortxNativeSession.XperienceOperation {
            val read = session.read()
            return session.captureXperienceOperation(read.owner, session.xperienceContext(read), NativeXperienceWrite.Change.edit(edit()), false)
        }
        override fun close() {
            authority.active = true
            try { if (::session.isInitialized) session.close() } finally { directory.deleteRecursively() }
        }
    }

    @Test fun actualTypedSessionPreinvokeAndFullBudgetRefusalKeepTheOriginalCheckpointUsable() {
        load()
        for (kind in listOf("provider", "budget", "missing")) Fixture().use { fixture ->
            val before = fixture.store.captureCheckpoint(scope).plaintext
            fixture.operation().use { operation ->
                val rejected = runCatching { fixture.session.dispatchXperience(operation,
                    JSONObject().put("stremiox.autoSkip", true), { _, _, _ -> error("Typed must not use generic") },
                    { raw, host, persist ->
                        assertEquals(6L, OHJson.integer(OHJson.Obj(checkNotNull(NativeOwnerHistoryAccount(raw).raw("nativeSync"))).raw("schemaVersion")))
                        when (kind) {
                            "provider" -> error("Controlled original provider witness changed")
                            "budget" -> {
                                NativePlaylistAccountComposer.composePrepared(raw, host,
                                    JSONObject().put("apiKeys", JSONObject().put("future", "x".repeat(6_000_000))))
                                fail("Complete encrypted account budget must refuse before persist")
                            }
                            else -> Unit // Missing invocation must not be acknowledged.
                        }
                    }, {}) }
                assertTrue(rejected.isFailure)
            }
            assertEquals(0, fixture.writes); assertEquals(before, fixture.store.captureCheckpoint(scope).plaintext)
            assertFalse(fixture.session.requiresRecovery())
            fixture.operation().use { operation ->
                fixture.session.dispatchXperience(operation, JSONObject().put("stremiox.autoSkip", true),
                    { _, _, _ -> error("No generic route") }, { raw, host, persist ->
                        val complete = NativePlaylistAccountComposer.composePrepared(raw, host, JSONObject())
                        try {
                            val account = NativeOwnerHistoryAccount(complete)
                            assertArrayEquals(fixture.unknown, account.raw("future"))
                            val globals = OHJson.Obj(checkNotNull(account.raw("nativeHostPreferences"))).obj("globals").obj("fields")
                            assertNotNull(globals["stremiox.autoSkip"])
                            persist()
                        } finally { complete.fill(0) }
                    }, {})
            }
            assertEquals(1, fixture.writes); assertFalse(fixture.session.requiresRecovery())
            val raw = checkNotNull(fixture.session.rawAccount())
            assertArrayEquals(fixture.unknown, NativeOwnerHistoryAccount(raw).raw("future"))
            assertNull(OHJson.Obj(fixture.session.rawHostPreferences()).obj("globals").obj("fields")["stremiox.autoSkip"])
        }
    }

    @Test fun actualTypedSessionPostDurableOrSwallowedDuplicateFailureRequiresReopen() {
        load()
        for (kind in listOf("after", "duplicate")) Fixture().use { fixture ->
            val before = fixture.store.captureCheckpoint(scope).plaintext
            fixture.operation().use { operation ->
                val rejected = runCatching { fixture.session.dispatchXperience(operation, JSONObject(),
                    { _, _, _ -> error("No generic route") }, { raw, host, persist ->
                        val complete = NativePlaylistAccountComposer.composePrepared(raw, host, JSONObject())
                        try {
                            persist()
                            if (kind == "after") error("Controlled producer failure after durability")
                            try { persist() } catch (_: Exception) {} // Swallowing cannot manufacture success.
                        } finally { complete.fill(0) }
                    }, {}) }
                assertTrue(rejected.isFailure)
            }
            assertEquals(1, fixture.writes); assertNotEquals(before, fixture.store.captureCheckpoint(scope).plaintext)
            assertTrue(fixture.session.requiresRecovery())
        }
    }

    @Test fun actualGenericManagerRetainsFullProviderSettingsWitnessesAndPendingNamespaces() = kotlinx.coroutines.runBlocking {
        load()
        val fixture = com.vortx.android.sync.NativeAccountSyncTest()
        fixture.mainDispatcher()
        try { fixture.verifyXperienceAccountProducerCases() } finally { fixture.resetDispatcher() }
    }
}
