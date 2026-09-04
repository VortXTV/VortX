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
            assertFalse(UsenetCachePolicy.allocate(home, "too-big", UsenetCachePolicy.MAX_CACHE_BYTES + 1) != null)
        } finally { home.deleteRecursively() }
    }

    @Test
    fun `old completed cache files are eviction candidates before reservation`() {
        val home = createTempDirectory("usenet-cache").toFile()
        try {
            val stale = File(home, "vortx-nzb-stale.mkv").apply { writeBytes(ByteArray(4)); setLastModified(1) }
            assertTrue(UsenetCachePolicy.allocate(home, "fresh", incomingBytes = 4, maxBytes = 4) != null)
            assertFalse("oldest completed title is evicted before a new reservation", stale.exists())
        } finally { home.deleteRecursively() }
    }

    @Test fun `active reservation is never evicted by a concurrent allocation`() {
        val home = createTempDirectory("usenet-cache").toFile()
        try {
            val active = requireNotNull(UsenetCachePolicy.allocate(home, "live", 4, 4))
            assertFalse(UsenetCachePolicy.allocate(home, "other", 1, 4) != null)
            active.abandon()
        } finally { home.deleteRecursively() }
    }
}
