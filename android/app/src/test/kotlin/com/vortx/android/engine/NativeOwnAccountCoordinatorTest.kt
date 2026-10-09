package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import com.vortx.android.ui.viewmodel.NativeStreamingAccountViewModel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Production coordinator + real JNI; all authenticated responses below are synthetic local data. */
@OptIn(ExperimentalCoroutinesApi::class)
class NativeOwnAccountCoordinatorTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
    private val child = UserProfile(id = "11111111-1111-1111-1111-111111111111", name = "Independent", avatar = "🍿", usesOwnAccount = true)
    private val uid = "e9" + "0".repeat(22)
    private class Store : VortxCheckpointStore {
        var value: String? = null; var locator: VortxAccountScope? = null
        var preflight: NativeMigrationPreflight? = null
        override fun read(scope: VortxAccountScope) = value
        override fun commit(scope: VortxAccountScope, snapshot: String) { scope.validateSnapshot(snapshot); value = snapshot }
        override fun discover(accountID: String) = locator?.takeIf { it.accountID == accountID }
        override fun remember(scope: VortxAccountScope) { locator = scope }
        override fun readPreflight(accountID: String) = preflight?.takeIf { it.scope.accountID == accountID }
        override fun commitPreflight(next: NativeMigrationPreflight, expected: NativeMigrationPreflight?) {
            check(preflight?.raw == expected?.raw); preflight = next
        }
    }
    private class Journal {
        val values = mutableMapOf<String, String?>()
        val credentials = NativeOwnAccountCredentials({ key -> PersistentCredentialSnapshot(PersistentCredentialAvailability.AVAILABLE, mapOf(key to values[key])) },
            { key, value -> values[key] = value; true })
    }
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
    private fun document() = JSONObject().put("vortx", JSONObject()
        .put("roster", JSONArray().put(owner.encode()).put(child.encode())).put("rosterModified", 1)
        .put("library", JSONArray()).put("addons", JSONArray())
        .put("byProfile", JSONObject().put(child.id, JSONObject().put("library", JSONArray().put(JSONObject()
            .put("id", "historical-a-only").put("type", "movie").put("t", 45).put("d", 100))))))
    private fun coordinator(store: Store, journal: Journal, isCurrent: () -> Boolean = { true },
                            after: (String) -> Unit = {}): NativeAccountCoordinator {
        val producer = NativeOwnAccountProducer { path, body ->
            val result = when (path) {
                "login" -> JSONObject().put("result", JSONObject().put("authKey", "fake-token"))
                "getUser" -> { assertEquals("fake-token", body.getString("authKey")); JSONObject().put("result", JSONObject().put("_id", uid)) }
                "datastoreGet" -> JSONObject().put("result", JSONArray().put(JSONObject().put("_id", "independent-b")
                    .put("type", "movie").put("name", "B title").put("state", JSONObject().put("timeOffset", 20_000)
                        .put("duration", 100_000).put("video_id", "independent-b").put("lastWatched", "2026-10-08T10:00:00Z"))))
                "addonCollectionGet" -> JSONObject().put("result", JSONObject().put("addons", JSONArray()))
                else -> error("Unexpected source request")
            }; after(path); result.toString().toByteArray()
        }
        return NativeAccountCoordinator(bindings(), store, { object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No resources")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network")
        } }, { it == account && isCurrent() }, { it() }, {}, ownCredentials = journal.credentials,
            ownProducer = producer, captureOwnAccountAdmission = { captured -> { action -> captured == account && isCurrent() && action() } })
    }

    @Test fun `initial own setup publishes no blank state and verified sign-in binds exact staged revision without historical overlay`() = runBlocking {
        val store = Store(); val journal = Journal(); val coordinator = coordinator(store, journal)
        try {
            val doc = document()
            assertFalse(coordinator.applyDocument(account, doc) { true })
            assertNull(store.value); assertNull(store.locator); assertTrue(runCatching { coordinator.session() }.isFailure)
            assertTrue(coordinator.streamingProfiles().single().pendingImport)
            val target = coordinator.captureStreamingTarget(child.id)
            assertTrue(coordinator.signInStreaming(target, "fake@example.invalid", "fake-password"))
            val read = coordinator.session().read(); val selected = NativeAccountBinding.read(read.state, child.id)
            assertEquals(uid, selected.streamingUID); assertNotNull(selected.transactionID)
            assertEquals("fake-token", journal.credentials.capture(account, child.id, uid, selected.transactionID) { it() }!!.request(JSONObject()).getString("authKey"))
            val baseline = NativeOwnAccountBaseline.validate(bindings(), read.owner.scope, read.state.getJSONObject("nativeSync"))
            assertTrue(baseline.bucket("libraries", child.id).toString().contains("independent-b"))
            assertFalse(baseline.bucket("watches", child.id).toString().contains("historical-a-only"))
            val pending = read.state.getJSONObject("hostDocument").getJSONObject("nativeOwnAccountPending").getJSONObject(child.id)
            assertTrue(String(java.util.Base64.getDecoder().decode(pending.getString("profileOverlayBase64"))).contains("historical-a-only"))
            assertFalse(pending.has("verifiedStreamingUid")) // New B is not evidence of historical A.
            assertTrue(coordinator.streamingProfiles().single().pendingOverlay)
            assertFalse(store.value!!.contains("fake-token")); assertFalse(store.value!!.contains("fake-password"))
            assertTrue(NativeHostPreferences.equal(doc, document()))
        } finally { coordinator.retire() }
    }

    @Test fun `cold peer keeps validated native data visible without credentials and retains changed legacy overlay pending`() = runBlocking {
        val firstStore = Store(); val first = coordinator(firstStore, Journal()); val doc = document()
        assertFalse(first.applyDocument(account, doc) { true })
        assertTrue(first.signInStreaming(first.captureStreamingTarget(child.id), "fake@example.invalid", "fake-password"))
        val remote = JSONObject(doc.toString()).put("nativeSync", first.session().read().state.getJSONObject("nativeSync"))
        first.retire()
        val peerStore = Store(); val emptyJournal = Journal(); val peer = coordinator(peerStore, emptyJournal) { error("Cold peer must not call provider") }
        try {
            assertTrue(peer.applyDocument(account, remote) { true })
            assertTrue(emptyJournal.values.isEmpty())
            val before = peer.session().read().state.getJSONObject("nativeSync")
            assertEquals(uid, NativeAccountBinding.read(peer.session().read().state, child.id).streamingUID)
            remote.getJSONObject("vortx").getJSONObject("byProfile").getJSONObject(child.id).put("futureDisplayStyle", "retained")
            assertTrue(peer.applyDocument(account, remote) { true })
            val after = peer.session().read()
            assertTrue(NativeHostPreferences.equal(before, after.state.getJSONObject("nativeSync")))
            val pending = after.state.getJSONObject("hostDocument").getJSONObject("nativeOwnAccountPending").getJSONObject(child.id)
            assertTrue(String(java.util.Base64.getDecoder().decode(pending.getString("profileOverlayBase64"))).contains("futureDisplayStyle"))
            assertFalse(pending.has("verifiedStreamingUid"))
            peer.retire(); assertTrue(peer.reopenCheckpoint(account) { true })
            assertEquals(uid, NativeAccountBinding.read(peer.session().read().state, child.id).streamingUID)
        } finally { peer.retire() }
    }

    @Test fun `replaced authenticated setup target and logout during last fetch cannot publish`() = runBlocking {
        val store = Store(); val journal = Journal(); var current = true
        val coordinator = coordinator(store, journal, { current }) { path -> if (path == "addonCollectionGet") current = false }
        try {
            assertFalse(coordinator.applyDocument(account, document()) { current })
            val stale = coordinator.captureStreamingTarget(child.id)
            assertFalse(coordinator.applyDocument(account, document()) { current })
            assertTrue(runCatching { coordinator.signInStreaming(stale, "fake@example.invalid", "fake-password") }.isFailure)
            assertTrue(journal.values.isEmpty())
            assertTrue(runCatching { coordinator.signInStreaming(coordinator.captureStreamingTarget(child.id), "fake@example.invalid", "fake-password") }.isFailure)
            assertNull(store.value); assertNull(store.locator)
        } finally { coordinator.retire() }
    }

    @Test fun `typed opaque UID remains literal but actual encoded credential carriers are still inspected`() {
        val proof = JSONObject().put("verifiedStreamingUid", uid).put("sourceDocumentSha256", "0".repeat(64))
        val accountValue = JSONObject().put("kind", "own").put("value", uid)
        val raw = JSONObject().put("proof", proof).put("account", accountValue)
        assertTrue(NativeHostPreferences.equal(raw, NativeHostDocument.archive(raw).getJSONObject("document")))
        proof.put("verifiedStreamingUid", java.util.Base64.getEncoder().encodeToString("{\"authKey\":\"fake-secret\"}".toByteArray()))
        assertTrue(NativeHostDocument.archive(raw).getJSONArray("excludedCredentialPaths").length() > 0)
        assertTrue(runCatching { NativeHostDocument.archive(JSONObject().put("ordinary", uid)) }.isFailure)
    }

    @Test fun `profile form shows only authenticated setup and clears captured form after verified commit`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val accounts = coordinator(Store(), Journal()); val models = androidx.lifecycle.ViewModelStore()
        try {
            assertFalse(accounts.applyDocument(account, document()) { true })
            val model = NativeStreamingAccountViewModel(accounts).also { models.put("profile-sign-in", it) }
            assertFalse(model.state.value.mounted)
            assertEquals(listOf(child.id), model.state.value.profiles.map { it.id })
            model.open(child.id); assertEquals(child.id, model.state.value.formProfile!!.id)
            model.submit("fake@example.invalid", "fake-password")
            val state = withTimeout(5_000) { model.state.first { !it.busy && it.mounted } }
            assertNull(state.formProfile)
            assertFalse(state.toString().contains("fake-password")); assertFalse(state.toString().contains("fake-token"))
            assertTrue(state.streaming.single().pendingOverlay)
        } finally { models.clear(); accounts.retire(); Dispatchers.resetMain() }
    }

    @Test fun `form submission cannot recapture a replacement setup or reveal credential error detail`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val journal = Journal(); val store = Store(); val accounts = coordinator(store, journal)
        val models = androidx.lifecycle.ViewModelStore()
        try {
            assertFalse(accounts.applyDocument(account, document()) { true })
            val model = NativeStreamingAccountViewModel(accounts).also { models.put("profile-sign-in", it) }
            model.open(child.id)
            assertFalse(accounts.applyDocument(account, document()) { true })
            model.submit("fake@example.invalid", "fake-password")
            val state = withTimeout(5_000) { model.state.first { !it.busy && it.message != null } }
            assertFalse(state.mounted); assertNotNull(state.formProfile)
            assertTrue(journal.values.isEmpty()); assertNull(store.value)
            assertFalse(state.toString().contains("fake-password")); assertFalse(state.toString().contains("fake@example.invalid"))
            model.close(); assertNull(model.state.value.formProfile)
        } finally { models.clear(); accounts.retire(); Dispatchers.resetMain() }
    }

    @Test fun `old PIN dialog cannot recapture a replacement authenticated setup`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val accounts = coordinator(Store(), Journal()); val models = androidx.lifecycle.ViewModelStore()
        try {
            val original = document()
            original.getJSONObject("vortx").getJSONArray("roster").getJSONObject(1).put("pin", UserProfile.pinHash("1234", child.id))
            assertFalse(accounts.applyDocument(account, original) { true })
            val model = NativeStreamingAccountViewModel(accounts).also { models.put("profile-sign-in", it) }
            val beforePin = requireNotNull(model.prepare(child.id))
            assertEquals(UserProfile.pinHash("1234", child.id), beforePin.profile.pin)
            val replacement = document()
            replacement.getJSONObject("vortx").getJSONArray("roster").getJSONObject(1).put("pin", UserProfile.pinHash("5678", child.id))
            assertFalse(accounts.applyDocument(account, replacement) { true })
            model.openPrepared(beforePin) // Even a correct old PIN does not authorize the new target.
            assertNull(model.state.value.formProfile)
            assertEquals(UserProfile.pinHash("5678", child.id), requireNotNull(model.prepare(child.id)).profile.pin)
        } finally { models.clear(); accounts.retire(); Dispatchers.resetMain() }
    }

    @Test fun `editor save delete and add cannot recapture a later binding or profile ABA`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val accounts = coordinator(Store(), Journal()); val models = androidx.lifecycle.ViewModelStore()
        try {
            assertFalse(accounts.applyDocument(account, document()) { true })
            assertTrue(accounts.signInStreaming(accounts.captureStreamingTarget(child.id), "fake@example.invalid", "fake-password"))
            val access = NativeProfileAccess { accounts.session() }; access.select(child.id)
            val model = NativeStreamingAccountViewModel(accounts).also { models.put("profile-sign-in", it) }
            val original = access.read().profiles.single { it.id == child.id }
            val editor = requireNotNull(model.captureEditor(original, false))
            // Same UID relink still rotates immutable binding txn and must invalidate an old editor.
            assertTrue(accounts.signInStreaming(accounts.captureStreamingTarget(child.id), "fake@example.invalid", "fake-password"))
            var callback = false
            assertFalse(model.commitEditor(editor) { callback = true; access.save(original.copy(usesOwnAccount = false), false) })
            assertFalse(callback)
            assertFalse(model.commitEditor(editor) { callback = true; access.remove(child.id) })
            assertFalse(callback); assertEquals("own", NativeAccountBinding.read(accounts.session().read().state, child.id).kind)
            val draft = child.copy(id = "22222222-2222-2222-2222-222222222222", name = "New")
            val adding = requireNotNull(model.captureEditor(draft, true))
            access.select(owner.id); access.select(child.id)
            assertFalse(model.commitEditor(adding) { callback = true; access.save(draft, true) })
            assertFalse(callback); assertFalse(access.read().profiles.any { it.id == draft.id })
            val switching = requireNotNull(model.captureSelection(access.read().profiles.single { it.id == owner.id }))
            accounts.retire(); assertTrue(accounts.reopenCheckpoint(account) { true })
            assertFalse(model.commitEditor(switching) { callback = true; access.select(owner.id) })
            assertFalse(callback) // Same account/profile values after reopen do not revive old PIN admission.
            access.save(access.read().profiles.single { it.id == child.id }.copy(name = "Remote update"), false)
            assertEquals("Remote update", model.state.value.profiles.single { it.id == child.id }.name)
        } finally { models.clear(); accounts.retire(); Dispatchers.resetMain() }
    }

    private fun ownerDocument() = document().also { it.getJSONObject("vortx")
        .put("roster", JSONArray().put(owner.encode())).remove("byProfile") }

    @Test fun `optional owner auth uses verified credentials not VortX login and does not mutate native data`() = runBlocking {
        val store = Store(); val requests = mutableListOf<String>(); val journal = Journal()
        val accounts = coordinator(store, journal, after = { requests += it })
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            assertTrue(accounts.applyDocument(account, ownerDocument()) { true })
            val before = store.value
            val auth = NativeStreamingAuthRepository(accounts, scope)
            auth.refresh()
            assertEquals(com.vortx.android.model.AuthState.SignedOut, auth.authState.value)
            assertTrue(auth.management.value.canManage)
            assertTrue(auth.signInForRevision("fake@example.invalid", "fake-password", auth.management.value.revision).isSuccess)
            assertEquals(com.vortx.android.model.AuthState.SignedIn(null, uid), auth.authState.value)
            assertEquals(listOf("login", "getUser"), requests) // Connection is not a hidden library import.
            assertEquals(before, store.value)
            auth.signOutForRevision(auth.management.value.revision)
            assertEquals(com.vortx.android.model.AuthState.SignedOut, auth.authState.value)
            assertEquals(before, store.value)
            assertEquals(owner.id, accounts.session().read().owner.profileID)
        } finally { scope.cancel(); accounts.retire() }
    }

    @Test fun `shared child cannot manage owner credential and old UI revision cannot survive profile ABA`() = runBlocking {
        val accounts = coordinator(Store(), Journal()); val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            assertTrue(accounts.applyDocument(account, ownerDocument()) { true })
            val access = NativeProfileAccess { accounts.session() }
            access.save(child.copy(usesOwnAccount = false), true)
            val auth = NativeStreamingAuthRepository(accounts, scope); auth.refresh()
            assertTrue(auth.signIn("fake@example.invalid", "fake-password").isSuccess)
            val old = auth.management.value.revision
            access.select(child.id); auth.refresh()
            assertEquals(com.vortx.android.model.AuthState.SignedIn(null, uid), auth.authState.value)
            assertFalse(auth.management.value.canManage)
            assertTrue(auth.signInForRevision("fake@example.invalid", "fake-password", auth.management.value.revision).isFailure)
            assertTrue(runCatching { auth.signOutForRevision(auth.management.value.revision) }.isFailure)
            access.select(owner.id); auth.refresh()
            assertTrue(auth.management.value.canManage)
            assertTrue(runCatching { auth.signOutForRevision(old) }.isFailure)
            assertEquals(com.vortx.android.model.AuthState.SignedIn(null, uid), auth.authState.value)
        } finally { scope.cancel(); accounts.retire() }
    }

    @Test fun `retirement after owner UID response leaves staged token inactive and never clears native account`() = runBlocking {
        val journal = Journal(); val store = Store(); lateinit var accounts: NativeAccountCoordinator
        accounts = coordinator(store, journal, after = { if (it == "getUser") accounts.retire() })
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            assertTrue(accounts.applyDocument(account, ownerDocument()) { true })
            val before = store.value
            val auth = NativeStreamingAuthRepository(accounts, scope); auth.refresh()
            assertTrue(auth.signIn("fake@example.invalid", "fake-password").isFailure)
            assertEquals(before, store.value)
            assertTrue(journal.values.keys.none { it.startsWith("owner-selection.") })
            assertEquals(com.vortx.android.model.AuthState.SignedOut, auth.authState.value)
            assertTrue(accounts.reopenCheckpoint(account) { true })
            auth.refresh(); assertEquals(com.vortx.android.model.AuthState.SignedOut, auth.authState.value)
        } finally { scope.cancel(); accounts.retire() }
    }
}
