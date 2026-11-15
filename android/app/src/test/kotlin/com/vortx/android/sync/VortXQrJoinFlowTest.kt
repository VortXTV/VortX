package com.vortx.android.sync

import com.vortx.android.sync.NativeAccountSyncTest.TestContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class VortXQrJoinFlowTest {
    @Test
    fun pollDispositionSeparatesExpiryRetryApprovalAndPending() {
        assertEquals(
            VortXSyncManager.QrPollDisposition.EXPIRED,
            VortXSyncManager.qrPollDisposition(404, false),
        )
        assertEquals(
            VortXSyncManager.QrPollDisposition.EXPIRED,
            VortXSyncManager.qrPollDisposition(410, false),
        )
        listOf(0, 408, 429, 500, 503).forEach { status ->
            assertEquals(
                VortXSyncManager.QrPollDisposition.RETRIABLE_ERROR,
                VortXSyncManager.qrPollDisposition(status, false),
            )
        }
        assertEquals(
            VortXSyncManager.QrPollDisposition.READY,
            VortXSyncManager.qrPollDisposition(200, true),
        )
        assertEquals(
            VortXSyncManager.QrPollDisposition.PENDING,
            VortXSyncManager.qrPollDisposition(200, false),
        )
    }

    @Test
    fun approvedEnvelopeMustAuthenticateBeforeItCanBecomeADataKey() {
        val joiner = VortXPairingCrypto.newEphemeral()
        val dataKey = ByteArray(32) { it.toByte() }
        val (claim, wrapped) = requireNotNull(
            VortXPairingCrypto.wrapDataKey(dataKey, joiner.publicKeyBase64URL),
        )
        val envelope = JSONObject()
            .put("claim", claim)
            .put("wrapped", wrapped)
            .toString()

        assertArrayEquals(
            dataKey,
            VortXSyncManager.unwrapQrPayload(envelope, joiner.privateKey),
        )
        assertNull(VortXSyncManager.unwrapQrPayload("{}", joiner.privateKey))
        assertNull(VortXSyncManager.unwrapQrPayload(envelope, VortXPairingCrypto.newEphemeral().privateKey))
    }

    private class Relay {
        val sync = VortXSyncManager(TestContext())
        val owner = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
        val key = ByteArray(32) { (it + 1).toByte() }
        private val previous = VortXSyncManager.Session("previous-fixture", owner, ByteArray(32) { 7 })
        private val pairingBearer = "paired-fixture"
        private lateinit var publicKey: String
        var statusRequests = 0
            private set
        var accountRequests = 0
            private set
        var accountStatus = 503
        var accountResponseGate: CompletableDeferred<Unit>? = null
        var beforeAccountCommit: (() -> Unit)? = null
        var persistRequests = 0
            private set
        val firstLookup = CompletableDeferred<Unit>()

        init {
            // Keep the real adoption path and replace only the OS secure persistence boundary.
            val durable = sync.javaClass.getDeclaredField("sessionState").apply { isAccessible = true }.get(sync)
            val persist: (VortXSyncManager.Session, Long) -> Boolean = { session, epoch ->
                persistRequests++
                sync.installSessionRestoreTestSeam(session, epoch)
                true
            }
            durable.javaClass.getDeclaredField("persist").apply { isAccessible = true }.set(durable, persist)
            sync.installSyncTestSeam(previous, 0, transport = { _, path, body, bearer ->
                when (path) {
                    "/v1/qr/start" -> {
                        publicKey = checkNotNull(body).getString("devicePublicKey")
                        200 to JSONObject().put("pairingID", "fixture-pairing").put("code", "ABCDEFGH")
                    }
                    "/v1/qr/status?id=fixture-pairing" -> {
                        statusRequests++
                        if (statusRequests != 1) 404 to null
                        else {
                            val (claim, wrapped) = checkNotNull(VortXPairingCrypto.wrapDataKey(key, publicKey))
                            val payload = JSONObject().put("claim", claim).put("wrapped", wrapped).toString()
                            200 to JSONObject().put("token", pairingBearer).put("payload", payload)
                        }
                    }
                    "/v1/auth/me" -> {
                        assertEquals(pairingBearer, bearer)
                        accountRequests++
                        firstLookup.complete(Unit)
                        accountResponseGate?.await()
                        accountStatus to if (accountStatus == 200) JSONObject().put("account",
                            object : JSONObject() {
                                override fun optString(key: String): String {
                                    if (key == "email") beforeAccountCommit?.invoke()
                                    return super.optString(key)
                                }
                            }.put("id", owner.id).put("email", owner.email).put("username", owner.username))
                        else null
                    }
                    else -> error("Unexpected request outside the QR fixture")
                }
            })
            sync.installSessionRestoreTestSeam(previous)
        }
    }

    @Test
    fun deliveredApprovalRetriesAccountLookupAndAdoptsOnlyOnce() = runBlocking {
        val relay = Relay()
        try {
            val session = checkNotNull(relay.sync.qrStart())
            session.use {
                val lookupGate = CompletableDeferred<Unit>()
                relay.accountResponseGate = lookupGate
                val firstPoll = async { relay.sync.qrPoll(session) }
                withTimeout(5_000) { relay.firstLookup.await() }
                assertEquals(VortXSyncManager.QrJoinResult.Pending, relay.sync.qrPoll(session))
                lookupGate.complete(Unit)
                assertEquals(VortXSyncManager.QrJoinResult.TransportError, firstPoll.await())
                for (status in listOf(0, 408, 429)) {
                    relay.accountStatus = status
                    assertEquals(VortXSyncManager.QrJoinResult.TransportError, relay.sync.qrPoll(session))
                }
                assertEquals("previous-fixture", relay.sync.currentSession()?.token)

                relay.accountStatus = 200
                val completion = PickerAuthCompletion()
                assertEquals(VortXSyncManager.QrJoinResult.SignedIn(relay.owner.email), relay.sync.qrPoll(session, completion))
                assertArrayEquals(relay.key, checkNotNull(relay.sync.currentSession()).dataKey)
                assertEquals(VortXSyncManager.QrJoinResult.Failed, relay.sync.qrPoll(session))
                assertNull(session.currentApproval())
                assertEquals(1, relay.statusRequests)
                assertEquals(5, relay.accountRequests)
            }
        } finally {
            relay.sync.cancelSyncTestWork()
        }
    }

    @Test
    fun authorizationRefusalAndRetiredAttemptReleaseApproval() = runBlocking {
        for (supersede in listOf(false, true)) {
            val relay = Relay()
            try {
                checkNotNull(relay.sync.qrStart()).use { session ->
                    assertEquals(VortXSyncManager.QrJoinResult.TransportError, relay.sync.qrPoll(session))
                    if (supersede) checkNotNull(relay.sync.qrStart()).close()
                    else relay.accountStatus = 401
                    assertEquals(VortXSyncManager.QrJoinResult.Failed, relay.sync.qrPoll(session))
                    assertFalse(session.isOpen())
                    assertNull(session.currentApproval())
                    assertEquals("previous-fixture", relay.sync.currentSession()?.token)
                    assertEquals(1, relay.statusRequests)
                    assertEquals(if (supersede) 1 else 2, relay.accountRequests)
                }
            } finally {
                relay.sync.cancelSyncTestWork()
            }
        }
    }

    @Test
    fun closingAfterLookupButBeforeCommitLeavesPreviousSession() = runBlocking {
        val relay = Relay()
        try {
            checkNotNull(relay.sync.qrStart()).use { session ->
                relay.accountStatus = 200
                // The production poll validates liveness and the account id before reading
                // the remaining adoption fields. Close in that exact pre-commit window.
                relay.beforeAccountCommit = session::close
                assertEquals(VortXSyncManager.QrJoinResult.Failed, relay.sync.qrPoll(session, PickerAuthCompletion()))
                assertFalse(session.isOpen())
                assertNull(session.currentApproval())
                assertEquals(0, relay.persistRequests)
                assertEquals("previous-fixture", relay.sync.currentSession()?.token)
            }
        } finally {
            relay.sync.cancelSyncTestWork()
        }
    }
}
