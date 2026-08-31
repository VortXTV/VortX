package com.vortx.android.ui.viewmodel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CacheCheckGenerationGateTest {

    @Test
    fun lateEarlierSnapshotCannotDecorateAfterANewerSnapshotBegins() {
        val gate = CacheCheckGenerationGate()
        val early = gate.begin()
        val latest = gate.begin()

        assertFalse(gate.isCurrent(early))
        assertTrue(gate.isCurrent(latest))
    }
}
