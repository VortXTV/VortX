package com.vortx.android.usenet

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NzbAssemblyLimitsTest {
    @Test
    fun `underreported multi segment NZB stops before the ordered third part reaches disk`() {
        // The declared XML size claims two 4-byte segments. The first two commit in order, but the third
        // decoded segment would grow the actual playable file past that declaration and must never be copied.
        var written = 0L
        listOf(4L, 4L, 4L).forEachIndexed { index, part ->
            val allowed = NzbAssemblyLimits.permitsAppend(written, part, declaredBytes = 8L)
            if (index < 2) {
                assertTrue("declared part $index should commit", allowed)
                written += part
            } else {
                assertFalse("underreported third part must be rejected before disk copy", allowed)
            }
        }
        assertTrue("only declared bytes reached the assembled output", written == 8L)
    }
}
