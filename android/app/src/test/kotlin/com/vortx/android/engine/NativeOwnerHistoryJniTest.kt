package com.vortx.android.engine

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in REAL JNI tests. Require reviewed owner-history host cdylib; no network or device.
 * No raw-archive/credential/checkpoint authority claim: these synthetic verifiers accept checks.
 * A skipped test is NOT JNI proof. The coordinated native gate must require zero skips.
 */
class NativeOwnerHistoryJniTest {
    private val accept = NativeOwnerHistoryVerifier { bytes ->
        val kind = JSONObject(bytes.toString(Charsets.UTF_8)).getString("kind")
        check(kind == "full" || kind == "lease")
        true
    }
    private fun load() {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        assumeTrue("Set VORTX_JNI_LIBRARY to exact reviewed owner-history host cdylib", !path.isNullOrBlank())
        System.load(requireNotNull(path))
    }
    private fun snapshot(): ByteArray {
        val engine = VortxCore.nativeInitRuntime("""{"ownerId":"owner","ownerName":"Owner"}""")
        check(engine != 0L)
        try {
            check(JSONObject(requireNotNull(VortxCore.nativeDispatchJson(engine,
                """{"type":"bind_sync_scope","scope":"scope"}"""))).getBoolean("ok"))
            return requireNotNull(VortxCore.nativeGetStateJson(engine)).toByteArray(Charsets.UTF_8)
        } finally { VortxCore.nativeEngineFree(engine) }
    }
    private fun capture(handle: Long, verifier: NativeOwnerHistoryVerifier = accept): JSONObject =
        JSONObject(requireNotNull(VortxCore.nativeOwnerHistoryRequest(handle,
            """{"kind":"capture","profileId":"owner","authenticatedUid":"uid"}""".toByteArray(),
            7L, verifier)).toString(Charsets.UTF_8))

    @Test fun openForkRequestAndQuiescentCloseUseRealPrivateSessionProtocol() {
        load()
        val parent = VortxCore.nativeOwnerHistoryOpen(snapshot(), accept)
        assertTrue(parent > 0L)
        var child = 0L
        try {
            val before = capture(parent)
            assertEquals("capture", before.getString("kind"))
            val fence = before.getJSONObject("fence")
            child = VortxCore.nativeOwnerHistoryFork(parent, fence.toString().toByteArray(), accept)
            assertTrue(child > 0L); assertNotEquals(parent, child)
            val next = capture(child).getJSONObject("fence")
            assertNotEquals(fence.getString("instanceId"), next.getString("instanceId"))
            assertEquals(fence.getString("sourceSetWitnessId"), next.getString("sourceSetWitnessId"))
            assertEquals(before.toString(), capture(parent).toString())
            assertEquals(0L, VortxCore.nativeOwnerHistoryFork(child, fence.toString().toByteArray(), accept))
            assertNull(VortxCore.nativeOwnerHistoryRequest(parent, "{}".toByteArray(), -1, accept))
        } finally {
            if (child != 0L) assertTrue(VortxCore.nativeOwnerHistoryClose(child))
            assertTrue(VortxCore.nativeOwnerHistoryClose(parent))
        }
        assertFalse(VortxCore.nativeOwnerHistoryClose(parent))
        assertNull(VortxCore.nativeOwnerHistoryRequest(parent, "{}".toByteArray(), 7, accept))
    }

    @Test fun javaVerifierExceptionRejectsAndDoesNotRemainPendingOnThread() {
        load()
        val bytes = snapshot()
        assertEquals(0L, VortxCore.nativeOwnerHistoryOpen(bytes, NativeOwnerHistoryVerifier { false }))
        assertEquals(0L, VortxCore.nativeOwnerHistoryOpen(bytes, NativeOwnerHistoryVerifier {
            throw IllegalStateException("synthetic verifier rejection")
        }))
        val live = VortxCore.nativeOwnerHistoryOpen(bytes, accept)
        assertTrue(live > 0L)
        try {
            assertEquals("error", capture(live, NativeOwnerHistoryVerifier { false }).getString("kind"))
            assertEquals("error", capture(live, NativeOwnerHistoryVerifier {
                throw IllegalStateException("synthetic lease rejection")
            }).getString("kind"))
            assertEquals("capture", capture(live).getString("kind"))
        } finally { assertTrue(VortxCore.nativeOwnerHistoryClose(live)) }
    }

