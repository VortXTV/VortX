package com.vortx.android.sources

import org.junit.Assert.assertEquals
import org.junit.Test

class SourceQuickFiltersTest {
    @Test fun `all real-model quick-filter policy cases`() {
        assertEquals(17, sourceQuickFilterPolicyCases())
    }
}
