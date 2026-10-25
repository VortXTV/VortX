package com.vortx.android.player.queue

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackQueueModelTest {
    private val owner = ContinueWatchingOwner("profile-a", "slot-a", "principal-a", true, 7L)
    private fun id(n: Int) = UUID(0L, n.toLong()).toString()
    private fun movie(n: Int) = MetaItem("tt$n", MediaType.MOVIE, "Movie $n")
    private fun initial() = PlaybackQueueState(owner = owner, revision = 1L, ready = true)
    private fun populated(): PlaybackQueueState = (1..3).fold(initial()) { state, n ->
        requireNotNull(PlaybackQueueModel.add(state, owner, movie(n), false, id(n)))
    }

    @Test fun `append and play-next retain stable entry UUID and explicit order`() {
        val first = requireNotNull(PlaybackQueueModel.add(initial(), owner, movie(1), false, id(1)))
        val appended = requireNotNull(PlaybackQueueModel.add(first, owner, movie(2), false, id(2)))
        val next = requireNotNull(PlaybackQueueModel.add(appended, owner, movie(3), true, id(3)))
        assertEquals(listOf(id(3), id(1), id(2)), next.entries.map { it.id })
        assertEquals(4L, next.revision)
        assertEquals(listOf(id(1)), first.entries.map { it.id })
    }

    @Test fun `exact hundred-entry capacity is accepted and overflow cannot evict an older entry`() {
        val full = (1..100).fold(initial()) { state, n ->
            requireNotNull(PlaybackQueueModel.add(state, owner, movie(n), false, id(n)))
        }
        assertEquals(100, full.entries.size)
        assertNull(PlaybackQueueModel.add(full, owner, movie(101), true, id(101)))
        assertEquals((1..100).map(::id), full.entries.map { it.id })
    }

    @Test fun `a title may be queued twice but one queue UUID cannot be reused`() {
        val first = requireNotNull(PlaybackQueueModel.add(initial(), owner, movie(1), false, id(1)))
        assertNull(PlaybackQueueModel.add(first, owner, movie(2), false, id(1)))
        val duplicateTitle = requireNotNull(PlaybackQueueModel.add(first, owner, movie(1), false, id(2)))
        assertEquals(listOf("tt1", "tt1"), duplicateTitle.entries.map { it.item.id })
        assertEquals(listOf(id(1), id(2)), duplicateTitle.entries.map { it.id })
    }

    @Test fun `move and remove address one UUID rather than every equal title`() {
        val duplicate = requireNotNull(PlaybackQueueModel.add(populated(), owner, movie(1), false, id(4)))
        val moved = requireNotNull(PlaybackQueueModel.move(duplicate, owner, id(4), -1))
        assertEquals(listOf(id(1), id(2), id(4), id(3)), moved.entries.map { it.id })
        val removed = requireNotNull(PlaybackQueueModel.remove(moved, owner, id(1)))
        assertEquals(listOf(id(2), id(4), id(3)), removed.entries.map { it.id })
        assertEquals("tt1", removed.entries.first { it.id == id(4) }.item.id)
    }

    @Test fun `stale missing and out-of-bounds row operations do not mutate queue`() {
        val before = populated()
        assertNull(PlaybackQueueModel.move(before, owner, id(1), -1))
        assertNull(PlaybackQueueModel.move(before, owner, id(3), 1))
        assertNull(PlaybackQueueModel.move(before, owner, id(2), 0))
        assertNull(PlaybackQueueModel.move(before, owner, id(2), 2))
        assertNull(PlaybackQueueModel.move(before, owner, id(99), -1))
        assertNull(PlaybackQueueModel.remove(before, owner, id(99)))
        assertEquals(listOf(id(1), id(2), id(3)), before.entries.map { it.id })
    }

    @Test fun `capture alone never consumes and accepted consume removes exactly one entry`() {
        val before = populated()
        val token = requireNotNull(PlaybackQueueModel.capture(before, owner, id(2)))
        assertEquals(3, before.entries.size)
        assertTrue(PlaybackQueueModel.accepts(before, owner, token))
        val consumed = requireNotNull(PlaybackQueueModel.consumeAfterAccepted(before, owner, token))
        assertEquals(listOf(id(1), id(3)), consumed.entries.map { it.id })
        assertNull(PlaybackQueueModel.consumeAfterAccepted(consumed, owner, token))
    }

    @Test fun `every structural edit revokes an unresolved token including unrelated-tail addition`() {
        val before = populated()
        val token = requireNotNull(PlaybackQueueModel.capture(before, owner, id(1)))
        val appended = requireNotNull(PlaybackQueueModel.add(before, owner, movie(4), false, id(4)))
        val moved = requireNotNull(PlaybackQueueModel.move(before, owner, id(3), -1))
        val removed = requireNotNull(PlaybackQueueModel.remove(before, owner, id(3)))
        for (after in listOf(appended, moved, removed)) {
            assertFalse(PlaybackQueueModel.accepts(after, owner, token))
            assertNull(PlaybackQueueModel.consumeAfterAccepted(after, owner, token))
        }
    }

    @Test fun `owner mismatch and same-owner ABA revision cannot borrow prior queue authority`() {
        val before = populated()
        val token = requireNotNull(PlaybackQueueModel.capture(before, owner, id(1)))
        val candidates = listOf(
            owner.copy(profileId = "profile-b"), owner.copy(accountSlot = "slot-b"),
            owner.copy(principal = "principal-b"), owner.copy(usesEngineHistory = false),
            owner.copy(revision = owner.revision + 2),
        )
        for (changed in candidates) {
            assertNull(PlaybackQueueModel.capture(before, changed, id(1)))
            assertFalse(PlaybackQueueModel.accepts(before, changed, token))
            assertFalse(PlaybackQueueModel.accepts(before.copy(owner = changed), changed, token))
            assertNull(PlaybackQueueModel.remove(before, changed, id(1)))
            assertNull(PlaybackQueueModel.add(before, changed, movie(5), false, id(5)))
        }
    }

    @Test fun `loading or unavailable snapshots cannot supply or consume a queue capability`() {
        val ready = populated()
        val token = requireNotNull(PlaybackQueueModel.capture(ready, owner, id(1)))
        for (unavailable in listOf(ready.copy(ready = false), ready.copy(owner = null))) {
            assertNull(PlaybackQueueModel.capture(unavailable, owner, id(1)))
            assertFalse(PlaybackQueueModel.accepts(unavailable, owner, token))
            assertNull(PlaybackQueueModel.consumeAfterAccepted(unavailable, owner, token))
        }
    }

    @Test fun `catalog-only projection strips progress permits and unrelated artwork metadata`() {
        val input = movie(1).copy(
            year = "2026", description = "not-a-real-private-stream", progress = 0.9f,
            background = "not-a-real-stream-url", logo = "unretained-logo", genres = listOf("Drama"),
            resumeSeconds = 120.0, watched = true, continueWatchingPermit = "not-a-real-permit",
        )
        val stored = requireNotNull(PlaybackQueueModel.add(initial(), owner, input, false, id(1))).entries.single().item
        assertEquals(MetaItem(input.id, input.type, input.name, input.poster), stored)
    }

    @Test fun `episode target preserves coordinates and video identity but never inherits up-next semantics`() {
        val episode = MetaItem("tt-show", MediaType.SERIES, "Show", preferredEpisode = PreferredEpisode(0, 2, "custom-video-id", true))
        val stored = requireNotNull(PlaybackQueueModel.add(initial(), owner, episode, false, id(1))).entries.single().item
        assertEquals(PreferredEpisode(0, 2, "custom-video-id", false), stored.preferredEpisode)
    }

    @Test fun `storage namespace is account principal profile and history-route specific but revision stable`() {
        val key = PlaybackQueueModel.storageKey(owner)
        assertEquals(key, PlaybackQueueModel.storageKey(owner.copy(revision = 900L)))
        assertTrue(key.matches(Regex("queue\\.v1\\.[0-9a-f]{64}")))
        for (other in listOf(owner.copy(profileId = "b"), owner.copy(accountSlot = "b"),
            owner.copy(principal = "b"), owner.copy(usesEngineHistory = false))) {
            assertNotEquals(key, PlaybackQueueModel.storageKey(other))
        }
        assertNotEquals(
            PlaybackQueueModel.storageKey(owner.copy(accountSlot = "a:b", principal = "c")),
            PlaybackQueueModel.storageKey(owner.copy(accountSlot = "a", principal = "b:c")),
        )
        assertFalse(key.contains(owner.principal))
    }

    @Test fun `unsupported media invalid metadata and noncanonical UUIDs are refused`() {
        val invalidItems = listOf(
            movie(1).copy(id = ""), movie(1).copy(id = "line\nbreak"), movie(1).copy(name = " "),
            movie(1).copy(name = "a".repeat(513)), movie(1).copy(poster = "p".repeat(4097)),
            movie(1).copy(preferredEpisode = PreferredEpisode(1, 1, "episode")),
            MetaItem("channel", MediaType.CHANNEL, "Live"),
            MetaItem("show", MediaType.SERIES, "Show", preferredEpisode = PreferredEpisode(-1, 1)),
        )
        for (item in invalidItems) assertTrue(runCatching { PlaybackQueueModel.add(initial(), owner, item, false, id(1)) }.isFailure)
        for (badId in listOf("1-1-1-1-1", "not-a-uuid", "00000000-0000-4000-8000-ABCDEFABCDEF")) {
            assertTrue(runCatching { PlaybackQueueModel.add(initial(), owner, movie(1), false, badId) }.isFailure)
        }
        assertNotNull(PlaybackQueueModel.add(initial(), owner, movie(1), false, id(1)))
    }
}
