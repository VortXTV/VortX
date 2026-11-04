package com.vortx.android.moat

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.sync.RevisionContext
import com.vortx.android.sync.withIsolatedPristinePreferenceFence
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.ArrayDeque
import kotlin.coroutines.CoroutineContext

class WatchSignalEnqueueConsentTest {
    @Test fun optedOutPlaybackNeverEnqueuesEvenIfConsentReturnsBeforeTheWorkerRuns() = isolated { fixture ->
        fixture.setConsent(false)
        assertFalse(fixture.enqueue())
        assertEquals(0, fixture.dispatcher.pending)
        assertEquals(1, fixture.consentReads)

        fixture.setConsent(true)
        fixture.dispatcher.runAll()
        assertEquals(1, fixture.consentReads)
        assertFalse(fixture.prefs.contains("stremiox.watchSignalSent"))
    }

    @Test fun optedInPlaybackStillChecksLiveConsentAfterTheWorkerStarts() = isolated { fixture ->
        fixture.setConsent(true)
        assertTrue(fixture.enqueue())
        assertEquals(1, fixture.dispatcher.pending)
        assertEquals(1, fixture.consentReads)

        fixture.setConsent(false)
        fixture.dispatcher.runAll()
        assertEquals(2, fixture.consentReads)
        assertFalse(fixture.prefs.contains("stremiox.watchSignalSent"))
    }

    private fun isolated(test: (Fixture) -> Unit) = withIsolatedPristinePreferenceFence {
        Fixture().use(test)
    }

    private class Fixture : AutoCloseable {
        val dispatcher = PausedDispatcher()
        private val parent = Job()
        private val worker = CoroutineScope(parent + dispatcher)
        val prefs = RevisionContext().getSharedPreferences("vortx_settings", Context.MODE_PRIVATE)
        var consentReads = 0
            private set
        private val context = object : ContextWrapper(null) {
            override fun getApplicationContext(): Context = this

            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                check(name == "vortx_settings")
                consentReads++
                return prefs
            }
        }

        fun setConsent(consent: Boolean) {
            prefs.edit().putBoolean(MoatConsent.KEY, consent).commit()
        }

        // Recognized as a TMDB input by the public enqueue path, but with no numeric ID or
        // resolver backing. Even a regression in either consent check cannot make a request.
        fun enqueue() = WatchSignalClient.enqueueWatchSignal(context, "tmdb:consent-fixture", "movie", false, worker)

        override fun close() {
            parent.cancel()
            dispatcher.runAll()
        }
    }

    private class PausedDispatcher : CoroutineDispatcher() {
        private val work = ArrayDeque<Runnable>()
        val pending: Int get() = work.size

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            work.addLast(block)
        }

        fun runAll() {
            while (work.isNotEmpty()) work.removeFirst().run()
        }
    }
}
