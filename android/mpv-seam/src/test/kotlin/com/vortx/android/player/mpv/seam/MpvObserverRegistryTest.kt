package com.vortx.android.player.mpv.seam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MpvObserverRegistryTest {
    @Test fun `callback may remove itself and another observer without corrupting iteration`() {
        val registry = MpvObserverRegistry<Int>()
        listOf(1, 2, 3).forEach(registry::add)
        val delivered = mutableListOf<Int>()
        registry.dispatch {
            delivered.add(it)
            if (it == 1) {
                registry.remove(1)
                registry.remove(2)
                registry.add(4)
            }
        }
        assertEquals(listOf(1, 2, 3), delivered)
        delivered.clear()
        registry.dispatch(delivered::add)
        assertEquals(listOf(3, 4), delivered)
    }

    @Test fun `callback does not hold registry lock across client teardown`() {
        val registry = MpvObserverRegistry<Int>()
        registry.add(1)
        registry.dispatch {
            val removed = CountDownLatch(1)
            val worker = Thread { registry.remove(1); removed.countDown() }
            worker.start()
            assertTrue("teardown blocked by callback lock", removed.await(2, TimeUnit.SECONDS))
            worker.join(2000)
        }
    }
}
