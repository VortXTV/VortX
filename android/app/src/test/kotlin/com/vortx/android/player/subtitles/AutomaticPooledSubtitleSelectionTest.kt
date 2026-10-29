package com.vortx.android.player.subtitles

import com.vortx.android.player.PlayerSubtitleSelection
import com.vortx.android.player.SubtitleSelectionAuthority
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

/** Actual suspend helper + actual subtitle identity authority; callback boundaries are synthetic.
 * These tests do not establish Compose, secure account, application looper, MPV or native acceptance. */
class AutomaticPooledSubtitleSelectionTest {
    @Test
    fun `missing or denied original receipt never starts download or mount`() = runBlocking {
        val authority = SubtitleSelectionAuthority()
        var downloads = 0
        var mounts = 0
        assertFalse(runAutomaticPooledSubtitleSelection(
            capture = authority::capture,
            permits = authority::isCurrent,
            download = { downloads++; "synthetic-local-file" },
            mount = { _, _ -> mounts++ },
        ))
        authority.beginSource("source")
        assertFalse(runAutomaticPooledSubtitleSelection(
            capture = authority::capture,
            permits = { false },
            download = { downloads++; "synthetic-local-file" },
            mount = { _, _ -> mounts++ },
        ))
        assertEquals(0, downloads)
        assertEquals(0, mounts)
    }

    @Test
    fun `late Off embedded or external manual choice vetoes completed download`() = runBlocking {
        for (choice in listOf("Off", "embedded", "external")) {
            val authority = SubtitleSelectionAuthority()
            authority.beginSource("source")
            val original = authority.capture()!!
            val release = CompletableDeferred<String?>()
            var mounted: PlayerSubtitleSelection? = null
            val work = async(start = CoroutineStart.UNDISPATCHED) {
                runAutomaticPooledSubtitleSelection(
                    capture = authority::capture,
                    permits = authority::isCurrent,
                    download = { release.await() },
                    mount = { _, receipt -> mounted = receipt },
                )
            }
            assertFalse(choice, work.isCompleted)
            val manual = authority.beginChoice()!!
            release.complete("synthetic-local-file")
            assertFalse(choice, work.await())
            assertFalse(choice, authority.isCurrent(original))
            assertTrue(choice, authority.isCurrent(manual))
            assertNull(choice, mounted)
        }
    }

    @Test
    fun `source A B A cannot adopt original suspended pool receipt`() = runBlocking {
        val authority = SubtitleSelectionAuthority()
        val original = authority.beginSource("A")!!
        val release = CompletableDeferred<String?>()
        var mounts = 0
        val work = async(start = CoroutineStart.UNDISPATCHED) {
            runAutomaticPooledSubtitleSelection(
                capture = authority::capture,
                permits = authority::isCurrent,
                download = { release.await() },
                mount = { _, _ -> mounts++ },
            )
        }
        authority.beginSource("B")
        val returned = authority.beginSource("A")!!
        release.complete("synthetic-local-file")
        assertFalse(work.await())
        assertEquals(original.sourceContext, returned.sourceContext)
        assertFalse(authority.isCurrent(original))
        assertTrue(authority.isCurrent(returned))
        assertEquals(0, mounts)
    }

    @Test
    fun `cancelled noncooperative download cannot mount while original receipt remains current`() = runBlocking {
        val authority = SubtitleSelectionAuthority()
        val original = authority.beginSource("source")!!
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var mounts = 0
        val work = async(start = CoroutineStart.UNDISPATCHED) {
            runAutomaticPooledSubtitleSelection(
                capture = authority::capture,
                permits = authority::isCurrent,
                download = {
                    withContext(NonCancellable) {
                        entered.complete(Unit)
                        release.await()
                        "synthetic-local-file"
                    }
                },
                mount = { _, _ -> mounts++ },
            )
        }
        assertTrue(entered.isCompleted)
        work.cancel()
        release.complete(Unit)
        work.join()
        assertTrue(work.isCancelled)
        assertTrue(authority.isCurrent(original))
        assertEquals(0, mounts)
    }

    private data class OwnerReceipt(val selection: PlayerSubtitleSelection, val ownerEpoch: Any)

    @Test
    fun `owner revoke and logical account return cannot adopt an old download`() = runBlocking {
        val authority = SubtitleSelectionAuthority()
        val original = authority.beginSource("source")!!
        var logicalOwner = "A"
        var ownerEpoch = Any()
        val release = CompletableDeferred<String?>()
        var mounts = 0
        val work = async(start = CoroutineStart.UNDISPATCHED) {
            runAutomaticPooledSubtitleSelection(
                capture = { authority.capture()?.let { OwnerReceipt(it, ownerEpoch) } },
                permits = { it.ownerEpoch === ownerEpoch && logicalOwner == "A" && authority.isCurrent(it.selection) },
                download = { release.await() },
                mount = { _, _ -> mounts++ },
            )
        }
        logicalOwner = "B"
        ownerEpoch = Any()
        logicalOwner = "A"
        ownerEpoch = Any()
        release.complete("synthetic-local-file")
        assertFalse(work.await())
        assertTrue(authority.isCurrent(original)) // independent owner epoch supplies the rejection
        assertEquals(0, mounts)
    }

    @Test
    fun `successful attempt captures once and awaits mount with the exact original receipt`() = runBlocking {
        val authority = SubtitleSelectionAuthority()
        val original = authority.beginSource("source")!!
        val mountEntered = CompletableDeferred<Unit>()
        val releaseMount = CompletableDeferred<Unit>()
        var captures = 0
        var mounted: PlayerSubtitleSelection? = null
        var mountedFile: String? = null
        val work = async(start = CoroutineStart.UNDISPATCHED) {
            runAutomaticPooledSubtitleSelection(
                capture = { captures++; authority.capture() },
                permits = authority::isCurrent,
                download = { "synthetic-local-file" },
                mount = { file, receipt ->
                    mounted = receipt
                    mountedFile = file
                    mountEntered.complete(Unit)
                    releaseMount.await()
                },
            )
        }
        assertTrue(mountEntered.isCompleted)
        assertFalse(work.isCompleted)
        assertSame(original, mounted)
        assertEquals("synthetic-local-file", mountedFile)
        assertEquals(1, captures)
        releaseMount.complete(Unit)
        assertTrue(work.await())
        assertEquals(1, captures)
    }

    @Test
    fun `revocation during awaited mount cannot report current completion`() = runBlocking {
        val authority = SubtitleSelectionAuthority()
        val original = authority.beginSource("source")!!
        val mountEntered = CompletableDeferred<Unit>()
        val releaseMount = CompletableDeferred<Unit>()
        val work = async(start = CoroutineStart.UNDISPATCHED) {
            runAutomaticPooledSubtitleSelection(
                capture = authority::capture,
                permits = authority::isCurrent,
                download = { "synthetic-local-file" },
                mount = { _, receipt ->
                    assertSame(original, receipt)
                    mountEntered.complete(Unit)
                    releaseMount.await()
                },
            )
        }
        assertTrue(mountEntered.isCompleted)
        authority.beginChoice()
        releaseMount.complete(Unit)
        assertFalse(work.await())
    }
}
