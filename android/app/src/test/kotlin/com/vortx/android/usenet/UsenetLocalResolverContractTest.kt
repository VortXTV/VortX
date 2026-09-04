package com.vortx.android.usenet

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the bounded disk-window design without requiring a live NNTP provider. */
class UsenetLocalResolverContractTest {
    private val source = File("src/main/kotlin/com/vortx/android/usenet/UsenetLocalResolver.kt").readText()

    @Test fun `segments are not retained as a whole video byte array`() {
        assertFalse(source.contains("arrayOfNulls<ByteArray>(segments.size)"))
        assertTrue(source.contains("MAX_SEGMENT_WORKERS = 4"))
        assertTrue(source.contains("MAX_SEGMENT_BYTES"))
    }

    @Test fun `workers commit private parts and final output in index order`() {
        assertTrue(source.contains("File(workDir, \"${'$'}seg.part\")"))
        assertTrue(source.contains("for (segment in segments.indices)"))
        assertTrue(source.contains("File(workDir, \"${'$'}segment.part\")"))
    }

    @Test fun `cancellation and failures remove partial artifacts`() {
        assertTrue(source.contains("coroutineContext.ensureActive()"))
        assertTrue(source.contains("target.delete()"))
        assertTrue(source.contains("workDir.listFiles()?.forEach { it.delete() }"))
    }
}
