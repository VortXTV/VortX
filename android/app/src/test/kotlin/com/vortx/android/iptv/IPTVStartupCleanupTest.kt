package com.vortx.android.iptv

import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IPTVStartupCleanupTest {

    @Test
    fun `application startup seam initializes before replay on its background scope`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "iptv-startup-io")
        }
        val dispatcher = executor.asCoroutineDispatcher()
        try {
            val events = mutableListOf<String>()
            val scope = CoroutineScope(SupervisorJob() + dispatcher)

            launchIPTVStartupCleanup(
                scope = scope,
                initialize = { events += "init:${Thread.currentThread().name}" },
                resumeAll = {
                    events += "resume:${Thread.currentThread().name}"
                    true
                },
                onFailure = { events += "failure" },
            ).join()

            assertEquals(listOf("init", "resume"), events.map { it.substringBefore(':') })
            assertTrue(events.all { it.substringAfter(':').startsWith("iptv-startup-io") })
            assertFalse(events.any { it.contains("main", ignoreCase = true) })
        } finally {
            dispatcher.close()
        }
    }
}
