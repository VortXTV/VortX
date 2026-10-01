package com.vortx.android.usenet

import org.junit.Assert.assertTrue
import org.junit.Test

class NzbAssemblyLimitsTest {
    @Test
    fun `yenc whole size and contiguous ranges not NZB estimates define coverage`() {
        val first = YencDecoder.DecodedPart(totalBytes = 10, begin = 1, endInclusive = 4, decodedBytes = 4)
        val second = YencDecoder.DecodedPart(totalBytes = 10, begin = 5, endInclusive = 10, decodedBytes = 6)
        assertTrue(NzbAssemblyLimits.permitsPart(0, first))
        assertTrue(NzbAssemblyLimits.permitsPart(4, second))
        assertTrue(!NzbAssemblyLimits.permitsPart(4, second.copy(begin = 6)))
        assertTrue(!NzbAssemblyLimits.permitsPart(4, second.copy(totalBytes = 8)))
    }
}
