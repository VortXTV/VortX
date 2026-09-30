package com.vortx.android.downloads

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DownloadAutoDeleteWatchedAdmissionTest {

    @Test
    fun `disabled setting that acquires lifecycle lock first prevents reclaim admission`() {
        val lock = Any()
        var enabled = true
        val reclaimed = AtomicBoolean(false)

        DownloadAutoDeleteWatchedAdmission.setEnabled(lock, enabled = false) { enabled = it }
        val result = DownloadAutoDeleteWatchedAdmission.admit(
            lock = lock,
            isEnabled = { enabled },
            disabled = { "disabled" },
            reclaim = { reclaimed.set(true); "reclaimed" },
        )

        assertEquals("disabled", result)
        assertFalse(reclaimed.get())
    }

    @Test
    fun `setting change cannot interleave a reclaim already admitted under the same lock`() {
        val lock = Any()
        var enabled = true
        val reclaimEntered = CountDownLatch(1)
        val allowReclaim = CountDownLatch(1)
        val settingFinished = CountDownLatch(1)
        val settingWriteRan = AtomicBoolean(false)

        val reclaimer = thread {
            DownloadAutoDeleteWatchedAdmission.admit(
                lock = lock,
                isEnabled = { enabled },
                disabled = { fail("enabled admission unexpectedly disabled") },
                reclaim = {
                    reclaimEntered.countDown()
                    assertTrue(allowReclaim.await(1, TimeUnit.SECONDS))
                },
            )
        }
        assertTrue(reclaimEntered.await(1, TimeUnit.SECONDS))
        val disable = thread {
            DownloadAutoDeleteWatchedAdmission.setEnabled(lock, enabled = false) {
                enabled = it
                settingWriteRan.set(true)
                settingFinished.countDown()
            }
        }

        assertFalse("OFF must wait rather than race the admitted reclaim", settingFinished.await(50, TimeUnit.MILLISECONDS))
        allowReclaim.countDown()
        reclaimer.join()
        disable.join()

        assertTrue(settingWriteRan.get())
        assertFalse(enabled)
    }
}
