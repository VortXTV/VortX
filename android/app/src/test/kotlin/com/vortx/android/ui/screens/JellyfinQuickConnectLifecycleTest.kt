package com.vortx.android.ui.screens

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class JellyfinQuickConnectLifecycleTest {

    @Test
    fun `password fallback cancels poll and suppresses every stale callback`() = runBlocking {
        val enteredPoll = CompletableDeferred<Unit>()
        val pollStopped = CompletableDeferred<Unit>()
        var succeeded = false
        var failed = false

        val lifecycle = JellyfinQuickConnectLifecycle(this)
        lifecycle.start(
            await = {
                enteredPoll.complete(Unit)
                try {
                    awaitCancellation()
                } finally {
                    pollStopped.complete(Unit)
                }
            },
            onSuccess = { succeeded = true },
            onFailure = { failed = true },
        )

        enteredPoll.await()
        assertTrue(lifecycle.isPolling)

        lifecycle.cancel()
        pollStopped.await()

        assertFalse(lifecycle.isPolling)
        assertFalse(succeeded)
        assertFalse(failed)
    }

    @Test
    fun `starting a replacement invalidates the previous poll`() = runBlocking {
        val firstEntered = CompletableDeferred<Unit>()
        val firstStopped = CompletableDeferred<Unit>()
        val secondResult = CompletableDeferred<String>()
        var firstSucceeded = false
        var secondSucceeded = false

        val lifecycle = JellyfinQuickConnectLifecycle(this)
        lifecycle.start(
            await = {
                firstEntered.complete(Unit)
                try {
                    awaitCancellation()
                } finally {
                    firstStopped.complete(Unit)
                }
            },
            onSuccess = { firstSucceeded = true },
            onFailure = {},
        )
        firstEntered.await()

        lifecycle.start(
            await = { secondResult.await() },
            onSuccess = { secondSucceeded = true },
            onFailure = {},
        )
        firstStopped.await()
        secondResult.complete("connected")
        while (lifecycle.isPolling) kotlinx.coroutines.yield()

        assertFalse(firstSucceeded)
        assertTrue(secondSucceeded)
    }
}
