package com.vortx.android.sync

import com.vortx.android.security.CredentialBackend
import com.vortx.android.security.FailClosedCredentialState
import com.vortx.android.security.PersistentCredentialAvailability
import java.util.Base64
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread
import org.junit.Assert.*
import org.junit.Test

internal object RenewalFixtures {
    const val accountID = "10000000-0000-0000-0000-000000000001"
    const val now = 1_700_000_000_000L
    const val day = 86_400_000L
    val account = VortXSyncManager.Account(accountID, "fixture@example.invalid", "Synthetic", false)
    val key: ByteArray get() = ByteArray(32) { 41 }
    fun token(expiry: Long, version: Long = 1, accountID: String = this.accountID): String =
        rawToken("{\"a\":\"$accountID\",\"v\":$version,\"exp\":$expiry}")
    fun rawToken(payload: String): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(payload.toByteArray()) + "." + Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32))
    val prior: String get() = token(now + day)
    val next: String get() = token(now + 120 * day)
    fun tuple(token: String = prior, epoch: Long = 1): Map<String, String?> = linkedMapOf(
        "token" to token,
        "account" to "{ \"id\":\"$accountID\", \"email\":\"fixture@example.invalid\", \"username\":\"Synthetic\", \"twoFactorEnabled\":false, \"future\":1.00 }",
        "dataKey" to Base64.getEncoder().encodeToString(key), "ownerEpoch" to epoch.toString())
}

internal class RenewalBackend(initial: Map<String, String?> = RenewalFixtures.tuple()) : CredentialBackend {
    val values = initial.toMutableMap()
    var writes = 0
    var mode = "ok"
    var lastWrite: Map<String, String?>? = null
    override fun string(key: String): String? {
        if (mode == "readFailure" || mode == "readbackFailure" && writes > 0) error("synthetic read failure")
        return values[key]
    }
    override fun write(values: Map<String, String?>): Boolean {
        writes++; lastWrite = values.toMap(); this.values.putAll(values)
        if (mode == "throw") error("synthetic write failure")
        if (mode == "mismatch") this.values["account"] = "changed"
        return mode != "reject"
    }
}

class SessionRenewalPolicyTest {
    @Test fun validCustomTwoSegmentRenewalMustExtendSameVersionAndAccount() {
        with(RenewalFixtures) {
            assertTrue(SessionRenewalPolicy.accepts(next, prior, accountID, now))
            for (candidate in listOf(prior, token(now - 1), token(now + 122 * day), token(now + 2 * day, 2),
                token(now + 2 * day, accountID = "10000000-0000-0000-0000-000000000002"), "$next.extra", "$next=")) {
                assertFalse(SessionRenewalPolicy.accepts(candidate, prior, accountID, now))
            }
            assertFalse(SessionRenewalPolicy.accepts(next, token(now), accountID, now))
            assertFalse(SessionRenewalPolicy.accepts(next, prior, accountID, 0))
            assertFalse(SessionRenewalPolicy.accepts(null, prior, accountID, now))
        }
    }

    @Test fun claimsRejectDuplicatesCoercionsUnsafeNumbersAndWrongSignatureShape() {
        with(RenewalFixtures) {
            val prefix = "\"a\":\"$accountID\","
            val tails = listOf("\"v\":1,\"v\":1,\"exp\":${now + day}",
                "\"v\":1.0,\"exp\":${now + day}", "\"v\":1e0,\"exp\":${now + day}",
                "\"v\":\"1\",\"exp\":${now + day}", "\"v\":9007199254740992,\"exp\":${now + day}",
                "\"v\":1,\"exp\":${now + day}.1", "\"v\":-1,\"exp\":${now + day}")
            tails.forEach { assertFalse(SessionRenewalPolicy.accepts(rawToken("{$prefix$it}"), prior, accountID, now)) }
            assertFalse(SessionRenewalPolicy.accepts(next.substringBefore('.') + ".AA", prior, accountID, now))
            assertFalse(SessionRenewalPolicy.accepts(" "+next, prior, accountID, now))
        }
    }

