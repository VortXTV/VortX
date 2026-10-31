package com.vortx.android.moat

import com.vortx.android.singularity.SourceIndexLifecycle
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MoatSourceEpochTest {
    private val credential = MoatToken.SessionCredential("fixture-bearer-a", "fixture-account")
    private val now = 1_000L
    private fun minted(value: String) = MoatToken.Minted(value, now + 120_000L)

    @Test fun credentialAndMintedDescriptionsDoNotExposeTheirValues() {
        val account = MoatToken.SessionCredential("private-fixture-bearer", "private-fixture-account")
        val token = MoatToken.Minted("private-fixture-token", 123_456L)
        val descriptions = listOf(account.toString(), token.toString()).joinToString()
        for (privateValue in listOf(account.bearer, account.accountId, token.token)) {
            assertFalse(descriptions.contains(privateValue))
        }
    }

    private fun cache(
        scope: CoroutineScope,
        credentials: () -> MoatToken.SessionCredential? = { credential },
        permitted: () -> Boolean = { true },
        mint: suspend (String, MoatMintCancellation) -> MoatToken.Minted?,
    // Preserve the test's parent Job and drain mint completions immediately when their fixture latch opens.
    // The assertions after release therefore observe the retired flight's final acceptance attempt.
    ) = MoatSourceEpochCache(credentials, permitted, mint,
        CoroutineScope(scope.coroutineContext + Dispatchers.Unconfined), nowMs = { now })

    @Test fun sameCredentialEpochReentryRejectsNoncooperativeOldMintAndDisconnectsIt() = runBlocking { withTimeout(5_000) {
        SourceIndexLifecycle.invalidate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val disconnected = AtomicInteger()
        val mints = AtomicInteger()
        val cache = cache(this) { _, cancellation ->
            if (mints.incrementAndGet() == 1) {
                cancellation.onCancelled { disconnected.incrementAndGet() }
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
                minted("retired")
            } else minted("reopened")
        }
        try {
            val old = async(start = CoroutineStart.UNDISPATCHED) { cache.current() }
            entered.await()
            SourceIndexLifecycle.invalidate()
            assertEquals(1, disconnected.get())
            assertEquals("reopened", cache.current())
            release.complete(Unit)
            assertNull(old.await())
            assertEquals("reopened", cache.current())
            assertEquals(2, mints.get())
        } finally { release.complete(Unit); cache.clear() }
    } }

    @Test fun delayedOldEpochClearDoesNotEraseReopenedCachedToken() = runBlocking { withTimeout(5_000) {
        SourceIndexLifecycle.invalidate()
        val oldEpoch = SourceIndexLifecycle.currentEpoch()
        val mints = AtomicInteger()
        val cache = cache(this) { _, _ -> minted("token-${mints.incrementAndGet()}") }
        try {
            assertEquals("token-1", cache.current())
            SourceIndexLifecycle.invalidate()
            assertEquals("token-2", cache.current())
            cache.clearThrough(oldEpoch)
            assertEquals("token-2", cache.current())
            assertEquals(2, mints.get())
        } finally { cache.clear() }
    } }

    @Test fun retiredCredentialMintCannotClearOrReplaceNewerInFlightOwner() = runBlocking { withTimeout(5_000) {
        SourceIndexLifecycle.invalidate()
        var live = credential
        val firstEntered = CompletableDeferred<Unit>()
        val secondEntered = CompletableDeferred<Unit>()
        val firstRelease = CompletableDeferred<Unit>()
        val secondRelease = CompletableDeferred<Unit>()
        val mints = AtomicInteger()
        val cache = cache(this, credentials = { live }) { bearer, _ ->
            mints.incrementAndGet()
            withContext(NonCancellable) {
                if (bearer == credential.bearer) { firstEntered.complete(Unit); firstRelease.await(); minted("old") }
                else { secondEntered.complete(Unit); secondRelease.await(); minted("new") }
            }
        }
        try {
            val first = async(start = CoroutineStart.UNDISPATCHED) { cache.current() }
            firstEntered.await()
            live = credential.copy(bearer = "fixture-bearer-b")
            val second = async(start = CoroutineStart.UNDISPATCHED) { cache.current() }
            secondEntered.await()
            firstRelease.complete(Unit)
            assertNull(first.await())
            val joined = async(start = CoroutineStart.UNDISPATCHED) { cache.current() }
            secondRelease.complete(Unit)
            assertEquals("new", second.await())
            assertEquals("new", joined.await())
            assertEquals("new", cache.current())
            assertEquals(2, mints.get())
        } finally { firstRelease.complete(Unit); secondRelease.complete(Unit); cache.clear() }
    } }

    @Test fun concurrentCurrentCallsShareOneProductionCacheFlight() = runBlocking { withTimeout(5_000) {
        SourceIndexLifecycle.invalidate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val mints = AtomicInteger()
        val cache = cache(this) { _, _ ->
            mints.incrementAndGet(); entered.complete(Unit); release.await(); minted("shared")
        }
        try {
            val first = async(start = CoroutineStart.UNDISPATCHED) { cache.current() }
            entered.await()
            val second = async(start = CoroutineStart.UNDISPATCHED) { cache.current() }
            release.complete(Unit)
            assertEquals("shared", first.await())
            assertEquals("shared", second.await())
            assertEquals(1, mints.get())
        } finally { release.complete(Unit); cache.clear() }
    } }

    @Test fun missingCredentialAndWithdrawnConsentNeverStartMint() = runBlocking { withTimeout(5_000) {
        SourceIndexLifecycle.invalidate()
        var live: MoatToken.SessionCredential? = null
        var consent = true
        val mints = AtomicInteger()
        val cache = cache(this, credentials = { live }, permitted = { consent }) { _, _ ->
            mints.incrementAndGet(); minted("allowed")
        }
        try {
            assertNull(cache.current())
            live = credential
            consent = false
            assertNull(cache.current())
            assertEquals(0, mints.get())
            consent = true
            assertEquals("allowed", cache.current())
            assertEquals(1, mints.get())
        } finally { cache.clear() }
    } }

    @Test fun consentWithdrawalAtMintCompletionRejectsTheTokenEvenBeforeNotification() = runBlocking { withTimeout(5_000) {
        SourceIndexLifecycle.invalidate()
        var consent = true
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val cache = cache(this, permitted = { consent }) { _, _ ->
            entered.complete(Unit); release.await(); minted("must-not-publish")
        }
        try {
            val pending = async(start = CoroutineStart.UNDISPATCHED) { cache.current() }
            entered.await()
            consent = false
            release.complete(Unit)
            assertNull(pending.await())
            assertNull(cache.current())
        } finally { release.complete(Unit); cache.clear() }
    } }

    @Test fun cancellationLatchRemembersRevocationBeforeConnectionRegistration() {
        val cancellation = MoatMintCancellation()
        val disconnected = AtomicInteger()
        cancellation.cancel()
        val registration = cancellation.onCancelled {
            assertTrue(cancellation.isCancelled())
            disconnected.incrementAndGet()
        }
        cancellation.cancel()
        registration.close()
        assertEquals(1, disconnected.get())
    }

    @Test fun transportCancellationIsImmediateAndDisconnectNeverBlocksTheCancellingThread() = runBlocking { withTimeout(5_000) {
        val cancellation = MoatMintCancellation()
        val cancellingThread = Thread.currentThread()
        val continuationCancelled = AtomicBoolean(false)
        val continuationThread = AtomicReference<Thread?>()
        val disconnectEntered = CompletableDeferred<Thread>()
        val disconnectFinished = CompletableDeferred<Unit>()
        val releaseDisconnect = CountDownLatch(1)
        val registration = cancellation.onTransportCancelled(
            cancelContinuation = {
                continuationThread.set(Thread.currentThread())
                continuationCancelled.set(true)
            },
            disconnect = {
                disconnectEntered.complete(Thread.currentThread())
                try { check(releaseDisconnect.await(2, TimeUnit.SECONDS)) { "Fixture disconnect release timed out" } }
                finally { disconnectFinished.complete(Unit) }
            },
        )
        try {
            cancellation.cancel()
            assertTrue(continuationCancelled.get())
            assertTrue(continuationThread.get() === cancellingThread)
            assertFalse(disconnectEntered.await() === cancellingThread)
            assertEquals(1L, releaseDisconnect.count)
            assertFalse(disconnectFinished.isCompleted)
        } finally {
            releaseDisconnect.countDown()
            try { withContext(NonCancellable) { withTimeout(5_000) { disconnectFinished.await() } } }
            finally { registration.close() }
        }
    } }
}
