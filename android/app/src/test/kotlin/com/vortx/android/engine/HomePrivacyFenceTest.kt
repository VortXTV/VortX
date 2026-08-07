package com.vortx.android.engine

import com.vortx.android.library.WatchedIndex
import com.vortx.android.model.AuthState
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class HomePrivacyFenceTest {
    @Test
    fun `own account engine history requires matching native email`() {
        val ownAccount = UserProfile(
            name = "Separate account",
            avatar = "person",
            usesOwnAccount = true,
            email = "own@example.com",
        )

        assertFalse(
            engineHistoryPrincipalMatches(
                ownAccount,
                AuthState.SignedIn(email = "primary@example.com", uid = "primary"),
            ),
        )
        assertTrue(
            engineHistoryPrincipalMatches(
                ownAccount,
                AuthState.SignedIn(email = "OWN@example.com", uid = "own"),
            ),
        )
        assertFalse(engineHistoryPrincipalMatches(ownAccount, AuthState.SignedOut))
    }

    @Test
    fun `owner profile continues to use the active native account`() {
        val owner = UserProfile(name = "Owner", avatar = "person", isOwner = true)
        assertTrue(engineHistoryPrincipalMatches(owner, AuthState.SignedOut))
    }

    @Test
    fun `failed or incomplete sign-in retains an existing privacy fence`() {
        val fence = HomePrivacyFence(initiallySuppressed = true)
        val failedAttempt = fence.beginSignIn("request-a")

        fence.completeSignIn(attempt = failedAttempt, accountUid = null)
        assertTrue(fence.isRaised)

        val incompleteAttempt = fence.beginSignIn("request-b")
        fence.completeSignIn(attempt = incompleteAttempt, accountUid = "")
        assertTrue(fence.isRaised)
    }

    @Test
    fun `logout raises privacy fence before dispatch can publish an event`() {
        val fence = HomePrivacyFence()
        var dispatchObservedFence = false

        fence.beforeLogout {
            dispatchObservedFence = fence.isRaised
        }

        assertTrue(dispatchObservedFence)
        assertTrue(fence.isRaised)
    }

    @Test
    fun `only verified sign-in with matching account uid lowers fence`() {
        val fence = HomePrivacyFence(initiallySuppressed = true)
        val attempt = fence.beginSignIn("request-a")
        fence.noteContinueWatchingRefresh(fence.previewTicket(1), "account-a")

        fence.completeSignIn(attempt = attempt, accountUid = "account-a")

        assertFalse(fence.isRaised)
    }

    @Test
    fun `logout invalidates a sign-in completion already in flight`() {
        val fence = HomePrivacyFence(initiallySuppressed = true)
        val staleAttempt = fence.beginSignIn("request-a")

        fence.beforeLogout { }
        fence.completeSignIn(attempt = staleAttempt, accountUid = "account-a")

        assertTrue(fence.isRaised)
    }

    @Test
    fun `stale pre-logout snapshot cannot publish after privacy generation advances`() {
        val fence = HomePrivacyFence()
        fence.establishFreshEngineState(isSignedIn = false, signedInUid = null, accountUidVerified = true)
        val stale = fence.capture()
        var published = false

        fence.beforeLogout { }
        val accepted = fence.publishIfCurrent(stale) {
            published = true
            true
        }

        assertFalse(accepted)
        assertFalse(published)
        assertTrue(fence.isRaised)
    }

    @Test
    fun `same-email stale auth request cannot lower the newer attempt`() {
        val email = "owner@example.com"
        val oldRequest = EngineState.authRequestId(email, "old-password")
        val newRequest = EngineState.authRequestId(email, "new-password")
        val staleOutcome = EngineState.parseAuthAttemptOutcome(
            """{"name":"CoreEvent","args":{"event":"UserAuthenticated","args":{"auth_request":{"type":"Login","email":"$email","password":"old-password","facebook":false}}}}""",
        )
        assertEquals(oldRequest, staleOutcome?.requestId)
        assertFalse(staleOutcome?.requestId == newRequest)
        val fence = HomePrivacyFence()
        val staleAttempt = fence.beginSignIn(oldRequest)
        val staleTicket = fence.previewTicket(1)
        val currentAttempt = fence.beginSignIn(newRequest, nextPreviewEventSequence = 2)

        fence.noteContinueWatchingRefresh(staleTicket, "account-a")
        fence.completeSignIn(staleAttempt, "account-a")
        assertTrue(fence.isRaised)

        fence.noteContinueWatchingRefresh(fence.previewTicket(2), "account-a")
        fence.completeSignIn(currentAttempt, "account-a")
        assertFalse(fence.isRaised)
    }

    @Test
    fun `valid account buckets do not authorize a uid-less stale preview`() {
        val dir = Files.createTempDirectory("vortx-home-preview-owner").toFile()
        try {
            dir.resolve("library.json").writeText("""{"uid":"account-a","items":{}}""")
            dir.resolve("library_recent.json").writeText("""{"uid":"account-a","items":{}}""")
            assertTrue(WatchedIndex.storageMatchesUid(dir, "account-a"))
            val fence = HomePrivacyFence()
            val attempt = fence.beginSignIn("request-a")

            // This mirrors production's bucket gate. No current preview event was observed.
            fence.completeSignIn(attempt, "account-a")

            val permit = fence.capture()
            assertFalse(permit.suppressAccountHistory)
            assertTrue(permit.suppressContinueWatchingPreview)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `current account preview event establishes uid-less preview ownership after sign-in`() {
        val fence = HomePrivacyFence()
        val attempt = fence.beginSignIn("request-a")
        fence.completeSignIn(attempt, "account-a")
        val eventTicket = fence.previewTicket(1)

        assertTrue(fence.noteContinueWatchingRefresh(eventTicket, "account-a"))
        assertFalse(fence.capture().suppressContinueWatchingPreview)
    }

    @Test
    fun `profile switch invalidates old permit even when both profiles share one account`() {
        val profileA = HomeProfileIdentity("profile-a", usesEngineHistory = true, accountKey = "primary")
        val profileB = HomeProfileIdentity("profile-b", usesEngineHistory = false, accountKey = "primary")
        val fence = HomePrivacyFence(initiallySuppressed = false, initialProfile = profileA)
        val stale = fence.capture()

        assertTrue(fence.switchProfile(profileB, nextPreviewEventSequence = 4))
        assertFalse(fence.isCurrent(stale))
        assertEquals(profileB, fence.capture().profile)
        assertFalse(fence.switchProfile(profileB, nextPreviewEventSequence = 5))
    }

    @Test
    fun `own account profile switch raises history fence until matching sign in completes`() {
        val primary = HomeProfileIdentity(
            profileId = "primary-profile",
            usesEngineHistory = true,
            accountKey = "primary",
        )
        val own = HomeProfileIdentity(
            profileId = "own-profile",
            usesEngineHistory = true,
            accountKey = "primary.own-profile",
            expectedPrincipal = "own@example.com",
        )
        val fence = HomePrivacyFence(initiallySuppressed = false, initialProfile = primary)

        assertTrue(fence.switchProfile(own, nextPreviewEventSequence = 7))
        assertTrue(fence.capture().suppressAccountHistory)
        assertTrue(fence.capture().suppressContinueWatchingPreview)
    }

    @Test
    fun `preview callback captured before transition cannot acquire the new generation`() {
        val fence = HomePrivacyFence(initiallySuppressed = true)
        val first = fence.beginSignIn("request-a", nextPreviewEventSequence = 1)
        val preTransitionTicket = fence.previewTicket(1)
        val replacement = fence.beginSignIn("request-b", nextPreviewEventSequence = 2)

        assertFalse(fence.noteContinueWatchingRefresh(preTransitionTicket, "account-a"))
        fence.completeSignIn(first, "account-a")
        assertTrue(fence.isRaised)

        assertFalse(fence.noteContinueWatchingRefresh(fence.previewTicket(2), "account-b"))
        fence.completeSignIn(replacement, "account-b")
        assertFalse(fence.isRaised)
    }

    @Test
    fun `identical credential retry cannot start until the native predecessor settles`() = runBlocking {
        val coordinator = AuthAttemptCoordinator()
        val request = EngineState.authRequestId("owner@example.com", "same-password")
        val predecessor = requireNotNull(coordinator.begin(request))

        assertNull(coordinator.begin(request))
        assertTrue(coordinator.complete(AuthAttemptOutcome.Succeeded(request)))
        assertEquals(AuthAttemptOutcome.Succeeded(request), predecessor.outcome.await())

        val retry = requireNotNull(coordinator.begin(request))
        assertTrue(retry.id > predecessor.id)
    }

    @Test
    fun `late different-request response cannot complete replacement attempt`() {
        val coordinator = AuthAttemptCoordinator()
        val oldRequest = EngineState.authRequestId("owner@example.com", "old-password")
        val newRequest = EngineState.authRequestId("owner@example.com", "new-password")
        requireNotNull(coordinator.begin(oldRequest))
        val replacement = requireNotNull(coordinator.begin(newRequest))

        assertFalse(coordinator.complete(AuthAttemptOutcome.Succeeded(oldRequest)))
        assertFalse(replacement.outcome.isCompleted)
        assertTrue(coordinator.complete(AuthAttemptOutcome.Succeeded(newRequest)))
    }

    @Test
    fun `timed out dispatched attempt quarantines identical retry and consumes stale terminal`() {
        val coordinator = AuthAttemptCoordinator()
        val request = EngineState.authRequestId("owner@example.com", "password")
        val timedOut = requireNotNull(coordinator.begin(request))

        assertTrue(coordinator.abandon(timedOut))
        assertNull(coordinator.begin(request))
        assertFalse(coordinator.complete(AuthAttemptOutcome.Succeeded(request)))

        val retry = requireNotNull(coordinator.begin(request))
        assertTrue(coordinator.complete(AuthAttemptOutcome.Succeeded(request)))
        assertTrue(retry.outcome.isCompleted)
    }

    @Test
    fun `dispatch failure releases exact attempt without creating stale terminal debt`() {
        val coordinator = AuthAttemptCoordinator()
        val request = EngineState.authRequestId("owner@example.com", "password")
        val failedDispatch = requireNotNull(coordinator.begin(request))

        assertTrue(coordinator.releaseBeforeDispatch(failedDispatch))
        assertTrue(coordinator.begin(request) != null)
    }

    @Test
    fun `native error settles only the matching active attempt`() = runBlocking {
        val coordinator = AuthAttemptCoordinator()
        val request = EngineState.authRequestId("owner@example.com", "bad-password")
        val lease = requireNotNull(coordinator.begin(request))
        val error = AuthAttemptOutcome.Failed(request, "Bad password")

        assertTrue(coordinator.complete(error))
        assertEquals(error, lease.outcome.await())
        assertFalse(coordinator.complete(error))
    }

    @Test
    fun `explicit sign out retires active attempt before its late terminal`() {
        val coordinator = AuthAttemptCoordinator()
        val request = EngineState.authRequestId("owner@example.com", "password")
        requireNotNull(coordinator.begin(request))

        assertTrue(coordinator.abandonActive())
        assertNull(coordinator.begin(request))
        assertFalse(coordinator.complete(AuthAttemptOutcome.Failed(request, "late error")))
        assertTrue(coordinator.begin(request) != null)
    }

    @Test
    fun `uid-less restored sign-in remains fail closed`() {
        val fence = HomePrivacyFence()

        fence.establishFreshEngineState(
            isSignedIn = true,
            signedInUid = null,
            accountUidVerified = false,
        )

        assertTrue(fence.capture().suppressAccountHistory)
        assertTrue(fence.capture().suppressContinueWatchingPreview)
    }

    @Test
    fun `auth parser accepts only attempt-bound login results`() {
        val requestId = EngineState.authRequestId("owner@example.com", "secret")
        val success = EngineState.parseAuthAttemptOutcome(
            """{"name":"CoreEvent","args":{"event":"UserAuthenticated","args":{"auth_request":{"type":"Login","email":"owner@example.com","password":"secret","facebook":false}}}}""",
        )
        assertEquals(AuthAttemptOutcome.Succeeded(requestId), success)

        val failure = EngineState.parseAuthAttemptOutcome(
            """{"name":"CoreEvent","args":{"event":"Error","args":{"error":{"message":"Bad password"},"source":{"event":"UserAuthenticated","args":{"auth_request":{"type":"Login","email":"owner@example.com","password":"secret","facebook":false}}}}}}""",
        )
        assertEquals(AuthAttemptOutcome.Failed(requestId, "Bad password"), failure)

        assertNull(
            EngineState.parseAuthAttemptOutcome(
                """{"name":"CoreEvent","args":{"event":"UserLibraryMissing","args":{"library_missing":false}}}""",
            ),
        )
        assertNull(
            EngineState.parseAuthAttemptOutcome(
                """{"name":"CoreEvent","args":{"event":"UserAuthenticated","args":{"auth_request":{"type":"Facebook","token":"unrelated"}}}}""",
            ),
        )
    }

    @Test
    fun `result wrapper rethrows coroutine cancellation`() = runBlocking {
        var cancellationObserved = false
        try {
            runCatchingPreservingCancellation<Unit> {
                throw CancellationException("cancelled")
            }
        } catch (_: CancellationException) {
            cancellationObserved = true
        }

        assertTrue(cancellationObserved)
    }
}
