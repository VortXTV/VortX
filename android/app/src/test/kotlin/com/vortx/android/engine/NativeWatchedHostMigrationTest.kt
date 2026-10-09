package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import java.nio.file.Files
import java.util.Base64
import java.util.zip.Deflater
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Actual production coordinator, encrypted preflight/checkpoint, and held JNI. No remote calls. */
class NativeWatchedHostMigrationTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
    private val scope = VortxAccountScope("account.${account.id}", owner.id)
    private fun bindings(): VortxRuntimeBindings {
        assumeTrue(System.getenv("VORTX_JNI_SYNC") == "1" && !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        return object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
    }
    private fun document(watched: Boolean = true): JSONObject {
        val library = JSONArray()
        if (watched) library.put(JSONObject().put("id", "fixture-series").put("type", "series").put("name", "Fixture")
            .put("watched", bitmap()).put("ua", JSONObject().put("fixture-series:1:2", 50)))
        return JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode())).put("rosterModified", 1)
            .put("library", library).put("addons", JSONArray().put(JSONObject().put("transportUrl", "https://fixture.invalid/manifest.json")
                .put("manifest", JSONObject().put("id", "fixture").put("name", "Fixture").put("version", "1.0.0")
                    .put("types", JSONArray().put("series")).put("resources", JSONArray().put("meta"))))))
    }
    private fun bitmap(): String {
        val zip = Deflater()
        return try {
            zip.setInput(byteArrayOf(7)); zip.finish()
            val data = ByteArray(128); val count = zip.deflate(data)
            "fixture-series:1:3:3:${Base64.getEncoder().encodeToString(data.copyOf(count))}"
        } finally { zip.end() }
    }
    private fun response(request: LegacyWatchedBitfieldMigrationEvidence.MetadataRequest): LegacyWatchedBitfieldMigrationEvidence.MetadataResponse {
        val videos = JSONArray()
        for (index in 1..3) videos.put(JSONObject().put("id", "${request.metaID}:1:$index").put("season", 1).put("episode", index)
            .put("released", "2005-01-0${index}T00:00:00Z"))
        return LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request,
            JSONObject().put("meta", JSONObject().put("id", request.metaID).put("type", "series").put("videos", videos)).toString().toByteArray())
    }
    private fun coordinator(store: VortxCheckpointStore, current: () -> Boolean = { true },
                            createTransport: () -> Unit = {},
                            fetch: suspend (LegacyWatchedBitfieldMigrationEvidence.MetadataRequest) -> LegacyWatchedBitfieldMigrationEvidence.MetadataResponse): NativeAccountCoordinator =
        NativeAccountCoordinator(bindings(), store, { createTransport(); object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No resource network")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No resource network")
        } }, { it == account && current() }, { it() }, {}, watchedProducer = NativeWatchedMigrationProducer(fetch))
    private fun store(directory: java.io.File) = VortxEncryptedCheckpointStore(directory) { SecretKeySpec(ByteArray(32) { 21 }, "AES") }
    private fun watched(accounts: NativeAccountCoordinator): List<String> {
        val read = accounts.session().read()
        val query = accounts.session().resolve(JSONObject().put("kind", "profile_playback").put("profileId", owner.id), read.owner)
        val values = query.getJSONObject("watchedVideoIdsByTitle").optJSONArray("fixture-series") ?: JSONArray()
        return (0 until values.length()).map(values::getString)
    }

    @Test fun `single owner incomplete setup survives encrypted cold reopen without a blank runtime and imports real watched receipt on retry`() = runBlocking {
        val directory = Files.createTempDirectory("native-watched-preflight-").toFile()
        val checkpoints = store(directory)
        var available = false
        val fetch: suspend (LegacyWatchedBitfieldMigrationEvidence.MetadataRequest) -> LegacyWatchedBitfieldMigrationEvidence.MetadataResponse = {
            check(available); response(it)
        }
        var accounts = coordinator(checkpoints, fetch = fetch)
        try {
            val original = document().put("apiKeys", JSONObject().put("tmdb", "fixture-secret"))
            assertFalse(accounts.applyDocument(account, original) { true })
            assertNull(checkpoints.read(scope)); assertNull(checkpoints.discover(scope.accountID))
            assertTrue(accounts.streamingProfiles().isEmpty()); assertEquals(1, accounts.migrationStatus()!!.pendingRows)
            val preflight = checkpoints.readPreflight(scope.accountID)!!
            assertFalse(preflight.raw.contains("fixture-secret"))
            assertTrue(preflight.archive.getJSONArray("excludedCredentialPaths").toString().contains("apiKeys"))
            assertTrue(directory.listFiles()!!.all { it.name.startsWith("native-preflight-v1-") })
            assertTrue(directory.listFiles()!!.none { String(it.readBytes()).contains("fixture-series") })
            accounts.retire(); accounts = coordinator(checkpoints, fetch = fetch)
            assertFalse(accounts.reopenCheckpoint(account) { true })
            assertEquals(1, accounts.migrationStatus()!!.pendingRows)
            available = true
            assertTrue(accounts.retryMigration(accounts.captureMigrationTarget()))
            assertEquals(setOf("fixture-series:1:1", "fixture-series:1:3"), watched(accounts).toSet())
            assertEquals(scope, checkpoints.discover(scope.accountID))
            accounts.retire(); accounts = coordinator(checkpoints) { error("Cold native mount must not fetch") }
            assertTrue(accounts.reopenCheckpoint(account) { true })
            assertEquals(setOf("fixture-series:1:1", "fixture-series:1:3"), watched(accounts).toSet())
        } finally { accounts.retire(); directory.deleteRecursively() }
    }

    @Test fun `retry reprocesses historical A bytes after current B changed without projecting A into B`() = runBlocking {
        val directory = Files.createTempDirectory("native-watched-history-").toFile()
        val checkpoints = store(directory); var available = false
        val seen = mutableListOf<String>()
        val accounts = coordinator(checkpoints) { request -> seen += request.metaID; check(available); response(request) }
        try {
            assertFalse(accounts.applyDocument(account, document()) { true })
            val originalSHA = checkpoints.readPreflight(scope.accountID)!!.archive.getJSONObject("document")
                .getJSONArray("nativeWatchedMigrationPending").getJSONObject(0).getString("sourceDocumentSha256")
            assertTrue(accounts.applyDocument(account, document(false).put("futureSetting", "B")) { true })
            assertTrue(watched(accounts).isEmpty()); assertEquals(1, accounts.migrationStatus()!!.pendingRows)
            val nativeBefore = accounts.session().read().state.getJSONObject("nativeSync").toString()
            available = true; seen.clear()
            assertTrue(accounts.retryMigration(accounts.captureMigrationTarget()))
            assertEquals(listOf("fixture-series"), seen)
            val after = accounts.session().read()
            assertEquals(nativeBefore, after.state.getJSONObject("nativeSync").toString())
            assertTrue(watched(accounts).isEmpty())
            assertEquals(originalSHA, after.state.getJSONObject("hostDocument").getJSONArray("nativeWatchedMigrationEvidence")
                .getJSONObject(0).getString("sourceDocumentSha256"))
        } finally { accounts.retire(); directory.deleteRecursively() }
    }

    @Test fun `cancel and account retirement during retry preserve sealed original without publication`() = runBlocking {
        val directory = Files.createTempDirectory("native-watched-cancel-").toFile()
        val checkpoints = store(directory); var current = true; var wait = false
        val entered = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
        val accounts = coordinator(checkpoints, { current }) { request ->
            if (!wait) error("Unavailable")
            entered.complete(Unit); finish.await(); response(request)
        }
        try {
            assertFalse(accounts.applyDocument(account, document()) { current })
            val before = checkpoints.readPreflight(scope.accountID)!!.raw
            val sealedBefore = directory.listFiles()!!.single().readBytes()
            wait = true
            val target = accounts.captureMigrationTarget()
            val retry = launch { accounts.retryMigration(target) }
            entered.await(); retry.cancelAndJoin()
            assertEquals(before, checkpoints.readPreflight(scope.accountID)!!.raw)
            assertArrayEquals(sealedBefore, directory.listFiles()!!.single().readBytes())
            current = false; finish.complete(Unit)
            assertTrue(runCatching { accounts.retryMigration(target) }.isFailure)
            assertNull(checkpoints.read(scope)); assertNull(checkpoints.discover(scope.accountID))
            assertArrayEquals(sealedBefore, directory.listFiles()!!.single().readBytes())
        } finally { accounts.retire(); directory.deleteRecursively() }
    }

    @Test fun `preflight compare and swap rejects stale update and foreign account lookup cannot reveal owner`() {
        val directory = Files.createTempDirectory("native-preflight-cas-").toFile()
        val checkpoints = store(directory)
        try {
            val first = NativeMigrationPreflight.create(scope, NativeHostDocument.archive(document(false)), emptyList())
            checkpoints.commitPreflight(first, null)
            val second = NativeMigrationPreflight.create(scope, first.archive, emptyList())
            checkpoints.commitPreflight(second, first)
            assertTrue(runCatching { checkpoints.commitPreflight(first, first) }.isFailure)
            assertEquals(second.raw, checkpoints.readPreflight(scope.accountID)!!.raw)
            assertNull(checkpoints.readPreflight("account.00000000-0000-0000-0000-000000000999"))
            assertTrue(runCatching { checkpoints.verifyFreshAccount(scope) }.isFailure)
            assertNull(checkpoints.discover(scope.accountID))
        } finally { directory.deleteRecursively() }
    }

    @Test fun `cancellation at final cold transport creation cannot install a runtime or locator`() = runBlocking {
        val directory = Files.createTempDirectory("native-watched-final-cancel-").toFile()
        val checkpoints = store(directory); var available = false; var job: Job? = null
        val accounts = coordinator(checkpoints, createTransport = { job?.cancel() }) { check(available); response(it) }
        try {
            assertFalse(accounts.applyDocument(account, document()) { true })
            val retained = checkpoints.readPreflight(scope.accountID)!!.raw
            available = true
            val retry = launch { job = currentCoroutineContext()[Job]; accounts.retryMigration(accounts.captureMigrationTarget()) }
            retry.join(); assertTrue(retry.isCancelled)
            assertNull(checkpoints.read(scope)); assertNull(checkpoints.discover(scope.accountID))
            assertEquals(retained, checkpoints.readPreflight(scope.accountID)!!.raw)
            assertNotNull(accounts.migrationStatus())
        } finally { accounts.retire(); directory.deleteRecursively() }
    }

    @Test fun `own reconnect with unavailable metadata preserves active A and exact inactive B candidate across cold retry`() =
        pendingReconnect(initialOwn = true)

    @Test fun `shared to own unavailable metadata preserves shared binding and cold retries exact candidate without refetch`() =
        pendingReconnect(initialOwn = false)

    private fun pendingReconnect(initialOwn: Boolean) = runBlocking {
        val directory = Files.createTempDirectory("native-watched-own-link-").toFile()
        val checkpoints = store(directory)
        val child = UserProfile(id = "11111111-1111-1111-1111-111111111111", name = "Independent", avatar = "🍿", usesOwnAccount = initialOwn)
        val values = mutableMapOf<String, String?>()
        val credentials = NativeOwnAccountCredentials({ key -> PersistentCredentialSnapshot(PersistentCredentialAvailability.AVAILABLE, mapOf(key to values[key])) },
            { key, value -> values[key] = value; true })
        var uid = "stream-A"; var available = false; var allowSource = true
        val producer = NativeOwnAccountProducer { path, _ ->
            check(allowSource) { "Cold retry must not refetch or relabel the independent source" }
            when (path) {
                "login" -> JSONObject().put("result", JSONObject().put("authKey", "fixture-token"))
                "getUser" -> JSONObject().put("result", JSONObject().put("_id", uid))
                "datastoreGet" -> JSONObject().put("result", if (uid == "stream-A") JSONArray() else JSONArray().put(JSONObject()
                    .put("_id", "fixture-series").put("type", "series").put("name", "B series").put("state", JSONObject().put("watched", bitmap()))))
                "addonCollectionGet" -> JSONObject().put("result", JSONObject().put("addons", document().getJSONObject("vortx").getJSONArray("addons")))
                else -> error("Unexpected fake request")
            }.toString().toByteArray()
        }
        fun make() = NativeAccountCoordinator(bindings(), checkpoints, { object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No network")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network")
        } }, { it == account }, { it() }, {}, ownCredentials = credentials, ownProducer = producer,
            watchedProducer = NativeWatchedMigrationProducer { check(available); response(it) },
            captureOwnAccountAdmission = { captured -> { action -> captured == account && action() } })
        var accounts = make()
        try {
            val doc = document(false)
            doc.getJSONObject("vortx").getJSONArray("roster").put(child.encode())
            doc.getJSONObject("vortx").put("byProfile", JSONObject().put(child.id, JSONObject().put("library", JSONArray().put(
                JSONObject().put("id", "historical-A").put("type", "movie").put("t", 35).put("d", 100)
                    .put("lastWatched", "2020-01-02T00:00:00Z")))))
            if (initialOwn) {
                assertFalse(accounts.applyDocument(account, doc) { true })
                assertTrue(accounts.signInStreaming(accounts.captureStreamingTarget(child.id), "a@example.invalid", "fixture-password"))
            } else assertTrue(accounts.applyDocument(account, doc) { true })
            NativeProfileAccess { accounts.session() }.select(child.id)
            val before = NativeAccountBinding.read(accounts.session().read().state, child.id)
            uid = "stream-B"
            if (initialOwn) assertFalse(accounts.signInStreaming(accounts.captureStreamingTarget(child.id), "b@example.invalid", "fixture-password"))
            else assertFalse(NativeStreamingAccountLink(credentials, producer, NativeWatchedMigrationProducer { check(available); response(it) })
                .signIn(accounts.session(), account, child.id, "b@example.invalid", "fixture-password", { it() }, { it() }))
            val pending = accounts.session().read()
            assertTrue(before.matches(NativeAccountBinding.read(pending.state, child.id)))
            val candidate = pending.state.getJSONObject("hostDocument").getJSONObject("nativeOwnAccountCandidates").getJSONObject(child.id)
            assertEquals("stream-B", candidate.getString("verifiedStreamingUid"))
            val transaction = candidate.getString("transactionId")
            assertNotEquals(before.transactionID, transaction)
            assertFalse(checkpoints.read(scope)!!.contains("fixture-token"))
            // Even possession of this exact local secure revision does not make a cloud-provided
            // source envelope authenticated. Reserved device-only candidates are never adopted.
            val forged = document(false).put("nativeOwnAccountCandidates", JSONObject().put(child.id, candidate))
            forged.getJSONObject("vortx").getJSONArray("roster").put(child.encode())
            val sealedBeforeForgery = checkpoints.read(scope)
            assertTrue(runCatching { accounts.applyDocument(account, forged) { true } }.isFailure)
            assertEquals(sealedBeforeForgery, checkpoints.read(scope))
            accounts.retire(); accounts = make(); allowSource = false; available = true
            assertTrue(accounts.reopenCheckpoint(account) { true })
            assertEquals(child.id, accounts.session().read().owner.profileID)
            assertTrue(accounts.retryMigration(accounts.captureMigrationTarget()))
            val after = accounts.session().read()
            val selected = NativeAccountBinding.read(after.state, child.id)
            assertEquals("stream-B", selected.streamingUID); assertEquals(transaction, selected.transactionID)
            assertFalse(after.state.getJSONObject("hostDocument").getJSONObject("nativeOwnAccountCandidates").has(child.id))
            val query = accounts.session().resolve(JSONObject().put("kind", "profile_playback").put("profileId", child.id), after.owner)
            assertEquals(3, query.getJSONObject("watchedVideoIdsByTitle").getJSONArray("fixture-series").length())
            assertFalse(query.toString().contains("historical-A"))
            assertTrue(after.state.getJSONObject("hostDocument").toString().contains("historical-A"))
        } finally { accounts.retire(); directory.deleteRecursively() }
    }
}
