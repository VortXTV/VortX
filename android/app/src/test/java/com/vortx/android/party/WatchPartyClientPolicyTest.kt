package com.vortx.android.party

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class WatchPartyClientPolicyTest {
    private val room = "r".repeat(32)
    private val nonce = "n".repeat(32)
    private val owner = WatchPartyOwnerStamp("engine-one", 17L, 2L, "title-one", "account", "profile", 1L)
    private fun policy(sequence: Long = 0, start: Long = 1000) = WatchPartyClientPolicy(owner, "clock-one", room, 1, sequence, start)
    private fun proof(sequence: Long = 0, remaining: Long = 30_000) = WatchPartyProof(nonce, room, 1, sequence, remaining)
    private fun anchored(): WatchPartyClientPolicy = policy().also { assertTrue(it.acceptProof(proof(), nonce, 1000, 1100, true)) }

    @Test fun actualConnectedFrameDoesNotGrantLeaseOrApplyAuthority() {
        // Exact initial backend shape; `connected` is a transport acknowledgement, not a lease.
        val json = org.json.JSONObject("""{"kind":"connected","role":"leader","roomGeneration":"${room}","leaderTerm":1,"serverSequence":0}""")
        val p = policy()
        assertEquals("connected", json.strictString("kind"))
        assertTrue(p.connectedBaseline(json.opaqueString("roomGeneration"), json.strictLong("leaderTerm"), json.strictLong("serverSequence"), 1050))
        assertFalse(p.anchored)
        assertNull(p.permit(WatchPartyWire.Control("play", owner.titleToken, 0), 1050))
        assertTrue(p.acceptProof(proof(), nonce, 1050, 1100, true))
    }
    @Test fun bootstrapDiscardsUnseenControlThenAnchorsExactProof() {
        val p = policy()
        assertTrue(p.connectedBaseline(room, 1, 4, 1050))
        assertTrue(p.bootstrapEvent(room, 1, 5, 1060))
        assertNull(p.permit(WatchPartyWire.Control("seek", owner.titleToken, 5000), 1060))
        assertFalse(p.acceptProof(proof(4), nonce, 1050, 1100, true))
        assertTrue(p.acceptProof(proof(5), nonce, 1050, 1100, true))
    }
    @Test fun deadlineAnchoredToRequestStartNotResponseArrival() {
        val p = policy()
        assertTrue(p.acceptProof(proof(remaining = 1000), nonce, 1000, 1999, true))
        assertEquals(2000L, p.deadline)
        assertFalse(p.live(2000))
        assertFalse(policy().acceptProof(proof(remaining = 1000), nonce, 1000, 2000, true))
    }
    @Test fun clockRollbackPermanentlyRetiresEpoch() {
        val p = anchored()
        assertFalse(p.observe(1099))
        assertTrue(p.cancelled)
        assertFalse(p.observe(5000))
        assertFalse(p.acceptProof(proof(), nonce, 5000, 5001, false))
    }
    @Test fun proofRejectsUnknownNonceWrongRoomTermSequenceOrHugeLease() {
        assertFalse(policy().acceptProof(proof().copy(nonce = "x".repeat(32)), nonce, 1000, 1100, true))
        assertFalse(policy().acceptProof(proof().copy(room = "x".repeat(32)), nonce, 1000, 1100, true))
        assertFalse(policy().acceptProof(proof().copy(term = 2), nonce, 1000, 1100, true))
        assertFalse(anchored().acceptProof(proof(2), nonce, 1100, 1200, false))
        assertFalse(policy().acceptProof(proof(remaining = 30_001), nonce, 1000, 1100, true))
    }
    @Test fun orderedEventsCannotSkipDuplicateOverflowOrExtendLease() {
        val p = anchored(); val deadline = p.deadline
        assertFalse(p.admitEvent(room, 1, 2, 1200))
        assertTrue(p.admitEvent(room, 1, 1, 1200))
        assertFalse(p.admitEvent(room, 1, 1, 1201))
        assertEquals(deadline, p.deadline)
        val max = policy(MAX_SAFE_INTEGER)
        assertTrue(max.acceptProof(proof(MAX_SAFE_INTEGER), nonce, 1000, 1100, true))
        assertFalse(max.admitEvent(room, 1, MAX_SAFE_INTEGER, 1200))
    }
    @Test fun permitConsumedOnceOnlyOnExactCurrentEngineSessionSourceProfileAndClock() {
        val p = anchored(); assertTrue(p.admitEvent(room, 1, 1, 1200))
        val control = WatchPartyWire.Control("seek", owner.titleToken, 9000)
        val permit = requireNotNull(p.permit(control, 1200))
        for (changed in listOf(owner.copy(generation = "engine-two"), owner.copy(sourceRevision = 3),
            owner.copy(outerSessionId = 18), owner.copy(accountId = "other"), owner.copy(profileId = "other"), owner.copy(ownerEpoch = 2))) {
            assertFalse(p.consume(permit, changed, 1201))
        }
        assertFalse(p.consume(permit.copy(clockEpoch = "other"), owner, 1201))
        assertTrue(p.consume(permit, owner, 1201))
        assertFalse(p.consume(permit, owner, 1201))
    }
    @Test fun permitCannotApplyAfterNewerEventOrWrongMedia() {
        val p = anchored(); assertTrue(p.admitEvent(room, 1, 1, 1200))
        assertNull(p.permit(WatchPartyWire.Control("seek", "another-title", 1), 1200))
        val permit = requireNotNull(p.permit(WatchPartyWire.Control("seek", owner.titleToken, 1), 1200))
        assertTrue(p.admitEvent(room, 1, 2, 1201))
        assertFalse(p.consume(permit, owner, 1201))
    }
    @Test fun interleavedLeaseSurvivesOlderSuspendedMemberRenewalCompletion() = runTest {
        val ledger = WatchPartyRefreshLedger()
        ledger.leaseObserved(5)
        val captured = ledger.beginRefresh()
        val oldRequest = launch { delay(1000); ledger.completeRefresh(captured) }
        runCurrent()
        ledger.leaseObserved(6) // ordered WS event arrives while real HTTP work is suspended
        advanceTimeBy(1000); runCurrent(); oldRequest.join()
        assertEquals(5L, ledger.covered)
        assertTrue(ledger.needsRefresh)
        ledger.completeRefresh(ledger.beginRefresh())
        assertFalse(ledger.needsRefresh)
    }
    @Test fun guestCadencePrecedesOldClampedMemberDeadline() {
        for (remaining in listOf(300L, 1000L, 5000L, 30_000L)) {
            val wait = WatchPartyClientPolicy.refreshDelay(1000, 1000 + remaining)
            assertTrue(wait in 100..5000)
            assertTrue(wait < remaining)
        }
    }
    @Test fun retiredNonceHistoryIsBoundedAndIgnoresOnlyExactKnownValues() {
        val history = WatchPartyRetiredNonces(2)
        val a = "a".repeat(32); val b = "b".repeat(32); val c = "c".repeat(32)
        history.retire(a); history.retire(b); history.retire(c)
        assertFalse(history.contains(a)); assertTrue(history.contains(b)); assertTrue(history.contains(c))
        assertFalse(history.contains("unknown".repeat(4)))
    }
}
