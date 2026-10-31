package com.vortx.android.singularity

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Contract tests for the internal Android availability capability.
 *
 * These tests deliberately issue only synthetic predicates and moat providers. They do not stand in for
 * the App's typed vault/account admission; that wiring belongs to the production integration owner.
 */
class SourceIndexAuthorizationTest {
    @Test
    fun `deferred invalidation fences immediately and delivers cancellation off the calling thread`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "moat" }),
        )
        val caller = Thread.currentThread()
        val callback = CompletableDeferred<Boolean>()
        authorization.onRevoked { callback.complete(Thread.currentThread() !== caller) }
        SourceIndexLifecycle.invalidateDeferred()
        assertFalse(authorization.isCurrent())
        try {
            assertTrue(withTimeout(HANDSHAKE_TIMEOUT_MS) { callback.await() })
        } finally {
            authorization.close()
        }
    }

    @Test
    fun `caller cancellation causally retires the lease before its private IO callback`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "moat" }),
        )
        val entered = CompletableDeferred<Unit>()
        val sawInactiveContext = CompletableDeferred<Boolean>()
        val callback = CompletableDeferred<Unit>()
        authorization.onRevoked { callback.complete(Unit) }

        val caller = async(start = CoroutineStart.UNDISPATCHED) {
            entered.complete(Unit)
            try {
                awaitCancellation()
            } finally {
                sawInactiveContext.complete(!currentCoroutineContext().isActive)
                authorization.closeDeferred()
            }
        }
        try {
            withTimeout(HANDSHAKE_TIMEOUT_MS) { entered.await() }
            caller.cancel()
            withTimeout(HANDSHAKE_TIMEOUT_MS) { caller.join() }

            // The cancellation handler ran in the cancelled caller, before the callback was dispatched.
            assertTrue(withTimeout(HANDSHAKE_TIMEOUT_MS) { sawInactiveContext.await() })
            assertTrue(authorization.isRetired())
            withTimeout(HANDSHAKE_TIMEOUT_MS) { callback.await() }
            assertTrue(authorization.isRetired())
        } finally {
            caller.cancel()
            runCatching { withTimeout(HANDSHAKE_TIMEOUT_MS) { caller.join() } }
            authorization.close()
        }
    }

    @Test
    fun `closed predicate cannot issue a capability or invoke moat`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        var moatReads = 0

        val authorization = SourceIndexLifecycle.issue(
            isCurrent = { false },
            moatProvider = {
                moatReads += 1
                "must-not-be-read"
            },
        )

        assertNull(authorization)
        assertEquals(0, moatReads)
    }

    @Test
    fun `invalidate revokes once and supports reentrant callback registration`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "moat" }),
        )
        val revocations = AtomicInteger()
        val nestedRevocations = AtomicInteger()
        val callbackSawClosed = AtomicBoolean(false)
        val nestedFinished = CompletableDeferred<Unit>()

        val registration = authorization.onRevoked {
            revocations.incrementAndGet()
            // Calling back through the same capability must not deadlock on its callback map lock. A callback
            // registered after close is dispatched asynchronously and exactly once.
            callbackSawClosed.set(!authorization.isCurrent())
            authorization.onRevoked {
                nestedRevocations.incrementAndGet()
                nestedFinished.complete(Unit)
            }.close()
        }

        SourceIndexLifecycle.invalidate()
        SourceIndexLifecycle.invalidate()

        assertFalse(authorization.isCurrent())
        assertEquals(1, revocations.get())
        withTimeout(HANDSHAKE_TIMEOUT_MS) { nestedFinished.await() }
        assertEquals(1, nestedRevocations.get())
        assertTrue(callbackSawClosed.get())
        registration.close()
        authorization.close()
    }

    @Test
    fun `closing one lease does not revoke a peer lease`() {
        SourceIndexLifecycle.invalidate()
        val first = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "first" }),
        )
        val second = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "second" }),
        )
        val firstRevocations = AtomicInteger()
        val secondRevocations = AtomicInteger()
        first.onRevoked { firstRevocations.incrementAndGet() }
        second.onRevoked { secondRevocations.incrementAndGet() }

        first.close()

        assertFalse(first.isCurrent())
        assertTrue(second.isCurrent())
        assertEquals(1, firstRevocations.get())
        assertEquals(0, secondRevocations.get())

        second.close()
        assertEquals(1, secondRevocations.get())
    }

    @Test
    fun `epoch replacement fences an old lease while a new lease can be issued`() {
        SourceIndexLifecycle.invalidate()
        val oldLease = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "old" }),
        )

        SourceIndexLifecycle.invalidate()

        val newLease = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "new" }),
        )
        assertFalse(oldLease.isCurrent())
        assertTrue(newLease.isCurrent())
        assertFalse(oldLease === newLease)

        oldLease.close()
        assertTrue(newLease.isCurrent())
        newLease.close()
    }

    @Test
    fun `gate write fences a lease issued between before and after invalidation`() {
        SourceIndexLifecycle.invalidate()
        val gateOpen = AtomicBoolean(true)
        val priorLease = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { gateOpen.get() }, moatProvider = { "prior" }),
        )

        // The pre-write boundary advances the epoch while the old gate fact is still true. A lease issued in
        // this narrow window must not survive the actual fact write plus the post-write boundary.
        SourceIndexLifecycle.invalidate()
        assertFalse(priorLease.isCurrent())
        val racedLease = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { gateOpen.get() }, moatProvider = { "raced" }),
        )
        val revocations = AtomicInteger()
        racedLease.onRevoked { revocations.incrementAndGet() }

        gateOpen.set(false)
        assertFalse(racedLease.isRetired())
        assertEquals(0, revocations.get())

        SourceIndexLifecycle.invalidate()
        assertTrue(racedLease.isRetired())
        assertEquals(1, revocations.get())

        gateOpen.set(true)
        assertTrue(racedLease.isRetired())
        val reopenedLease = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { gateOpen.get() }, moatProvider = { "reopened" }),
        )
        assertTrue(reopenedLease.isCurrent())

        priorLease.close()
        racedLease.close()
        reopenedLease.close()
    }

    @Test
    fun `a moat token resolved across revocation cannot return after the epoch closes`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val providerEntered = CompletableDeferred<Unit>()
        val releaseProvider = CompletableDeferred<Unit>()
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(
                isCurrent = { true },
                moatProvider = {
                    providerEntered.complete(Unit)
                    withTimeout(HANDSHAKE_TIMEOUT_MS) { releaseProvider.await() }
                    "stale-token"
                },
            ),
        )

        val pending = async { authorization.moatToken() }
        try {
            withTimeout(HANDSHAKE_TIMEOUT_MS) { providerEntered.await() }
            SourceIndexLifecycle.invalidate()
            releaseProvider.complete(Unit)

            assertNull(withTimeout(HANDSHAKE_TIMEOUT_MS) { pending.await() })
            assertFalse(authorization.isCurrent())
        } finally {
            releaseProvider.complete(Unit)
            pending.cancel()
            runCatching { withTimeout(HANDSHAKE_TIMEOUT_MS) { pending.join() } }
            authorization.close()
        }
    }

    @Test
    fun `blank moat is treated as unavailable before a transport caller can use it`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { "   " }),
        )

        assertNull(authorization.moatToken())
        authorization.close()
    }

    @Test
    fun `predicate closure retires the lease permanently and delivers its callback asynchronously`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val open = AtomicBoolean(true)
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(isCurrent = { open.get() }, moatProvider = { "moat" }),
        )
        val callbackCount = AtomicInteger()
        val callbackFinished = CompletableDeferred<Unit>()
        authorization.onRevoked {
            callbackCount.incrementAndGet()
            callbackFinished.complete(Unit)
        }

        open.set(false)
        assertFalse(authorization.isCurrent())
        assertTrue(authorization.isRetired())

        // The failed live predicate retires the capability synchronously; reopening the fact cannot revive it.
        open.set(true)
        assertFalse(authorization.isCurrent())
        assertTrue(authorization.isRetired())
        withTimeout(HANDSHAKE_TIMEOUT_MS) { callbackFinished.await() }
        assertEquals(1, callbackCount.get())
        authorization.close()
    }

    @Test
    fun `isRetired is a scalar witness and does not re-read the live predicate`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val predicateCalls = AtomicInteger()
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(
                isCurrent = {
                    predicateCalls.incrementAndGet()
                    true
                },
                moatProvider = { "moat" },
            ),
        )
        assertEquals(1, predicateCalls.get())
        repeat(3) { assertFalse(authorization.isRetired()) }
        assertEquals(1, predicateCalls.get())

        val callbackStarted = CompletableDeferred<Unit>()
        val callbackFinished = CompletableDeferred<Unit>()
        val releaseCallback = CountDownLatch(1)
        val registration = authorization.onRevoked {
            callbackStarted.complete(Unit)
            try {
                releaseCallback.await(HANDSHAKE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            } finally {
                callbackFinished.complete(Unit)
            }
        }
        try {
            // Registration performs its one live check; scalar retirement must not perform another one.
            assertEquals(2, predicateCalls.get())
            authorization.closeDeferred()
            assertTrue(authorization.isRetired())
            repeat(3) { assertTrue(authorization.isRetired()) }
            assertEquals(2, predicateCalls.get())
            withTimeout(HANDSHAKE_TIMEOUT_MS) { callbackStarted.await() }
            assertTrue(authorization.isRetired())
            assertEquals(2, predicateCalls.get())
        } finally {
            releaseCallback.countDown()
            runCatching { withTimeout(HANDSHAKE_TIMEOUT_MS) { callbackFinished.await() } }
            registration.close()
            authorization.close()
        }
    }

    private companion object {
        const val HANDSHAKE_TIMEOUT_MS = 5_000L
        const val HANDSHAKE_TIMEOUT_SECONDS = 5L
    }
}
