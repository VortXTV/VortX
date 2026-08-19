package com.vortx.android.sources

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SourcePreviewModelTest {

    private fun TestModel(
        provider: () -> SourcePrefsSnapshot,
        scope: CoroutineScope,
        dispatcher: kotlinx.coroutines.CoroutineDispatcher,
    ) = SourcePreviewModel(
        snapshotProvider = provider,
        scope = scope,
        debounceMs = 0L,
        computeDispatcher = dispatcher,
    )

    @Test
    fun `default prefs surface every sample source with none hidden`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val model = TestModel({ SourcePrefsSnapshot.DEFAULT }, CoroutineScope(dispatcher), dispatcher)
        advanceUntilIdle()

        assertEquals(5, model.sampleCount.value)
        assertEquals(0, model.hiddenCount.value)
        assertEquals(5, model.rows.value.size)
        // The cached 4K remux is the auto-pick and leads the list.
        assertEquals("fixture-0", model.rows.value.first().id)
        assertTrue(model.rows.value.first().isBest)
    }

    @Test
    fun `a hide keyword drops matching sources and raises the hidden count`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val snapshot = SourcePrefsSnapshot.DEFAULT.copy(excludeTerms = listOf("hdcam"))
        val model = TestModel({ snapshot }, CoroutineScope(dispatcher), dispatcher)
        advanceUntilIdle()

        assertEquals(5, model.sampleCount.value)
        assertEquals(1, model.hiddenCount.value)
        assertEquals(4, model.rows.value.size)
        assertFalse(model.rows.value.any { it.id == "fixture-3" }) // the CAM was dropped
    }

    @Test
    fun `an empty sample restores the bundled fixture`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val model = TestModel({ SourcePrefsSnapshot.DEFAULT }, CoroutineScope(dispatcher), dispatcher)
        advanceUntilIdle()
        assertEquals(5, model.sampleCount.value)

        model.update(emptyList())
        advanceUntilIdle()
        assertEquals(5, model.sampleCount.value) // fixture, not blank
    }
}
