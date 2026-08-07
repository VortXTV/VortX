package com.vortx.android.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DetailLogoPolicyTest {
    @Test
    fun `usable addon logo is trimmed and retained`() {
        assertEquals(
            "https://images.example/title.png",
            detailLogoUrl("  https://images.example/title.png  ", false),
        )
    }

    @Test
    fun `missing blank or failed logo falls back to title text`() {
        assertNull(detailLogoUrl(null, false))
        assertNull(detailLogoUrl("   ", false))
        assertNull(detailLogoUrl("https://images.example/title.png", true))
    }
}
