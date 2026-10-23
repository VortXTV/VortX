package com.vortx.android.ui.profilepicker

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfilePickerPresentationTest {

    @Test
    fun `populated rows are centered without phantom empty tracks`() {
        val layout = ProfilePickerLayoutPolicy(widthDp = 1440f, largeText = false)
        assertEquals(6, layout.columns)
        assertEquals(listOf(0..5, 6..7), layout.rows(8))
        assertEquals(emptyList<IntRange>(), layout.rows(0))

        val compact = ProfilePickerLayoutPolicy(widthDp = 393f, largeText = false, isPhone = true)
        assertEquals(3, compact.columns)
        assertEquals(listOf(0..2, 3..3), compact.rows(4))
        assertTrue(compact.avatarSideDp >= 44f)

        val compactTv = ProfilePickerLayoutPolicy(widthDp = 1280f, largeText = false, isTv = true)
        assertEquals(5, compactTv.columns)
        assertEquals(200f, compactTv.tileWidthDp)
        assertEquals(120f, compactTv.avatarSideDp)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `controller prewarms selected and next then rotates only through ready candidates`() = runTest {
        val loads = mutableListOf<String>()
        val candidates = listOf(
            ProfilePickerArtworkCandidate("bad", "Bad", listOf("bad")),
            ProfilePickerArtworkCandidate("one", "One", listOf("one")),
            ProfilePickerArtworkCandidate("two", "Two", listOf("two")),
        )
        val controller = ProfilePickerArtworkController(
            fetchCandidates = { candidates },
            loadArtwork = { url -> loads += url; url != "bad" },
            rotationIntervalMillis = 10,
        )

        val running = launch { controller.run(reducedMotion = false) }
        runCurrent()
        assertEquals("one", controller.movie.value?.id)
        assertTrue(loads.containsAll(listOf("bad", "one", "two")))
        advanceTimeBy(10)
        runCurrent()
        assertEquals("two", controller.movie.value?.id)
        running.cancel()
        running.join()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `cancellation does not negative-cache an in-flight candidate`() = runTest {
        var calls = 0
        val controller = ProfilePickerArtworkController(
            fetchCandidates = {
                listOf(ProfilePickerArtworkCandidate("one", "One", listOf("one")))
            },
            loadArtwork = {
                calls += 1
                throw CancellationException("picker disappeared")
            },
            rotationIntervalMillis = 10,
        )
        val running: Job = launch { controller.run(reducedMotion = true) }
        runCurrent()
        running.cancelAndJoin()
        assertTrue(controller.unavailableCandidateIDs().isEmpty())
        assertEquals(1, calls)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `one controller owns one catalog across reduced-motion restarts`() = runTest {
        var catalogCalls = 0
        var artworkCalls = 0
        val controller = ProfilePickerArtworkController(
            fetchCandidates = {
                catalogCalls += 1
                listOf(ProfilePickerArtworkCandidate("one", "One", listOf("one")))
            },
            loadArtwork = {
                artworkCalls += 1
                true
            },
        )

        controller.run(reducedMotion = true)
        controller.run(reducedMotion = true)

        assertEquals(1, catalogCalls)
        assertEquals(1, artworkCalls)
    }
}
