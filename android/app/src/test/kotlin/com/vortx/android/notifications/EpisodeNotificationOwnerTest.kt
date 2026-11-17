package com.vortx.android.notifications

import com.vortx.android.data.ContinueWatchingOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EpisodeNotificationOwnerTest {
    private val profile = "00000000-0000-0000-0000-00000000A11C"
    private val first = checkNotNull(EpisodeNotificationOwner.parse("a".repeat(64), profile))
    private val second = checkNotNull(EpisodeNotificationOwner.parse("b".repeat(64), profile))
    private val series = "tmdb:42"

    @Test
    fun `notification retries reuse one event tag and distinct episodes stay separate`() {
        val older = checkNotNull(first.notificationTag(series, 100L))
        val newer = checkNotNull(first.notificationTag(series, 200L))
        assertEquals(older, first.notificationTag(series, 100L))
        assertNotEquals(newer, older)
        assertNotEquals(older, second.notificationTag(series, 100L))
        assertNotEquals(older, first.notificationTag("tmdb:43", 100L))
        assertFalse(older.contains(first.scopeDigest))
        assertFalse(older.contains(profile))
    }

    @Test
    fun `missing or invalid air time cannot produce a notification tag`() {
        assertNull(first.notificationTag(series, 0L))
        assertNull(first.notificationTag(series, -1L))
        assertNull(first.notificationTag("", 100L))
    }

    @Test
    fun `legacy profile-only work and unavailable mount are never owners`() {
        assertNull(EpisodeNotificationOwner.parse(null, profile))
        assertNull(EpisodeNotificationOwner.parse("native-unavailable", profile))
        assertNull(EpisodeNotificationOwner.parse(first.scopeDigest, null))
        assertFalse(first.matchesLibrary(null))
    }

    @Test
    fun `same profile id cannot authorize an alert for a different account`() {
        assertNotEquals(first, second)
        assertTrue(first.matchesLibrary(ContinueWatchingOwner(profile, first.scopeDigest, "first", true, 1)))
        assertFalse(first.matchesLibrary(ContinueWatchingOwner(profile, second.scopeDigest, "second", true, 1)))
        assertFalse(first.matchesLibrary(ContinueWatchingOwner("another-profile", first.scopeDigest, "first", true, 1)))
    }

    @Test
    fun `a new episode does not replace an eligible due retry`() {
        val due = first.eventKey(series, 100)
        val future = first.eventKey(series, 200)
        assertNotEquals(due, future)
        assertTrue(first.retainsWork(setOf(due), setOf(series), setOf(future), 150))
        assertTrue(first.retainsWork(setOf(future), setOf(series), setOf(future), 150))
        assertFalse(second.retainsWork(setOf(due), setOf(series), setOf(future), 150))
        assertFalse(first.retainsWork(setOf(due), emptySet(), setOf(future), 150))
        assertFalse(first.retainsWork(setOf(future), setOf(series), emptySet(), 150))
        assertFalse(first.retainsWork(setOf("vortx.newepisode.owner:$profile"), setOf(series), emptySet(), 150))
    }
}