    @Test fun onlySuccessOrExactBodylessConditionalBackup304IsEligible() {
        assertTrue(SessionRenewalPolicy.eligibleResponse("PUT", "/v1/backup", 200, null, null, false))
        assertTrue(SessionRenewalPolicy.eligibleResponse("GET", "/v1/backup", 304, "\"12\"", "\"12\"", true))
        for (path in listOf("/v1/auth", "/v1/auth/me", "/v1/qr", "/v1/qr/poll")) {
            assertFalse(SessionRenewalPolicy.eligibleResponse("GET", path, 200, null, null, true))
        }
        for (status in listOf(0, 301, 302, 400, 401, 404, 426, 500)) {
            assertFalse(SessionRenewalPolicy.eligibleResponse("GET", "/v1/backup", status, null, null, true))
        }
        for (etag in listOf(null, "12", "\"13\"", "W/\"12\"")) {
            assertFalse(SessionRenewalPolicy.eligibleResponse("GET", "/v1/backup", 304, "\"12\"", etag, true))
        }
        assertFalse(SessionRenewalPolicy.eligibleResponse("GET", "/v1/backup", 304, "\"12\"", "\"12\"", false))
        assertFalse(SessionRenewalPolicy.eligibleResponse("GET", "/other", 304, "\"12\"", "\"12\"", true))
    }

    @Test fun actualTupleAdmissionAndCasPreserveRawAccountKeyEpochAndFutureFields() {
        val backend = RenewalBackend(); val state = FailClosedCredentialState(backend)
        val before = backend.values.toMap()
        val session = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
        assertTrue(SessionRenewalPolicy.persistConfirmed(RenewalFixtures.next, RenewalFixtures.prior, session, 1,
            state.confirmedSnapshot(*SessionRenewalPolicy.tupleKeys), state::replaceConfirmed))
        assertEquals(before + ("token" to RenewalFixtures.next), backend.values)
        assertEquals(mapOf("token" to RenewalFixtures.next), backend.lastWrite)
        assertEquals(RenewalFixtures.next, state.confirmedSnapshot("token").values["token"])
    }

    @Test fun durableTupleMismatchOrUnavailabilityCannotBecomeRenewalAuthority() {
        for ((key, value) in listOf("token" to "different", "account" to "{}", "dataKey" to "AA==", "ownerEpoch" to "2")) {
            val backend = RenewalBackend(RenewalFixtures.tuple() + (key to value)); val state = FailClosedCredentialState(backend)
            assertFalse(SessionRenewalPolicy.persistConfirmed(RenewalFixtures.next, RenewalFixtures.prior,
                VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key), 1,
                state.confirmedSnapshot(*SessionRenewalPolicy.tupleKeys), state::replaceConfirmed))
            assertEquals(0, backend.writes)
        }
        val unavailable = FailClosedCredentialState(null)
        assertFalse(unavailable.replaceConfirmed(RenewalFixtures.tuple(), mapOf("token" to RenewalFixtures.next)))
        assertEquals(PersistentCredentialAvailability.UNAVAILABLE, unavailable.confirmedSnapshot("token").availability)
    }

    @Test fun exactCasRejectsStaleSnapshotsAndNeverReopensAfterAmbiguousWriteOrReadback() {
        for (mode in listOf("reject", "throw", "readbackFailure", "mismatch")) {
            val backend = RenewalBackend().apply { this.mode = mode }; var reopens = 0
            val state = FailClosedCredentialState(backend, reopenBackend = { reopens++; backend })
            assertFalse(state.replaceConfirmed(RenewalFixtures.tuple(), mapOf("token" to RenewalFixtures.next)))
            assertFalse(state.hasPersistentBackend)
            assertEquals(PersistentCredentialAvailability.UNAVAILABLE, state.confirmedSnapshot("token").availability)
            assertEquals(RenewalFixtures.prior, state.confirmedSnapshot("token").values["token"])
            assertFalse(state.replaceConfirmed(RenewalFixtures.tuple(), mapOf("token" to RenewalFixtures.next)))
            assertEquals(0, reopens)
            assertEquals(1, backend.writes)
        }
        val backend = RenewalBackend(); val state = FailClosedCredentialState(backend)
        backend.values["account"] = "different raw account bytes"
        assertFalse(state.replaceConfirmed(RenewalFixtures.tuple(), mapOf("token" to RenewalFixtures.next)))
        assertEquals(0, backend.writes)
    }

    @Test fun competingActualCasCallsCanPublishOnlyOneOriginalTupleSuccessor() {
        val backend = RenewalBackend(); val state = FailClosedCredentialState(backend)
        val start = CountDownLatch(1); val results = BooleanArray(2)
        val workers = (0..1).map { index -> thread {
            start.await(); results[index] = state.replaceConfirmed(RenewalFixtures.tuple(), mapOf("token" to "successor-$index"))
        } }
        start.countDown(); workers.forEach { it.join(2_000); assertFalse(it.isAlive) }
        assertEquals(1, results.count { it }); assertEquals(1, backend.writes)
    }
}
