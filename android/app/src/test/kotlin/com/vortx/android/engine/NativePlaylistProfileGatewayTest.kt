package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import java.nio.file.Files
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Proposed JNI-backed regression source for the captured playlist adapter. UNRUN in this packet. */
class NativePlaylistProfileGatewayTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 17)
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
    private val scope = VortxAccountScope("account.${account.id}", owner.id)
    private val playlistID = "00000000-0000-0000-0000-000000000101"
    private val playlistField = NativePlaylist.field(java.util.UUID.fromString(playlistID))

    private fun playlist() = NativePlaylist.encodedValue(NativePlaylist.Document(playlistID, "Saved",
        listOf(NativePlaylist.Entry("00000000-0000-0000-0000-000000000201", "tt000101",
            "movie", "Saved title"))))

    private fun bindings(): VortxRuntimeBindings {
        assumeTrue(System.getenv("VORTX_JNI_SYNC") == "1" && !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        return object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) =
                VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
    }

    private fun document() = JSONObject().put("vortx", JSONObject()
        .put("roster", JSONArray().put(owner.encode())).put("rosterModified", 1)
        .put("library", JSONArray()).put("addons", JSONArray()))

    private inner class Fixture : AutoCloseable {
        val directory = Files.createTempDirectory("native-playlist-profile-").toFile()
        val disk = VortxEncryptedCheckpointStore(directory) { SecretKeySpec(ByteArray(32) { 73 }, "AES") }
        var current = true
        var admissionEpoch = 1L
        val accounts = NativeAccountCoordinator(bindings(), disk, { object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No network")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network")
        } }, { it == account && current }, { it() }, {},
            captureOwnAccountAdmission = { expected ->
                val capturedEpoch = admissionEpoch
                val capturedAdmission: (() -> Boolean) -> Boolean = { action ->
                    expected == account && current && admissionEpoch == capturedEpoch && action()
                }
                capturedAdmission
            })
        override fun close() {
            accounts.retire()
            directory.deleteRecursively()
        }
    }

    @Test fun `generic JNI route fails closed before playlist mint or checkpoint replacement`() = runBlocking {
        Fixture().use { fixture ->
            assertTrue(fixture.accounts.applyDocument(account, document()) { fixture.current })
            val session = fixture.accounts.session()
            val read = session.read()
            assertFalse(session.hasOwnerHistory())
            assertTrue(runCatching { session.withCompleteAccountExportRead { } }.isFailure)
            val before = fixture.disk.captureCheckpoint(scope).plaintext
            val playlistRevision = session.playlistUpdates.value

            // Broad progress/session updates do not drive the playlist projection flow.
            session.dispatch(emptyList(), read.owner, progressOnly = true)
            assertEquals(playlistRevision, session.playlistUpdates.value)

            // The public adapter cannot mint a Target on a route with only the 32 MiB local bound.
            assertTrue(fixture.accounts.capturePlaylistProfile().isFailure)

            // Even an internal caller that bypasses adapter capture cannot enable generic fallback.
            val bypass = runCatching {
                session.dispatchBudgetedPlaylist(read.owner,
                    JSONObject().put(playlistField, playlist()), beforeCommit = {})
            }
            assertTrue(bypass.isFailure)
            assertEquals(before, fixture.disk.captureCheckpoint(scope).plaintext)
            assertFalse(session.requiresRecovery()) // Rejection preceded candidate construction/commit.
            assertEquals(playlistRevision, session.playlistUpdates.value)

            val profiles = session.read().state.getJSONObject("nativeHostPreferenceState")
                .getJSONObject("document").getJSONObject("profiles")
            val fields = profiles.optJSONObject(NativeHostPreferences.canonicalProfileID(owner.id))
                ?.optJSONObject("fields")
            assertFalse(fields?.has(playlistField) == true)
        }
    }

    @Test fun `owner history full account budget rejects bytes the local checkpoint bound would allow`() {
        val within = OHJson.Obj().set("future", OHJson.quote("x".repeat(5_000_000))).encoded()
        assertArrayEquals(within, NativeOwnerHistoryAccount(within).validateBudget(writeV2 = true))

        // About 6 MiB plaintext is far below the generic encrypted checkpoint's 32 MiB limit,
        // but exceeds the mandatory 7 MiB base64-sealed complete-account envelope.
        val localOnlySized = OHJson.Obj().set("future", OHJson.quote("x".repeat(6_000_000))).encoded()
        assertTrue(localOnlySized.size < 32 * 1024 * 1024 - 28)
        val failure = assertThrows(IllegalArgumentException::class.java) {
            NativeOwnerHistoryAccount(localOnlySized).validateBudget(writeV2 = true)
        }
        assertEquals("Complete account exceeds encrypted budget", failure.message)
    }
}
