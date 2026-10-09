package com.vortx.android.player

import com.vortx.android.data.PlayerResourceReleaseGate
import com.vortx.android.model.Playable
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class PlayerEngineBuildOwnerTest {
    @Test fun `Back during native construction releases the late decoder and connecting lease exactly once`() = runBlocking {
        val gate = PlayerResourceReleaseGate()
        val reclaimed = AtomicInteger()
        gate.registerReleaseCallback("source") { reclaimed.incrementAndGet() }
        val decoder = RecordingEngine()
        val owner = PlayerEngineBuildOwner(gate::decoderBound, gate::decoderReleased)
        val leaseCloses = AtomicInteger()
        val lease = PlayerPlaybackLeaseOwner(AutoCloseable { leaseCloses.incrementAndGet() }, gate::leaseBound, gate::leaseReleased)
        val entered = CompletableDeferred<Unit>()
        val finish = CountDownLatch(1)
        var prepared = false
        var published = false
        var fallback = false
        val job = launch {
            owner.build(
                createBackground = { entered.complete(Unit); await(finish); decoder },
                createForeground = { fallback = true; RecordingEngine() },
                prepare = { prepared = true },
            )?.let { published = true }
        }
        try {
            entered.await()
            job.cancel()
            owner.close()
            lease.close()
            gate.sessionDisposed()
            assertEquals(1, leaseCloses.get())
            assertEquals(0, decoder.releases.get())
            assertEquals("pending constructor still owns resources", 0, reclaimed.get())
        } finally { finish.countDown() }
        job.join() // Actual NonCancellable withContext return takes its prompt-cancellation path.
        owner.close()
        lease.close()
        assertTrue(job.isCancelled)
        assertFalse(prepared)
        assertFalse(published)
        assertFalse(fallback)
        assertEquals(1, decoder.releases.get())
        assertEquals(1, reclaimed.get())
        Unit
    }

    @Test fun `dispose during preparation cannot release a decoder in use or steal successor commands`() = runBlocking {
        val intent = PlaybackIntentController()
        val old = RecordingEngine()
        val successor = RecordingEngine()
        val releases = AtomicInteger()
        val owner = PlayerEngineBuildOwner({}, { releases.incrementAndGet() }, intent::unbindIfCurrent)
        val preparing = CompletableDeferred<Unit>()
        val finish = CountDownLatch(1)
        var published = false
        val job = launch {
            owner.build({ old }, { error("unexpected fallback") }, {
                prepareAndLoadEngine(it, playable, {
                    val sampledBeforeStop = true
                    preparing.complete(Unit)
                    await(finish)
                    sampledBeforeStop
                }, { true }, intent, bindForCommands = false)
            })?.let { published = true }
        }
        var successorActionsAtStop = emptyList<String>()
        try {
            preparing.await()
            owner.close()
            job.cancel()
            intent.bind(successor)
            intent.setBlocked(PlaybackBlocker.BACKGROUND, true)
            successorActionsAtStop = successor.actions.toList()
            assertEquals(0, old.releases.get())
        } finally { finish.countDown() }
        job.join()
        assertTrue("retired preparation cannot clear the live background blocker",
            PlaybackBlocker.BACKGROUND in intent.snapshot().blockers)
        assertEquals("retired preparation cannot command the live engine from its worker",
            successorActionsAtStop, successor.actions.toList())
        val oldActionsAfterRelease = old.actions.toList()
        intent.setBlocked(PlaybackBlocker.BACKGROUND, false)
        intent.userPlay()
        intent.userPause()
        assertEquals(listOf("play", "pause"), successor.actions.takeLast(2))
        assertEquals(oldActionsAfterRelease, old.actions.toList())
        assertEquals(1, old.releases.get())
        assertEquals(1, releases.get())
        assertFalse(published)
        Unit
    }

    @Test fun `retirement without coroutine cancellation still rejects late constructor publication`() = runBlocking {
        val decoder = RecordingEngine()
        val entered = CompletableDeferred<Unit>()
        val finish = CountDownLatch(1)
        val released = AtomicInteger()
        val owner = PlayerEngineBuildOwner({}, { released.incrementAndGet() })
        var result: PlayerEngine? = decoder
        var prepared = false
        val job = launch {
            result = owner.build({ entered.complete(Unit); await(finish); decoder },
                { error("unexpected fallback") }, { prepared = true })
        }
        try { entered.await(); owner.close() } finally { finish.countDown() }
        job.join()
        assertNull(result)
        assertFalse(prepared)
        assertEquals(1, released.get())
        assertEquals(1, decoder.releases.get())
        Unit
    }

    @Test fun `preparation failure releases its candidate and cannot transfer ownership`() = runBlocking {
        val decoder = RecordingEngine()
        val bound = AtomicInteger()
        val released = AtomicInteger()
        val owner = PlayerEngineBuildOwner({ bound.incrementAndGet() }, { released.incrementAndGet() })
        try {
            owner.build({ decoder }, { error("must not fallback after load error") }, { error("load failed") })
            fail("expected load error")
        } catch (expected: IllegalStateException) { assertEquals("load failed", expected.message) }
        owner.close()
        assertNull(owner.get())
        assertEquals(1, bound.get())
        assertEquals(1, released.get())
        assertEquals(1, decoder.releases.get())
        Unit
    }

    @Test fun `unavailable MPV preserves caller-thread fallback and only publication binds commands`() = runBlocking {
        val callerThread = Thread.currentThread()
        val intent = PlaybackIntentController()
        intent.userPause()
        val decoder = RecordingEngine()
        val released = AtomicInteger()
        val owner = PlayerEngineBuildOwner({}, { released.incrementAndGet() }, intent::unbindIfCurrent)
        var createThread: Thread? = null
        var prepareThread: Thread? = null
        val built = owner.build({ null }, { createThread = Thread.currentThread(); decoder }, {
            prepareThread = Thread.currentThread()
            prepareAndLoadEngine(it, playable, { true }, { true }, intent, bindForCommands = false)
        })
        assertSame(callerThread, createThread)
        assertSame(callerThread, prepareThread)
        assertSame(decoder, built)
        val beforePublication = decoder.actions.toList()
        intent.userPlay()
        assertEquals(beforePublication, decoder.actions.toList())
        reconcileAndPublishEngine(requireNotNull(built), { true }, { true }, intent, publish = {})
        intent.userPause()
        assertEquals(listOf("play", "pause"), decoder.actions.takeLast(2))
        owner.close()
        owner.close()
        val afterRelease = decoder.actions.toList()
        intent.userPlay()
        assertEquals(afterRelease, decoder.actions.toList())
        assertEquals(1, decoder.releases.get())
        assertEquals(1, released.get())
        Unit
    }

    @Test fun `closed owner never begins a constructor or binds a release obligation`() = runBlocking {
        val owner = PlayerEngineBuildOwner({ error("must not bind") }, { error("must not release") })
        owner.close()
        assertNull(owner.build({ error("must not create") }, { error("must not fallback") }, { error("must not load") }))
        Unit
    }

    @Test fun `foreground constructor failure settles pending obligation without a fake decoder`() = runBlocking {
        val released = AtomicInteger()
        val owner = PlayerEngineBuildOwner({}, { released.incrementAndGet() })
        try {
            owner.build(null, { error("construction failed") }, { error("must not load") })
            fail("expected construction error")
        } catch (expected: IllegalStateException) { assertEquals("construction failed", expected.message) }
        owner.close()
        assertEquals(1, released.get())
        Unit
    }

    @Test fun `failed decoder release never acknowledges resource reclamation`() = runBlocking {
        val decoder = RecordingEngine(failRelease = true)
        val released = AtomicInteger()
        val owner = PlayerEngineBuildOwner({}, { released.incrementAndGet() })
        owner.build(null, { decoder }, {})
        try { owner.close(); fail("expected release failure") } catch (_: IllegalStateException) { }
        assertEquals(0, released.get())
        assertEquals(1, decoder.releases.get())
        owner.close()
        assertEquals(1, decoder.releases.get())
        Unit
    }

    @Test fun `connecting lease release is counted only for a real successfully closed lease`() {
        val bound = AtomicInteger()
        val released = AtomicInteger()
        PlayerPlaybackLeaseOwner(null, { bound.incrementAndGet() }, { released.incrementAndGet() }).close()
        assertEquals(0, bound.get())
        assertEquals(0, released.get())
        val failing = PlayerPlaybackLeaseOwner(AutoCloseable { error("close failed") },
            { bound.incrementAndGet() }, { released.incrementAndGet() })
        try { failing.close(); fail("expected close failure") } catch (_: IllegalStateException) { }
        assertEquals(1, bound.get())
        assertEquals(0, released.get())
    }

    private fun await(latch: CountDownLatch) {
        check(latch.await(5, TimeUnit.SECONDS)) { "test construction barrier timed out" }
    }

    private val playable = Playable("https://example.invalid/video.mkv", "Video")

    private class RecordingEngine(private val failRelease: Boolean = false) : PlayerEngine {
        override val state = kotlinx.coroutines.flow.MutableStateFlow(PlayerState())
        val actions: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val releases = AtomicInteger()
        override fun load(playable: Playable) { actions += "load" }
        override fun play() { actions += "play" }
        override fun pause() { actions += "pause" }
        override fun togglePause() = Unit
        override fun seekTo(positionMs: Long) = Unit
        override fun setPlaybackSpeed(speed: Float) = Unit
        override fun selectAudioTrack(id: Int) = Unit
        override fun selectSubtitleTrack(id: Int?) = Unit
        override fun addExternalSubtitle(url: String) = Unit
        override fun setSubtitleDelay(seconds: Double) = Unit
        override fun onEnterBackground() = Unit
        override fun onEnterForeground() = Unit
        override fun release() { releases.incrementAndGet(); actions += "release"; check(!failRelease) }
        @androidx.compose.runtime.Composable
        override fun VideoSurface(modifier: androidx.compose.ui.Modifier, emberArgb: Int, scaleMode: VideoScaleMode) = Unit
    }
}
