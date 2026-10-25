package com.vortx.android.player.queue

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackQueuePresentationTest {
    private val owner = ContinueWatchingOwner("profile-a", "slot-a", "principal-a", true, 7L)
    private fun entry(n: Int) = PlaybackQueueEntry(UUID(0L, n.toLong()).toString(),
        MetaItem("tt$n", MediaType.MOVIE, "Movie $n", "poster-$n.jpg"))
    private fun source(entries: List<PlaybackQueueEntry> = (1..3).map(::entry)) =
        PlaybackQueueState(owner = owner, revision = 41L, ready = true, entries = entries)
    private fun assertUnavailable(projected: PlaybackQueueState, original: PlaybackQueueState) {
        assertFalse(projected.ready)
        assertTrue(projected.entries.isEmpty())
        assertNotNull(projected.error)
        assertEquals(original.owner, projected.owner)
        assertEquals(original.revision, projected.revision)
    }

    @Test fun `denied metadata is hidden only in projection while raw saved entries stay unchanged`() {
        val raw = source()
        var admittedOwner: ContinueWatchingOwner? = null
        val projected = PlaybackQueuePresentation.project(raw, owner, { owner }) { items, captured ->
            admittedOwner = captured
            assertEquals(raw.entries.map { it.item }, items)
            Result.success(items.filter { it.id != "tt2" })
        }
        assertEquals(owner, admittedOwner)
        assertTrue(projected.ready)
        assertEquals(listOf(entry(1), entry(3)), projected.entries)
        assertEquals(listOf(entry(1), entry(2), entry(3)), raw.entries)
        assertEquals(41L, projected.revision)
        assertEquals(owner, projected.owner)
        assertEquals("Some saved queue entries are unavailable for this profile.", projected.error)
    }

    @Test fun `duplicate catalog targets preserve their separate UUIDs and original order`() {
        val duplicate = entry(3).copy(item = entry(1).item)
        val raw = source(listOf(entry(1), entry(2), duplicate))
        val projected = PlaybackQueuePresentation.project(raw, owner, { owner }) { _, _ ->
            Result.success(listOf(entry(1).item))
        }
        assertEquals(listOf(entry(1).id, duplicate.id), projected.entries.map { it.id })
        assertEquals(listOf("tt1", "tt1"), projected.entries.map { it.item.id })
        assertEquals(3, raw.entries.size)
    }

    @Test fun `admission identifies allowed targets without replacing original display metadata`() {
        val raw = source(listOf(entry(1)))
        val changedMetadata = entry(1).item.copy(name = "Replacement name", poster = "replacement.jpg",
            resumeSeconds = 99.0, continueWatchingPermit = "synthetic-unretained-permit")
        val projected = PlaybackQueuePresentation.project(raw, owner, { owner }) { _, _ ->
            Result.success(listOf(changedMetadata))
        }
        assertEquals(raw, projected)
        assertEquals(entry(1).item, projected.entries.single().item)
    }

    @Test fun `a foreign admitted catalog ID or media type makes the entire projection unavailable`() {
        val raw = source()
        for (foreign in listOf(entry(99).item, entry(1).item.copy(type = MediaType.SERIES))) {
            val projected = PlaybackQueuePresentation.project(raw, owner, { owner }) { items, _ ->
                Result.success(items + foreign)
            }
            assertUnavailable(projected, raw)
            assertEquals(3, raw.entries.size)
        }
    }

    @Test fun `source owner mismatch and failed initial owner lookup never call admission`() {
        val raw = source()
        var calls = 0
        val mismatch = PlaybackQueuePresentation.project(raw, owner.copy(profileId = "profile-b"), { owner }) { _, _ ->
            calls += 1
            Result.success(emptyList())
        }
        val unavailable = PlaybackQueuePresentation.project(raw, owner, { error("Synthetic owner failure") }) { _, _ ->
            calls += 1
            Result.success(emptyList())
        }
        assertUnavailable(mismatch, raw)
        assertUnavailable(unavailable, raw)
        assertEquals(0, calls)
    }

    @Test fun `exact owner change or original identity with new ABA revision after admission fails closed`() {
        val raw = source()
        for (successor in listOf(owner.copy(principal = "principal-b"), owner.copy(revision = 9L))) {
            var current = owner
            val projected = PlaybackQueuePresentation.project(raw, owner, { current }) { items, _ ->
                current = successor
                Result.success(items)
            }
            assertUnavailable(projected, raw)
        }
        assertEquals(3, raw.entries.size)
    }

    @Test fun `owner provider failure after admission discards the projected entries`() {
        val raw = source()
        var lookups = 0
        var admissions = 0
        val projected = PlaybackQueuePresentation.project(raw, owner, {
            lookups += 1
            if (lookups == 1) owner else error("Synthetic successor lookup failure")
        }) { items, _ ->
            admissions += 1
            Result.success(items)
        }
        assertUnavailable(projected, raw)
        assertEquals(1, admissions)
        assertEquals(2, lookups)
    }

    @Test fun `failed or throwing admission never publishes any original entries`() {
        val raw = source()
        val failed = PlaybackQueuePresentation.project(raw, owner, { owner }) { _, _ ->
            Result.failure(IllegalStateException("Synthetic admission failure"))
        }
        val thrown = PlaybackQueuePresentation.project(raw, owner, { owner }) { _, _ ->
            error("Synthetic admission throw")
        }
        assertUnavailable(failed, raw)
        assertUnavailable(thrown, raw)
        assertEquals(3, raw.entries.size)
    }

    @Test fun `existing save error is retained in preference to a mixed hidden-entry notice`() {
        val raw = source().copy(ready = false, error = "Synthetic saved queue error")
        val projected = PlaybackQueuePresentation.project(raw, owner, { owner }) { items, _ ->
            Result.success(items.take(1))
        }
        assertEquals(raw.error, projected.error)
        assertEquals(listOf(entry(1)), projected.entries)
        assertFalse(projected.ready)
        assertEquals(3, raw.entries.size)
    }
}
