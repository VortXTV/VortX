package com.vortx.android.sync

import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.player.PlaybackOwnerToken
import org.junit.Assert.*
import org.junit.Test

/** Synthetic authority tests; no session store, network, device or real account is involved. */
class WatchPartyAuthSnapshotTest {
    private val account = "12345678-1234-4234-8234-123456789abc"

    private fun capture(
        token: PlaybackOwnerToken = checkNotNull(PlaybackOwnerEpoch.capture()),
        bearer: String = "synthetic.bearer.token",
        accountId: String = account,
        profileId: String = "Owner",
        auth: Long = 0L,
        session: Long = 0L,
        owner: Long = 1L,
    ) = WatchPartyAuthSnapshot.capture(bearer, accountId, profileId, auth, session, owner, token)

    @Test fun sameLiveAuthorityMatchesWithoutExposingCredentialsInDiagnostics() {
        val token = checkNotNull(PlaybackOwnerEpoch.capture())
        val first = checkNotNull(capture(token))
        val same = checkNotNull(capture(token))
        assertTrue(first.sameAuthorityAs(same))
        assertEquals("WatchPartyAuthSnapshot(redacted)", first.toString())
        assertFalse(first.toString().contains(first.bearer))
        assertFalse(first.toString().contains(first.accountId))
        assertFalse(first.toString().contains(first.profileId))
    }

    @Test fun everyAuthorityCoordinateMustStillMatchAfterSuspension() {
        val token = checkNotNull(PlaybackOwnerEpoch.capture())
        val first = checkNotNull(capture(token))
        val changed = listOf(
            capture(token, bearer = "replacement.bearer.token"),
            capture(token, accountId = "87654321-4321-4321-8321-cba987654321"),
            capture(token, profileId = "Other"), capture(token, auth = 1L),
            capture(token, session = 1L), capture(token, owner = 2L),
        )
        changed.forEach { assertFalse(first.sameAuthorityAs(checkNotNull(it))) }
    }

    @Test fun samePublicAccountAndProfileCannotReviveRetiredOwner() {
        val token = checkNotNull(PlaybackOwnerEpoch.capture())
        val first = checkNotNull(capture(token))
        PlaybackOwnerEpoch.transition { assertNull(PlaybackOwnerEpoch.capture()) }
        val replacement = checkNotNull(capture())
        assertFalse(first.sameAuthorityAs(replacement))
        assertFalse(first.sameAuthorityAs(first))
        assertNull(capture(token))
    }

    @Test fun invalidOrHeaderUnsafeAuthorityNeverCaptures() {
        assertNull(capture(bearer = "")); assertNull(capture(bearer = "has whitespace"))
        assertNull(capture(bearer = "token\r\nInjected: value"))
        assertNull(capture(accountId = "not-an-account"))
        assertNull(capture(accountId = account.uppercase()))
        assertNull(capture(accountId = "1-1-1-1-1"))
        assertNull(capture(profileId = "")); assertNull(capture(profileId = "profile\u0000"))
        assertNull(capture(auth = -1L)); assertNull(capture(session = -1L))
        assertNull(capture(owner = 0L))
    }

    @Test fun newAuthIntentRetiresPartyAuthorityEvenBeforeASessionCommit() {
        val coordinator = SessionOperationCoordinator()
        val token = checkNotNull(PlaybackOwnerEpoch.capture())
        val before = coordinator.snapshotAuthority { auth, session -> checkNotNull(capture(token, auth = auth, session = session)) }
        coordinator.beginAuth()
        val after = coordinator.snapshotAuthority { auth, session -> checkNotNull(capture(token, auth = auth, session = session)) }
        assertEquals(before.sessionGeneration, after.sessionGeneration)
        assertTrue(after.authGeneration > before.authGeneration)
        assertFalse(before.sameAuthorityAs(after))
    }

    @Test fun failedOwnerMutationStillRetiresOldPartyAndDoesNotReuseItsGeneration() {
        val coordinator = SessionOperationCoordinator()
        val before = coordinator.snapshotAuthority { auth, session -> checkNotNull(capture(auth = auth, session = session)) }
        val failure = IllegalStateException("synthetic persistence refusal")
        assertSame(failure, runCatching { coordinator.invalidate<Unit> { throw failure } }.exceptionOrNull())
        val after = coordinator.snapshotAuthority { auth, session -> checkNotNull(capture(auth = auth, session = session)) }
        assertTrue(after.authGeneration > before.authGeneration)
        assertTrue(after.sessionGeneration > before.sessionGeneration)
        assertFalse(before.sameAuthorityAs(after))
    }
}
