package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.NativeAccountReadCapture
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import javax.crypto.SecretKey

/** Pure/pre-native refusal checks, actual coordinator/capture/parser and synthetic owner/probe.
 * The trapping bindings are intentionally not JNI evidence. All methods authored UNRUN. */
class NativeWebsiteRosterAdmissionTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 7)
    private val scope = VortxAccountScope("account.${account.id}", UserProfile.OWNER_ID)
    private fun b(value: String) = value.toByteArray(Charsets.UTF_8)
    private var nativeCalls = 0
    private fun noNativeCall(): Nothing { nativeCalls++; error("No native call admitted") }
    private val noNative = object : VortxRuntimeBindings {
        override fun create(ownerId: String, ownerName: String): Long = noNativeCall()
        override fun hydrate(snapshot: String): Long = noNativeCall()
        override fun dispatch(handle: Long, action: String): String? = noNativeCall()
        override fun resolve(handle: Long, request: String): String? = noNativeCall()
        override fun state(handle: Long): String? = noNativeCall()
        override fun delta(handle: Long): String? = noNativeCall()
        override fun free(handle: Long) = noNativeCall()
    }
    private class Probe(var presence: AccountFileLocalPresence) : VortxCheckpointStore {
        var observations = 0
        override fun inspectWebsiteRosterAbsence(scope: VortxAccountScope,
            readExistingKey: (VortxAccountScope) -> SecretKey?): AccountFileLocalPresence {
            observations++; return presence
        }
        override fun read(scope: VortxAccountScope): String? = error("Production store read forbidden")
        override fun commit(scope: VortxAccountScope, snapshot: String) = error("Production store write forbidden")
    }
    private fun coordinator(probe: Probe) = NativeAccountCoordinator(noNative, probe,
        { error("Production transport factory forbidden") }, { it == account }, { it() },
        { error("Production publication forbidden") }, captureOwnAccountAdmission = { captured ->
            if (captured != account) null else { action -> action() }
        })
    private fun read(raw: ByteArray) = NativeAccountReadCapture.fromAuthenticatedPull(account, 9,
        account.id, account.generation, 17, raw)

    @Test fun `ordinary full roster and native documents fall through before any absence observation`() = runBlocking {
        val probe = Probe(AccountFileLocalPresence.UNAVAILABLE)
        val gateway = coordinator(probe)
        val fullRoster = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(
            UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true).encode().put("addonPreferences", JSONObject())))
            .put("rosterModified", 0)).toString().toByteArray(Charsets.UTF_8)
        for (raw in listOf(fullRoster, b("""{"vortx":{"roster":[]}}"""), b("""{"nativeSync":null,"addons":[]}"""), b("{}"))) {
            val source = read(raw)
            try {
                val original = requireNotNull(gateway.captureUploadOrigin(account) { true })
                assertNull(gateway.withWebsiteRosterCandidate(account, source, original) { error("No callback") })
            } finally { source.retire() }
        }
        assertEquals(0, probe.observations)
        assertEquals(0, nativeCalls)
    }

    @Test fun `eligible sources refuse present or unavailable local evidence before native or callback`() = runBlocking {
        for (presence in listOf(AccountFileLocalPresence.PRESENT, AccountFileLocalPresence.UNAVAILABLE)) {
            val probe = Probe(presence); val gateway = coordinator(probe)
            val source = read(b("""{"addons":[]}"""))
            try {
                val original = requireNotNull(gateway.captureUploadOrigin(account) { true })
                var callbacks = 0
                val result = runCatching { gateway.withWebsiteRosterCandidate(account, source, original) { callbacks++; Unit } }
                assertTrue(result.isFailure)
                assertEquals(0, callbacks)
                assertEquals(1, probe.observations)
                assertEquals(0, nativeCalls)
            } finally { source.retire() }
        }
    }

    @Test fun `credential bearing source and unresolved watched source refuse before native calls`() = runBlocking {
        val credentialSource = b("""{"addons":[{"transportUrl":"https://fixture.invalid/manifest.json","token":"synthetic-secret"}]}""")
        val projectedSecret = requireNotNull(NativeWebsiteRosterProjection.project(credentialSource))
        val rejectedSecret = runCatching { NativeWebsiteRosterAdmission.requireAdmissible(scope, projectedSecret, noNative) {} }
        assertTrue(rejectedSecret.isFailure)
        assertFalse(rejectedSecret.exceptionOrNull()?.message == "No native call admitted")

        // Deliberately opaque nonempty bits: this unit must require original metadata, not
        // turn into an empty watched inventory. This is not a claim that these bits decode.
        val watchedSource = b("""{"addons":[],"library":[{"id":"series-fixture","type":"series","watched":"opaque"}]}""")
        val projectedWatched = requireNotNull(NativeWebsiteRosterProjection.project(watchedSource))
        val rejectedWatched = runCatching { NativeWebsiteRosterAdmission.requireAdmissible(scope, projectedWatched, noNative) {} }
        assertTrue(rejectedWatched.exceptionOrNull() is NativeWebsiteRosterAdmission.MetadataRequired)
        assertEquals(0, nativeCalls)
    }

    @Test fun `retired and wrong account reads never become detached candidates`() = runBlocking {
        val probe = Probe(AccountFileLocalPresence.ABSENT); val gateway = coordinator(probe)
        val original = requireNotNull(gateway.captureUploadOrigin(account) { true })
        val retired = read(b("""{"addons":[]}""")); retired.retire()
        assertTrue(runCatching { gateway.withWebsiteRosterCandidate(account, retired, original) { error("No callback") } }.isFailure)
        val other = account.copy(generation = account.generation + 1)
        val wrong = NativeAccountReadCapture.fromAuthenticatedPull(other, 9, other.id, other.generation, 17, b("""{"addons":[]}"""))
        try { assertNull(gateway.withWebsiteRosterCandidate(account, wrong, original) { error("No callback") }) }
        finally { wrong.retire() }
        assertEquals(0, probe.observations)
        assertEquals(0, nativeCalls)
    }
}
