package com.vortx.android.ui.components

import org.junit.Assert.*
import org.junit.Test

class CinemaDetailLayoutPolicyTest {
    @Test fun `portrait phone hero is 78 percent of available viewport`() {
        assertEquals(624f, cinemaDetailHeroHeightDp(390f, 800f), 0.001f)
        assertEquals(546f, cinemaDetailHeroHeightDp(320f, 700f), 0.001f)
    }
    @Test fun `regular tablet and landscape bands retain room for controls`() {
        assertEquals(480f, cinemaDetailHeroHeightDp(840f, 800f), 0.001f)
        assertEquals(360f, cinemaDetailHeroHeightDp(800f, 390f), 0.001f)
        assertEquals(720f, cinemaDetailHeroHeightDp(600f, 1200f), 0.001f)
    }
    @Test fun `invalid measurements never produce zero height or nonfinite layout`() {
        assertEquals(420f, cinemaDetailHeroHeightDp(Float.NaN, 800f), 0f)
        assertEquals(420f, cinemaDetailHeroHeightDp(390f, Float.POSITIVE_INFINITY), 0f)
        assertEquals(420f, cinemaDetailHeroHeightDp(0f, 0f), 0f)
    }
    @Test fun `Sources jump index matches every optional fact combination`() {
        for (mask in 0 until 16) {
            val flags = (0 until 4).map { mask and (1 shl it) != 0 }
            assertEquals(3 + flags.count { it }, cinemaDetailSourceSectionIndex(flags[0], flags[1], flags[2], flags[3]))
        }
    }
}