    @Test fun verifierReentryAndCloseRejectButStatelessCanonicalizerRemainsAvailable() {
        load()
        val live = VortxCore.nativeOwnerHistoryOpen(snapshot(), accept)
        assertTrue(live > 0L)
        var called = false
        try {
            val verifier = NativeOwnerHistoryVerifier {
                called = true
                assertNull(VortxCore.nativeOwnerHistoryRequest(live, "{}".toByteArray(), 7, accept))
                assertFalse(VortxCore.nativeOwnerHistoryClose(live))
                val canonical = requireNotNull(VortxCore.nativeOwnerHistoryCanonicalize("{}".toByteArray()))
                assertEquals("error", JSONObject(canonical.toString(Charsets.UTF_8)).getString("kind"))
                true
            }
            assertEquals("capture", capture(live, verifier).getString("kind"))
            assertTrue(called)
            assertEquals("capture", capture(live).getString("kind"))
        } finally { assertTrue(VortxCore.nativeOwnerHistoryClose(live)) }
    }

    @Test fun strictUtf8BoundsAndRealCanonicalReceiptAreEnforced() {
        load()
        assertEquals(0L, VortxCore.nativeOwnerHistoryOpen(byteArrayOf(0xc0.toByte(), 0xaf.toByte()), accept))
        assertNull(VortxCore.nativeOwnerHistoryCanonicalize(byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte())))
        assertNull(VortxCore.nativeOwnerHistoryCanonicalize(ByteArray(NativeOwnerHistoryRuntime.MAX_BYTES + 1) { 32 }))
        val evidence = JSONObject().put("schemaVersion", 1).put("scope", "scope")
            .put("ownerProfileId", "owner").put("profileId", "owner").put("verifiedStreamingUid", "uid")
            .put("sourceDocumentSha256", "a".repeat(64)).put("sourceArchiveSha256", "f".repeat(64))
            .put("library", JSONObject("""{"items":[],"intents":[]}"""))
            .put("watches", org.json.JSONArray()).put("identityLinks", org.json.JSONArray())
        fun canonical(json: String) = JSONObject(requireNotNull(
            VortxCore.nativeOwnerHistoryCanonicalize(json.toByteArray())).toString(Charsets.UTF_8))
        val compact = canonical(evidence.toString())
        assertEquals("owner_history_evidence", compact.getString("kind"))
        assertEquals(compact.toString(), canonical(evidence.toString(2)).toString())
        evidence.put("authKey", "synthetic-not-for-output")
        val rejected = canonical(evidence.toString())
        assertEquals("error", rejected.getString("kind"))
        assertFalse(rejected.toString().contains("synthetic-not-for-output"))
    }

    @Test fun warmSchemaSixReceiveEncryptedColdReopenAndOrdinaryMutationUseRealJni() {
        load()
        // The test JVM must include the reviewed artifact directory in java.library.path.
        assertTrue("Production JNI loader must resolve the reviewed artifact", VortxCore.isAvailable())
        val owner = "7BFA570A-1F11-4455-9876-39F451725934"
        val uid = "synthetic-owner-uid"
        val scope = VortxAccountScope("synthetic.scope", owner)
        class OriginalAuthority : NativeOwnerHistoryAuthority {
            var active = true
            var checks = 0
            override fun <T> withActive(block: () -> T): T {
                check(active); checks++
                val result = block(); check(active); return result
            }
        }
        val authority = OriginalAuthority()
        val transport = object : VortxResourceTransport {
            override fun makeCancellation() = object : VortxResourceCancellation {
                override fun cancel() {}
                override fun close() {}
            }
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String =
                error("JNI integration must not load a resource or use the network")
        }
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(),
            "owner-history-jni-session-").toFile()
        val key = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        val checkpointFile = java.io.File(directory, "native-state-v1-${scope.digest}.sealed")
        var notifications = 0
        fun playback(session: VortxNativeSession) = session.resolve(JSONObject()
            .put("kind", "profile_playback").put("profileId", owner))
        try {
            VortxNativeSession.open(scope, "Owner", VortxJniBindings, store, transport,
                allowNewAccount = true, ownerHistoryAuthority = authority).use {
                assertFalse(it.hasOwnerHistory())
            }
            val original = store.captureCheckpoint(scope)
            val plaintext = requireNotNull(original.plaintext)
            val ciphertext = checkpointFile.readBytes()

            // Only original upstream bytes are synthetic. Production replay/canonicalize/import
            // generate ALL evidence, receipt and wire attestations, without authored proof fields.
            val source = OHJson.Obj().set("schemaVersion", OHJson.literal("1"))
                .set("kind", OHJson.quote("vortx.owner-history.source/1"))
                .set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(owner))
                .set("profileId", OHJson.quote(owner)).set("verifiedStreamingUid", OHJson.quote(uid))
                .set("libraryResponseBase64", OHJson.quote(OHJson.b64(
                    """{"result":[{"_id":"historical","type":"movie","name":"Historical","state":{"timeOffset":1234,"duration":5000,"lastWatched":"2026-01-01T00:00:00.125Z","flaggedWatched":0}}]}""".toByteArray())))
                .set("addonsResponseBase64", OHJson.quote(OHJson.b64(
                    """{"result":{"addons":[]}}""".toByteArray()))).encoded()
            val archive = OHJson.Obj().set("schemaVersion", OHJson.literal("1"))
                .set("kind", OHJson.quote("vortx.owner-history.archive/1"))
                .set("sourceDocumentBase64", OHJson.quote(OHJson.b64(source)))
                .set("metadataEvidenceBase64", OHJson.literal("[]")).encoded()
            val replay = NativeOwnerHistorySources.replay(archive, scope, owner, uid, authority)
            val canonical = OHJson.Obj(requireNotNull(NativeOwnerHistoryJniBindings.canonicalize(replay)))
            assertEquals("owner_history_evidence", canonical.text("kind"))
            val receipt = canonical.raw("receipt")
            val sourceID = canonical.obj("receipt").text("sourceId")
            val parent = NativeOwnerHistoryRuntime.open(NativeOwnerHistoryJniBindings,
                plaintext.toByteArray(Charsets.UTF_8), accept)
            var child: NativeOwnerHistoryRuntime? = null
            lateinit var importedSnapshot: ByteArray
            lateinit var capturedBinding: ByteArray
            fun request(runtime: NativeOwnerHistoryRuntime, kind: String, fence: ByteArray? = null,
                        evidence: ByteArray? = null): OHJson.Obj {
                val body = OHJson.Obj().set("kind", OHJson.quote(kind))
                if (fence != null) body.set("fence", fence)
                if (kind == "capture") body.set("profileId", OHJson.quote(owner))
                    .set("authenticatedUid", OHJson.quote(uid))
                if (evidence != null) body.set("evidence", evidence)
                return OHJson.Obj(runtime.request(body.encoded(), 0, accept))
            }
            try {
                val parentCapture = request(parent, "capture")
                assertEquals("capture", parentCapture.text("kind"))
                val staged = parent.fork(parentCapture.raw("fence"), accept)
                child = staged
                val first = request(staged, "capture")
                capturedBinding = first.obj("fence").raw("binding")
                val imported = request(staged, "import", first.raw("fence"), canonical.raw("evidence"))
                assertEquals("source_candidate", imported.text("kind"))
                assertArrayEquals(OHJson.canonical(receipt), OHJson.canonical(imported.raw("receipt")))
                assertEquals("false", OHJson.utf8(imported.raw("durableAck")))
                val checkpoint = request(staged, "checkpoint", request(staged, "capture").raw("fence"))
                assertEquals("checkpoint", checkpoint.text("kind"))
                assertEquals("false", OHJson.utf8(checkpoint.raw("durableAck")))
                assertEquals("true", OHJson.utf8(checkpoint.raw("requiresCompleteArchiveEnvelope")))
                importedSnapshot = checkpoint.raw("state")
                assertEquals(6L, OHJson.integer(OHJson.Obj(importedSnapshot).obj("nativeSync").raw("schemaVersion")))
                assertTrue(OHJson.equal(parentCapture.encoded(), request(parent, "capture").encoded()))
            } finally {
                child?.let { assertTrue(it.close()) }
                assertTrue(parent.close())
            }

            // The journal references the actual canonical receipt and native captured binding.
            val entry = OHJson.Obj().set("archiveBase64", OHJson.quote(OHJson.b64(archive)))
                .set("receipt", receipt).set("capturedBinding", capturedBinding)
                .set("profileId", OHJson.quote(owner)).set("verifiedStreamingUid", OHJson.quote(uid))
            val journal = OHJson.Obj().set("kind", OHJson.quote(NativeOwnerHistorySources.JOURNAL))
                .set("schemaVersion", OHJson.literal("1")).set("scope", OHJson.quote(scope.accountID))
                .set("ownerProfileId", OHJson.quote(owner))
                .set("sources", OHJson.Obj().set(sourceID, entry.encoded()).encoded()).encoded()
            val local = OHJson.Obj().set("kind", OHJson.quote(NativeOwnerHistorySources.LOCAL))
                .set("journalBase64", OHJson.quote(OHJson.b64(journal)))
                .set("pending", OHJson.literal("{}")).encoded()
            NativeOwnerHistorySources.fromLocal(scope, local)
                .validate(importedSnapshot, NativeOwnerHistoryJniBindings, authority)
            val carrier = NativeOwnerHistorySources.carrier(local, scope, uid)
            val unknown = """{"wide":18446744073709551615,"zero":-0.0}""".toByteArray()
            val remote = NativeOwnerHistoryAccount(OHJson.Obj()
                .set("nativeSync", OHJson.Obj(importedSnapshot).raw("nativeSync"))
                .set(NativeOwnerHistoryAccount.ARCHIVE, carrier).set("future", unknown).encoded())
            remote.validateBudget(true)

            VortxNativeSession.openForOwnerHistoryTransfer(scope, original, VortxJniBindings, store,
                transport, onMutation = { notifications++ }, beforeOwnerChange = {},
                onProgressMutation = { notifications++ }, isAccountCurrent = { authority.active },
                authority = authority).use { warm ->
                assertEquals(plaintext, store.read(scope))
                assertFalse(warm.hasOwnerHistory())
                warm.receiveOwnerHistory(remote, authority, NativeOwnerHistoryJniBindings, remoteHost = null)
                assertTrue(warm.hasOwnerHistory()); assertFalse(warm.requiresRecovery())
                assertEquals(owner, warm.read().owner.profileID)
                assertEquals(0L, playback(warm).getJSONObject("watchedTitles").optLong("historical", 0))
                assertEquals(1234L, warm.resolve(JSONObject().put("kind", "resume_point")
                    .put("id", "historical")).getJSONObject("resume").getLong("offsetMs"))
                assertArrayEquals(unknown, NativeOwnerHistoryAccount(requireNotNull(warm.rawAccount())).raw("future"))
                assertEquals(0, notifications) // Receiving a peer must not echo a local mutation.
                assertTrue(runCatching { store.requireCurrentCheckpoint(scope, original) }.isFailure)
            }
            val typedCiphertext = checkpointFile.readBytes()
            assertFalse(ciphertext.contentEquals(typedCiphertext))
            assertFalse(typedCiphertext.toString(Charsets.UTF_8).contains(NativeOwnerHistoryCoordinator.ENVELOPE))
            assertFalse(typedCiphertext.toString(Charsets.UTF_8).contains(uid))
            assertTrue(runCatching { store.read(scope) }.isFailure) // No generic sidecar-stripping route.

            // A NEW Store decrypts the file: not a retained in-memory checkpoint shortcut.
            val coldStore = VortxEncryptedCheckpointStore(directory) { key }
            val coldRead = coldStore.captureCheckpoint(scope)
            val checkpoint = NativeOwnerHistoryCoordinator.decodeEnvelope(
                requireNotNull(coldRead.plaintext).toByteArray(Charsets.UTF_8), scope)
            assertArrayEquals(local, checkpoint.localArchive)
            VortxNativeSession.openOwnerHistory(scope, checkpoint, coldRead, VortxJniBindings,
                NativeOwnerHistoryJniBindings, coldStore, transport, authority,
                onMutation = { notifications++ }, beforeOwnerChange = {},
                onProgressMutation = { notifications++ }, isAccountCurrent = { authority.active }).use { cold ->
                assertTrue(cold.hasOwnerHistory()); assertFalse(cold.requiresRecovery())
                assertEquals(owner, cold.read().owner.profileID)
                val results = cold.dispatch(listOf(JSONObject().put("type", "mark_watched").put("metaId", "historical")),
                    verifyCandidate = { candidate ->
                        val staged = JSONObject(candidate.resolve(JSONObject().put("kind", "profile_playback")
                            .put("profileId", owner).toString()))
                        assertTrue(staged.getJSONObject("watchedTitles").getLong("historical") > 0)
                    })
                assertTrue(JSONObject(results.single()).getBoolean("ok"))
                assertTrue(playback(cold).getJSONObject("watchedTitles").getLong("historical") > 0)
                assertEquals(1, notifications)
                val exported = NativeOwnerHistoryAccount(requireNotNull(cold.rawAccount()))
                assertArrayEquals(unknown, exported.raw("future"))
                assertArrayEquals(carrier, exported.raw(NativeOwnerHistoryAccount.ARCHIVE))
                NativeOwnerHistorySources.fromCarrier(scope, requireNotNull(exported.raw(NativeOwnerHistoryAccount.ARCHIVE)))
                    .validate(OHJson.Obj().set("nativeSync", requireNotNull(exported.raw("nativeSync"))).encoded(),
                        NativeOwnerHistoryJniBindings, authority)
                val persisted = NativeOwnerHistoryCoordinator.decodeEnvelope(
                    requireNotNull(coldStore.captureCheckpoint(scope).plaintext).toByteArray(Charsets.UTF_8), scope)
                assertArrayEquals(local, persisted.localArchive)
                assertArrayEquals(exported.encoded(), persisted.accountBase)
                assertTrue(runCatching { coldStore.requireCurrentCheckpoint(scope, coldRead) }.isFailure)
            }
            assertTrue(authority.checks > 10)
        } finally {
            // Only this test's disposable directory is removed, never application storage.
            directory.listFiles()?.forEach { assertTrue(it.delete()) }
            assertTrue(directory.delete())
        }
    }
}
