package com.vortx.android.sync

import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.security.FailClosedCredentialState
import kotlinx.coroutines.async
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual manager/coordinator/store-CAS policy. HTTP and encrypted backend are explicit in-memory seams. */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionRenewalManagerTest {
    private class Fixture(dispatcher: kotlinx.coroutines.CoroutineDispatcher) : AutoCloseable {
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val backend = RenewalBackend()
        val secure = FailClosedCredentialState(backend)
        val original = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
        val manager = VortXSyncManager(RevisionContext(), scope)
        val sent = mutableListOf<String?>()
        var header: String? = RenewalFixtures.next
        var status = 200
        var etag: String? = null
        var emptyBody = true
        var raw: ByteArray? = null
        var beforeResponse: suspend () -> Unit = {}
        val responseBody = JSONObject().put("fixture", "retained")
        init {
            manager.installSyncTestSeam(original, 0, transport = { _, _, _, _ -> 500 to null })
            manager.installSessionRestoreTestSeam(original)
            manager.installSessionRenewalTestSeam(now = { RenewalFixtures.now }, persist = { owner, sent, epoch, next ->
                SessionRenewalPolicy.persistConfirmed(next, sent, owner, epoch,
                    secure.confirmedSnapshot(*SessionRenewalPolicy.tupleKeys), secure::replaceConfirmed).also { saved ->
                    if (saved) manager.installSessionRestoreTestSeam(VortXSyncManager.Session(next, owner.account, owner.dataKey.copyOf()), epoch)
                }
            }, transport = { _, _, bearer ->
                sent += bearer; beforeResponse()
                VortXSyncManager.SessionRenewalTestResponse(status, responseBody, header, etag, emptyBody, raw)
            })
        }
        override fun close() { manager.stopRealtime(); scope.cancel() }
    }

    @Test fun successfulRenewalRetainsResponseSessionEpochPlaybackAndOriginalLeases() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            val lease = requireNotNull(f.manager.captureRealtimeLease())
            val playback = requireNotNull(PlaybackOwnerEpoch.capture())
            val result = f.manager.requestSessionRenewalForTest()
            assertEquals(200, result.first); assertSame(f.responseBody, result.second)
            assertSame(f.original, f.manager.currentSession())
            assertEquals(RenewalFixtures.prior, f.original.token)
            assertEquals(RenewalFixtures.next, f.original.currentBearer)
            assertEquals(RenewalFixtures.next, lease.currentBearer())
            assertTrue(f.manager.isRealtimeLeaseCurrent(lease)); assertTrue(PlaybackOwnerEpoch.isCurrent(playback))
            assertEquals(SessionOwnerSnapshot.Account(RenewalFixtures.accountID, lease.ownerEpoch), f.manager.sessionOwnerSnapshot())
            assertSame(f.original, f.manager.currentSession())
            f.header = null; f.manager.requestSessionRenewalForTest()
            assertEquals(listOf(RenewalFixtures.prior, RenewalFixtures.next), f.sent)
            assertEquals(1, f.backend.writes)
        } finally { f.close() }
    }

    @Test fun durableProviderRetryRequiresAnExplicitPersistedEpochAndFencesScheduledOwners() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            val owner = f.manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
            f.manager.installSessionRestoreTestSeam(f.original, owner.generation, explicitOwnerEpoch = false)
            val legacy = requireNotNull(f.manager.captureProviderRetryOwnerOpener(owner))
            assertNull(legacy())

            f.manager.installSessionRestoreTestSeam(f.original, owner.generation)
            assertNull(legacy())
            val original = requireNotNull(f.manager.captureProviderRetryOwnerOpener(owner))
            val lease = requireNotNull(original())
            val scopedKey = lease.withDataKey { key ->
                assertArrayEquals(f.original.dataKey, key)
                key
            }
            assertTrue(scopedKey.all { it == 0.toByte() })
            assertArrayEquals(RenewalFixtures.key, f.original.dataKey)

            f.manager.requestSessionRenewalForTest()
            lease.requireCurrent()
            assertEquals(owner, requireNotNull(original()).owner)

            val replacement = VortXSyncManager.Session(RenewalFixtures.next, f.original.account, ByteArray(32) { 7 })
            f.manager.replaceSyncSessionTestSeam(replacement)
            f.manager.installSessionRestoreTestSeam(replacement, owner.generation)
            assertNull(original())
            assertThrows(IllegalStateException::class.java) { lease.withDataKey { error("Retired key escaped") } }
            val successor = requireNotNull(requireNotNull(f.manager.captureProviderRetryOwnerOpener(owner))())
            successor.withDataKey { assertArrayEquals(replacement.dataKey, it) }
        } finally { f.close() }
    }

    @Test fun durableProviderRetryLeaseCannotReviveAfterAnUnavailableRead() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            val owner = f.manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
            val opener = requireNotNull(f.manager.captureProviderRetryOwnerOpener(owner))
            val lease = requireNotNull(opener())
            f.manager.installUnavailableSessionRestoreTestSeam()
            assertNull(opener())
            f.manager.installSessionRestoreTestSeam(f.original, owner.generation)
            assertNull(opener())
            assertThrows(IllegalStateException::class.java) { lease.requireCurrent() }
            assertNotNull(requireNotNull(f.manager.captureProviderRetryOwnerOpener(owner))())
        } finally { f.close() }
    }

    @Test fun renewalCannotDiscardTheOriginalOwnedRawDownloadOrChangeItsBytes() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            val document = requireNotNull(VortXCrypto.sealDocument(RenewalFixtures.key, "{}".toByteArray(), RenewalFixtures.accountID, 12, false))
            f.raw = JSONObject().put("document", document).put("version", 12).toString().toByteArray()
            val exported = f.manager.downloadAccountBackupFile()
            assertEquals(document, JSONObject(String(exported)).getString("document"))
            assertEquals(12, JSONObject(String(exported)).getInt("version"))
            assertSame(f.original, f.manager.currentSession()); assertEquals(RenewalFixtures.next, f.original.currentBearer)
            f.header = null; f.manager.downloadAccountBackupFile()
            assertEquals(listOf(RenewalFixtures.prior, RenewalFixtures.next), f.sent)
        } finally { f.close() }
    }

    @Test fun authQrErrorAndInvalid304HeadersAreIgnoredWithoutChangingSuccessfulBodies() = runTest {
        for ((path, status) in listOf("/v1/auth/me" to 200, "/v1/qr/poll" to 200,
            "/v1/backup" to 401, "/v1/backup" to 302, "/v1/backup" to 304)) {
            val f = Fixture(UnconfinedTestDispatcher(testScheduler))
            try {
                f.status = status
                assertEquals(status, f.manager.requestSessionRenewalForTest(path = path).first)
                assertEquals(RenewalFixtures.prior, f.original.currentBearer); assertEquals(0, f.backend.writes)
            } finally { f.close() }
        }
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            assertEquals(200, f.manager.requestSessionRenewalForTest(authPermit = true).first)
            assertEquals(0, f.backend.writes)
            f.status = 304; f.etag = "\"12\""
            assertEquals(304, f.manager.requestSessionRenewalForTest(ifNoneMatch = "\"12\"").first)
            assertEquals(RenewalFixtures.next, f.original.currentBearer)
        } finally { f.close() }
    }

    @Test fun staleOwnerAndChangedKeyAtResponseCannotPublishRenewal() = runTest {
        for (change in listOf("owner", "key")) {
            val f = Fixture(UnconfinedTestDispatcher(testScheduler))
            try {
                val lease = requireNotNull(f.manager.captureRealtimeLease())
                f.beforeResponse = {
                    if (change == "owner") f.manager.installSyncTestSeam(
                        VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key), 0,
                        transport = { _, _, _, _ -> 500 to null })
                    else f.original.dataKey[0] = 99
                }
                f.manager.requestSessionRenewalForTest()
                assertEquals(0, f.backend.writes); assertEquals(RenewalFixtures.prior, f.original.currentBearer)
                assertFalse(f.manager.isRealtimeLeaseCurrent(lease))
            } finally { f.close() }
        }
    }

    @Test fun callerCancellationBeforeHeaderAdmissionCannotPublishRenewal() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            f.beforeResponse = { currentCoroutineContext().cancel() }
            val request = async { f.manager.requestSessionRenewalForTest() }
            try { request.await(); fail("cancelled request returned") } catch (_: CancellationException) { }
            assertEquals(0, f.backend.writes); assertEquals(RenewalFixtures.prior, f.original.currentBearer)
        } finally { f.close() }
    }

    @Test fun lateOldTokenResponseCannotOverwriteAlreadyConfirmedSuccessor() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            val latest = RenewalFixtures.token(RenewalFixtures.now + (121 * RenewalFixtures.day))
            f.beforeResponse = {
                if (f.sent.size == 1) {
                    f.header = latest
                    f.manager.requestSessionRenewalForTest()
                    f.header = RenewalFixtures.next
                }
            }
            assertEquals(200, f.manager.requestSessionRenewalForTest().first)
            assertEquals(latest, f.original.currentBearer); assertEquals(latest, f.backend.values["token"])
            assertEquals(1, f.backend.writes)
        } finally { f.close() }
    }

    @Test fun unconfirmedWritesRetainLiveBearerAndOwnedResponseWithoutRetiringPlayback() = runTest {
        for (mode in listOf("reject", "throw", "readbackFailure", "mismatch", "readFailure")) {
            val f = Fixture(UnconfinedTestDispatcher(testScheduler))
            try {
                f.backend.mode = mode
                val lease = requireNotNull(f.manager.captureRealtimeLease()); val playback = requireNotNull(PlaybackOwnerEpoch.capture())
                assertEquals(200, f.manager.requestSessionRenewalForTest().first)
                assertEquals(RenewalFixtures.prior, f.original.currentBearer); assertSame(f.original, f.manager.currentSession())
                assertTrue(f.manager.isRealtimeLeaseCurrent(lease)); assertTrue(PlaybackOwnerEpoch.isCurrent(playback))
            } finally { f.close() }
        }
    }

    @Test fun confirmedRetryRestoresTruthWithoutReplacingTheRenewedSessionIdentity() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        try {
            f.manager.requestSessionRenewalForTest()
            val lease = requireNotNull(f.manager.captureRealtimeLease())
            f.manager.installUnavailableSessionRestoreTestSeam()
            assertTrue(f.manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session(RenewalFixtures.next, RenewalFixtures.account, RenewalFixtures.key), lease.ownerEpoch)
            assertEquals(SessionOwnerSnapshot.Account(RenewalFixtures.accountID, lease.ownerEpoch), f.manager.sessionOwnerSnapshot())
            assertSame(f.original, f.manager.currentSession()); assertTrue(f.manager.isRealtimeLeaseCurrent(lease))
        } finally { f.close() }
    }

    @Test fun realtimeReconnectUsesConfirmedBearerWithTheOriginalChannelLease() = runTest {
        val f = Fixture(UnconfinedTestDispatcher(testScheduler))
        val sockets = mutableListOf<Socket>()
        try {
            f.header = null
            val realtime = VortXSyncRealtime(f.manager, f.scope, "wss://example.invalid/v1/sync/connect",
                clockMs = { testScheduler.currentTime }, socketFactory = { request, listener -> Socket(request, listener).also(sockets::add) })
            f.manager.installRealtimeTestSeam(realtime); realtime.start()
            assertEquals("Bearer " + RenewalFixtures.prior, sockets.single().request().header("authorization"))
            f.header = RenewalFixtures.next; f.manager.requestSessionRenewalForTest()
            f.header = null; sockets.single().fail()
            advanceTimeBy(1_001); runCurrent()
            assertEquals(2, sockets.size)
            assertEquals("Bearer " + RenewalFixtures.next, sockets.last().request().header("authorization"))
        } finally { f.close() }
    }

    @Test fun watchPartyCarrierTracksOnlyItsOriginalSessionWhileAuthorityChecksStayStrict() {
        val original = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
        val owner = requireNotNull(PlaybackOwnerEpoch.capture())
        fun capture(session: VortXSyncManager.Session) = requireNotNull(WatchPartyAuthSnapshot.capture(
            bearer = session.token, accountId = session.account.id, profileId = "Owner", authGeneration = 0,
            sessionGeneration = 0, ownerEpoch = 1, ownerToken = owner, currentBearer = { session.currentBearer }))
        val snapshot = capture(original)
        assertTrue(original.publishConfirmedRenewal(RenewalFixtures.prior, RenewalFixtures.next))
        assertEquals(RenewalFixtures.next, snapshot.bearer); assertTrue(snapshot.sameAuthorityAs(capture(original)))
        val replacement = VortXSyncManager.Session("replacement", RenewalFixtures.account, RenewalFixtures.key)
        assertFalse(snapshot.sameAuthorityAs(capture(replacement)))
        assertEquals(RenewalFixtures.next, snapshot.bearer)
        PlaybackOwnerEpoch.transition { }
        assertFalse(snapshot.sameAuthorityAs(snapshot))
    }

    @Test fun restartRebindsPendingAccountTruthWithoutClearingOrOrphaningItsDirtyMarker() {
        var dirty = false
        fun state() = DurablePendingSyncState(readDirty = { dirty }, writeDirty = { _, value -> dirty = value; true })
        val oldOwner = PendingSyncOwner(0, 7, RenewalFixtures.accountID, RenewalFixtures.prior)
        state().recordEdit(oldOwner, PendingSyncAttempt(oldOwner))
        val restartedOwner = oldOwner.copy(token = RenewalFixtures.next)
        val claim = state().claimRestored(restartedOwner, PendingSyncAttempt(restartedOwner))
        assertTrue(dirty); assertTrue(claim.blockPull); assertNotNull(claim.attemptToStart)
        assertEquals(7L, restartedOwner.ownerEpoch)
    }

    private class Socket(private val opening: Request, private val listener: WebSocketListener) : WebSocket {
        private var cancelled = false
        override fun request() = opening
        override fun queueSize() = 0L
        override fun send(text: String) = !cancelled
        override fun send(bytes: ByteString) = !cancelled
        override fun close(code: Int, reason: String?): Boolean { cancelled = true; return true }
        override fun cancel() { cancelled = true }
        fun fail() = listener.onFailure(this, IllegalStateException("synthetic disconnect"), null)
    }
}
