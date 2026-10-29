package com.vortx.android.party

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Exercises the production session through controlled authority, HTTP, socket, time and player seams. */
@OptIn(ExperimentalCoroutinesApi::class)
class WatchPartyClientSessionTest {
    private class Harness(val test: TestScope) {
        val auth = SessionAuth()
        val transport = SessionTransport()
        val applied = mutableListOf<WatchPartyWire.Control>()
        var duplicatePermitAccepted = false
        var leaderPosition = 12_345L
        val session = WatchPartyClientSession(
            authAuthority = auth, currentOwner = { auth.owner() },
            apply = { control, permit, policy ->
                val first = policy.consume(permit, auth.owner(), test.testScheduler.currentTime + 100)
                duplicatePermitAccepted = policy.consume(permit, auth.owner(), test.testScheduler.currentTime + 100)
                if (first) applied += control
                first
            }, now = { test.testScheduler.currentTime + 100 }, transport = transport,
            assertMainThread = {}, currentLeaderControl = {
                WatchPartyWire.Control("play", auth.owner().titleToken, leaderPosition)
            },
        )
        fun pump() = test.runCurrent()
        fun connect(leader: Boolean): SessionSocket {
            if (leader) session.create() else session.join(WatchPartyInvite.make(SessionValues.roomId, SessionValues.invite, SessionValues.key))
            pump()
            transport.requests.last().result.complete(if (leader) SessionValues.created() else SessionValues.joined())
            pump()
            transport.requests.last().result.complete(SessionValues.ticket())
            pump()
            val socket = transport.sockets.last(); socket.open(); pump()
            socket.frame(SessionValues.connected(leader)); pump()
            val challenge = socket.sent.last { it.optString("kind") == "lease.challenge" }
            socket.frame(SessionValues.proof(challenge.getString("nonce"), 0)); pump()
            assertEquals(WatchPartyClientSession.UiState.Phase.CONNECTED, session.state.value.phase)
            // Backend broadcasts member-ready after the guest's first valid proof.
            if (!leader) { socket.frame(SessionValues.event("member-ready", 1)); pump() }
            return socket
        }
        fun close() { session.close(); pump() }
    }

