package com.vortx.android.trickplay

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrickplaySessionUploadContractTest {

    @Test
    fun `production upload gate uses retained revisions and preserves teardown snapshots`() {
        val source = productionSource()

        assertTrue(source.contains("retainedRevision += 1L"))
        assertTrue(source.contains("revision = retainedRevision"))
        assertTrue(source.contains("deferredUpload = pending"))
        assertTrue(source.contains("uploadCoordinator.complete(push.claim, policyOutcome)"))
        assertTrue(source.contains("finally {"))
        assertTrue(source.contains("val revision: Long"))
        assertFalse(source.contains("lastUploadedCount"))
        assertFalse(source.contains("frames.size > lastUploadedCount"))
    }

    private fun productionSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/trickplay/TrickplaySession.kt"),
            File("app/src/main/kotlin/com/vortx/android/trickplay/TrickplaySession.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/trickplay/TrickplaySession.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("TrickplaySession.kt not found")
    }
}
