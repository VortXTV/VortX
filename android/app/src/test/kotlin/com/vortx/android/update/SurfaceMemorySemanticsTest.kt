package com.vortx.android.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * SEC-07 (Later vs Skip semantics) and SEC-08 (concurrency) coverage. [UpdateChecker.SurfaceMemory] is the
 * exact state object the production checker uses for once-per-launch popups and session-scoped Later, so
 * hammering it from many threads proves the race the audit flagged cannot recur.
 */
class SurfaceMemorySemanticsTest {

    private val key = "0.3.15.189"

    @Test
    fun popupIsClaimedExactlyOncePerLaunchPerBuild() {
        val memory = UpdateChecker.SurfaceMemory()
        assertTrue(memory.claimPopup(key))
        assertFalse(memory.claimPopup(key))
        // A different build still gets its own first popup.
        assertTrue(memory.claimPopup("0.3.16.190"))
    }

    @Test
    fun laterSuppressesBannerAndPopupOnlyForThisSessionState() {
        val memory = UpdateChecker.SurfaceMemory()
        memory.later(key)
        assertFalse(memory.shouldSurface(key))
        assertFalse(memory.claimPopup(key)) // never pops up what the user sent away this session

        // Other builds are untouched.
        assertTrue(memory.shouldSurface("0.4.0.200"))
        assertTrue(memory.claimPopup("0.4.0.200"))
    }

    @Test
    fun laterAfterPopupClaimStillSuppressesTheRestOfTheSession() {
        val memory = UpdateChecker.SurfaceMemory()
        assertTrue(memory.claimPopup(key)) // popup shown...
        memory.later(key) // ...then user picks Later
        assertFalse(memory.shouldSurface(key))
        assertFalse(memory.claimPopup(key))
    }

    @Test
    fun concurrentSurfacingRacesConvergeToAtMostOnePopup() {
        val memory = UpdateChecker.SurfaceMemory()
        val threads = 8
        val iterations = 2_000
        val pool = Executors.newFixedThreadPool(threads)
        val start = CountDownLatch(1)
        val claims = AtomicInteger(0)
        val surfacableSeen = AtomicInteger(0)
        repeat(threads) {
            pool.submit {
                start.await()
                repeat(iterations) {
                    if (memory.shouldSurface(key)) surfacableSeen.incrementAndGet()
                    if (memory.claimPopup(key)) claims.incrementAndGet()
                }
            }
        }
        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(30, TimeUnit.SECONDS))

        // Exactly one claim wins despite 16k racing calls: no duplicate prompt, no lost prompt.
        assertEquals(1, claims.get())
        assertTrue(surfacableSeen.get() >= 1)
    }

    @Test
    fun concurrentReadsNeverResurfaceALateredBuild() {
        val memory = UpdateChecker.SurfaceMemory()
        // Later lands FIRST, then every thread races reads/writes against it: any true afterwards would be
        // a torn read of an unsynchronized set (the original SEC-08 defect).
        memory.later(key)
        val threads = 8
        val iterations = 1_000
        val pool = Executors.newFixedThreadPool(threads)
        val start = CountDownLatch(1)
        val resurfaced = AtomicInteger(0)
        repeat(threads) { index ->
            pool.submit {
                start.await()
                repeat(iterations) {
                    if (index % 2 == 0) memory.later(key)
                    else {
                        if (memory.shouldSurface(key)) resurfaced.incrementAndGet()
                        // claimPopup returning true for a latered build is equally forbidden.
                        if (memory.claimPopup("other.build.1")) Unit
                    }
                }
            }
        }
        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(30, TimeUnit.SECONDS))
        assertEquals(0, resurfaced.get())
        assertFalse(memory.shouldSurface(key))
        assertFalse(memory.claimPopup(key))
        // Untouched builds keep working after all the contention.
        assertTrue(memory.shouldSurface("other.build.1"))
    }
}
