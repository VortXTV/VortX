package com.vortx.android.usenet

import java.io.ByteArrayInputStream
import java.io.IOException
import org.junit.Assert.assertThrows
import org.junit.Test

class NntpLineReaderTest {
    @Test
    fun `huge unterminated article line is rejected at the line cap before materialization`() {
        val input = ByteArrayInputStream(ByteArray(32 * 1024) { 'x'.code.toByte() })
        assertThrows(IOException::class.java) {
            NntpLineReader(input).readLine(limit = 1024)
        }
    }
}
