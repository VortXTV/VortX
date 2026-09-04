package com.vortx.android.usenet

import java.io.File
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsenetCachePolicyTest {
    @Test
    fun `reservation rejects a title larger than the bounded cache`() {
        val home = createTempDirectory("usenet-cache").toFile()
        try {
            assertFalse(UsenetCachePolicy.reserve(home, UsenetCachePolicy.MAX_CACHE_BYTES + 1))
        } finally { home.deleteRecursively() }
    }

    @Test
    fun `old completed cache files are eviction candidates before reservation`() {
        val home = createTempDirectory("usenet-cache").toFile()
        try {
            val stale = File(home, "vortx-nzb-stale.mkv").apply { writeBytes(ByteArray(4)); setLastModified(1) }
            assertTrue(UsenetCachePolicy.reserve(home, incomingBytes = 4, maxBytes = 4))
            assertFalse("oldest completed title is evicted before a new reservation", stale.exists())
        } finally { home.deleteRecursively() }
    }
}
