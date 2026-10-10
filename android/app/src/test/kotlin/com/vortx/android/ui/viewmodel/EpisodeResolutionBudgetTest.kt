package com.vortx.android.ui.viewmodel

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import com.vortx.android.sources.SourceRequestFence
import org.junit.Assert.*
import org.junit.Test

class EpisodeResolutionBudgetTest {
    @Test fun `empty partial UI is not a network settlement and A B A cannot unlock old target`() = runBlocking {
        val fence = SourceRequestFence("owner")
        val a = fence.begin("owner", "opaque-a")
        val state = MutableStateFlow(EpisodeSourceSettlement(a))
        val wait = async { awaitEpisodeSourceSettlement(state, a) }
        yield(); assertFalse(wait.isCompleted)
        state.value = EpisodeSourceSettlement(fence.begin("owner", "opaque-b"), true)
        yield(); assertFalse(wait.isCompleted)
        state.value = EpisodeSourceSettlement(fence.begin("owner", "opaque-a"), true)
        yield(); assertFalse(wait.isCompleted)
        state.value = EpisodeSourceSettlement(a, true)
        assertSame(a, withTimeout(1000) { wait.await() }.request)
    }
    @Test fun `source and candidate phases share sixty five second monotonic target budget`() {
        var now = 0L; val budget = EpisodeResolutionBudget(nowMs = { now })
        assertEquals(65_000L, budget.remainingMs()); assertEquals(20_000L, budget.sourceRemainingMs())
        now = 19_000; assertEquals(1_000L, budget.sourceRemainingMs()); assertEquals(46_000L, budget.remainingMs())
        now = 21_000; assertEquals(0L, budget.sourceRemainingMs()); assertEquals(44_000L, budget.remainingMs())
        now = 66_000; assertEquals(0L, budget.remainingMs())
    }
    @Test fun `timeout cancels actual source child and candidate cannot restart elapsed outer budget`() = runBlocking {
        val budget = EpisodeResolutionBudget(outerMs = 80, sourceMs = 20, candidateMs = 200)
        var stopped = false
        assertNull(budget.source { try { awaitCancellation() } finally { stopped = true } }); assertTrue(stopped)
        val start = System.nanoTime(); assertNull(budget.candidate { delay(500); true })
        assertTrue((System.nanoTime() - start) / 1_000_000 < 150)
        assertNull(budget.outer { true })
    }
}
