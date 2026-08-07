package com.vortx.android.profile

import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileActivationOrderTest {
    @Test
    fun `home transition and new overlay are active before board rebuild`() {
        val events = mutableListOf<String>()

        activateProfileInOrder(
            transitionHome = { events += "transition" },
            applyPlayback = { events += "playback" },
            activateOverlay = { events += "overlay" },
            reloadDependants = { events += "reload" },
            publishProfile = { events += "publish" },
            rebuildBoard = { events += "rebuild" },
        )

        assertEquals(
            listOf("transition", "playback", "overlay", "reload", "publish", "rebuild"),
            events,
        )
    }
}