    private fun runCase(body: TestScope.(Harness) -> Unit) = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val h = Harness(this)
        try { body(h) } finally { h.close(); Dispatchers.resetMain() }
    }

    @Test fun guestReceivesAuthenticatedInitialStateAndCannotApplyTwice() = runCase { h ->
        val socket = h.connect(false)
        val encrypted = WatchPartyWire.seal(WatchPartyWire.Control("pause", h.auth.owner().titleToken, 12_345),
            SessionValues.key, SessionValues.generation, 1, 2)
        socket.frame(SessionValues.event("sealed", 2, encrypted)); h.pump()
        assertEquals(1, h.applied.size)
        assertEquals(12_345L, h.applied.single().positionMs)
        assertFalse(h.duplicatePermitAccepted)
        assertFalse(socket.sent.any { it.optString("kind") == "publish" })
        socket.frame(SessionValues.event("sealed", 2, encrypted)); h.pump()
        assertEquals(1, h.applied.size); assertTrue(socket.closed)
    }

    @Test fun secondLeaseDuringSuspendedRenewRequiresAnotherHttpRefresh() = runCase { h ->
        val socket = h.connect(false)
        socket.frame(SessionValues.event("lease-renewed", 2)); h.pump()
        advanceTimeBy(5_000); h.pump()
        val first = h.transport.requests.last(); assertTrue(first.path.endsWith("/renew"))
        socket.frame(SessionValues.event("lease-renewed", 3)); h.pump()
        first.result.complete(JSONObject()); h.pump()
        val challenge = socket.sent.last { it.optString("kind") == "lease.challenge" }
        socket.frame(SessionValues.proof(challenge.getString("nonce"), 3)); h.pump()
        val second = h.transport.requests.last()
        assertNotSame(first, second); assertTrue(second.path.endsWith("/renew"))
        assertFalse(second.result.isCompleted)
    }

    @Test fun memberReadyWinningOldGrantUsesNewReservationAndCurrentState() = runCase { h ->
        val socket = h.connect(true)
        h.session.publish("seek", 1_000); h.pump()
        assertEquals("reserve", socket.sent.last().getString("kind"))
        h.leaderPosition = 9_876
        socket.frame(SessionValues.event("member-ready", 1)); h.pump()
        socket.frame(JSONObject().put("kind", "reservation").put("reservationId", "Q".repeat(24))
            .put("roomGeneration", SessionValues.generation).put("leaderTerm", 1).put("serverSequence", 1)); h.pump()
        assertEquals(2, socket.sent.count { it.optString("kind") == "reserve" })
        assertFalse(socket.sent.any { it.optString("kind") == "publish" })
        socket.frame(JSONObject().put("kind", "reservation").put("reservationId", "V".repeat(24))
            .put("roomGeneration", SessionValues.generation).put("leaderTerm", 1).put("serverSequence", 2)); h.pump()
        val publish = socket.sent.last(); assertEquals("publish", publish.getString("kind"))
        val invite = WatchPartyInvite.parse(h.session.shareLink())!!
        val key = invite.copyKey()
        try { assertEquals(9_876L, WatchPartyWire.open(publish.getString("ciphertext"), key, SessionValues.generation, 1, 2).positionMs) }
        finally { key.fill(0); invite.erase() }
    }

    @Test fun readySupersedingSentPublishWaitsForItsStaleErrorBeforeRetry() = runCase { h ->
        val socket = h.connect(true)
        h.session.publish("seek", 1_000); h.pump()
        socket.frame(JSONObject().put("kind", "reservation").put("reservationId", "Q".repeat(24))
            .put("roomGeneration", SessionValues.generation).put("leaderTerm", 1).put("serverSequence", 1)); h.pump()
        val first = socket.sent.last(); assertEquals("publish", first.getString("kind"))
        h.leaderPosition = 8_765
        socket.frame(SessionValues.event("member-ready", 1)); h.pump()
        assertEquals(1, socket.sent.count { it.optString("kind") == "reserve" })
        socket.frame(JSONObject().put("kind", "error").put("code", "stale-reservation")); h.pump()
        assertEquals(2, socket.sent.count { it.optString("kind") == "reserve" })
        socket.frame(JSONObject().put("kind", "reservation").put("reservationId", "V".repeat(24))
            .put("roomGeneration", SessionValues.generation).put("leaderTerm", 1).put("serverSequence", 2)); h.pump()
        val second = socket.sent.last(); assertEquals("publish", second.getString("kind"))
        assertNotEquals(first.getString("ciphertext"), second.getString("ciphertext"))
        val invite = WatchPartyInvite.parse(h.session.shareLink())!!; val key = invite.copyKey()
        try { assertEquals(8_765L, WatchPartyWire.open(second.getString("ciphertext"), key, SessionValues.generation, 1, 2).positionMs) }
        finally { key.fill(0); invite.erase() }
    }

    @Test fun ordinaryJoinSupersedesBothUnsentGrantAndSentPublication() = runCase { first ->
        fun grant(sequence: Int, id: String) = JSONObject().put("kind", "reservation").put("reservationId", id.repeat(24))
            .put("roomGeneration", SessionValues.generation).put("leaderTerm", 1).put("serverSequence", sequence)
        val socket = first.connect(true)
        first.session.publish("seek", 1_000); first.pump()
        first.leaderPosition = 7_000
        socket.frame(SessionValues.event("member-joined", 1)); first.pump()
        socket.frame(grant(1, "Q")); first.pump()
        assertEquals(2, socket.sent.count { it.optString("kind") == "reserve" })
        assertFalse(socket.sent.any { it.optString("kind") == "publish" })
        socket.frame(grant(2, "V")); first.pump()
        val refreshed = socket.sent.last(); assertEquals("publish", refreshed.getString("kind"))
        val firstInvite = WatchPartyInvite.parse(first.session.shareLink())!!; val firstKey = firstInvite.copyKey()
        try { assertEquals(7_000L, WatchPartyWire.open(refreshed.getString("ciphertext"), firstKey, SessionValues.generation, 1, 2).positionMs) }
        finally { firstKey.fill(0); firstInvite.erase() }

        val second = Harness(this)
        try {
            val other = second.connect(true)
            second.session.publish("seek", 2_000); second.pump()
            other.frame(grant(1, "Q")); second.pump()
            val stale = other.sent.last(); assertEquals("publish", stale.getString("kind"))
            second.leaderPosition = 6_000
            other.frame(SessionValues.event("member-joined", 1)); second.pump()
            assertEquals(1, other.sent.count { it.optString("kind") == "reserve" })
            other.frame(JSONObject().put("kind", "error").put("code", "stale-reservation")); second.pump()
            assertEquals(2, other.sent.count { it.optString("kind") == "reserve" })
            other.frame(grant(2, "V")); second.pump()
            val fresh = other.sent.last(); assertEquals("publish", fresh.getString("kind"))
            assertNotEquals(stale.getString("ciphertext"), fresh.getString("ciphertext"))
            val invite = WatchPartyInvite.parse(second.session.shareLink())!!; val key = invite.copyKey()
            try { assertEquals(6_000L, WatchPartyWire.open(fresh.getString("ciphertext"), key, SessionValues.generation, 1, 2).positionMs) }
            finally { key.fill(0); invite.erase() }
        } finally { second.close() }
    }

    @Test fun profileAtoBtoACannotReviveOldRoomOrLateSocket() = runCase { h ->
        val old = h.connect(false)
        h.auth.rotate("profile-b"); h.auth.rotate("profile-a")
        advanceTimeBy(251); h.pump()
        assertTrue(old.closed)
        assertEquals(WatchPartyClientSession.UiState.Phase.CLOSED, h.session.state.value.phase)
        val replacement = h.connect(false)
        assertNotSame(old, replacement)
        assertFalse(old.isActive())
        assertFalse(old.tryFrame(SessionValues.event("member-left", 1)))
        h.pump()
        assertEquals(WatchPartyClientSession.UiState.Phase.CONNECTED, h.session.state.value.phase)
        assertTrue(h.applied.isEmpty())
    }

    @Test fun timedOutReservationCannotPublishOrReviveOnFreshSocket() = runCase { h ->
        val old = h.connect(true)
        h.session.publish("seek", 2_000); h.pump()
        assertEquals("reserve", old.sent.last().getString("kind"))
        advanceTimeBy(5_001); h.pump()
        assertTrue(old.closed)
        assertFalse(old.sent.any { it.optString("kind") == "publish" })
        val replacement = h.connect(true)
        assertNotSame(old, replacement)
        assertFalse(replacement.sent.any { it.optString("kind") == "publish" })
    }

    @Test fun cancelledOldHttpCompletionCannotStartOrOverwriteReplacement() = runCase { h ->
        h.session.create(); h.pump()
        val old = h.transport.requests.last()
        h.session.ownerChanged(); h.session.create(); h.pump()
        val replacement = h.transport.requests.last(); assertNotSame(old, replacement)
        old.result.complete(SessionValues.created()); h.pump()
        assertEquals(WatchPartyClientSession.UiState.Phase.CONNECTING, h.session.state.value.phase)
        assertTrue(h.transport.sockets.isEmpty())
        replacement.result.complete(SessionValues.created()); h.pump()
        assertTrue(h.transport.requests.last().path.endsWith("/ticket"))
    }
}
