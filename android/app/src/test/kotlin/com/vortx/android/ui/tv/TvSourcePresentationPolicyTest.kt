package com.vortx.android.ui.tv

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TvSourcePresentationPolicyTest {
    @Test
    fun `jump keeps user addon order and every neighboring section`() {
        val groups = listOf(group("Third in alphabet", 10), group("First in alphabet", 10), group("Middle", 10))
        val target = tvSourceGroupKey(groups[1], 1)

        val window = tvSourceWindow(groups, emptySet(), 40, target)

        assertEquals(groups.map { it.addon }, window.filterIsInstance<TvSourceItem.Header>().map { it.addon })
        assertEquals(30, window.filterIsInstance<TvSourceItem.Row>().size)
        assertEquals(target, (window[requireNotNull(tvSourceSectionIndex(window, target))] as TvSourceItem.Header).key)
    }

    @Test
    fun `jump to late addon opens a bounded target window without rendering preceding thousands`() {
        val groups = listOf(group("Large first addon", 5_000), group("Late addon", 2_000))
        val target = tvSourceGroupKey(groups[1], 1)

        val rows = tvSourceWindow(groups, emptySet(), 40, target).filterIsInstance<TvSourceItem.Row>()

        assertEquals(80, rows.size)
        assertEquals(40, rows.count { it.groupKey == target })
        assertEquals("Late addon-0", rows.first { it.groupKey == target }.source.id)
    }

    @Test
    fun `same addon display names have separate focus and collapse identities`() {
        val groups = listOf(group("Shared name", 3, "https://one.example"), group("Shared name", 3, "https://two.example"))
        val first = tvSourceGroupKey(groups[0], 0)
        val second = tvSourceGroupKey(groups[1], 1)
        assertNotEquals(first, second)

        val window = tvSourceWindow(groups, setOf(first), 40, second)

        assertTrue(window.filterIsInstance<TvSourceItem.Header>().first().collapsed)
        assertFalse(window.filterIsInstance<TvSourceItem.Header>().last().collapsed)
        assertEquals(3, window.filterIsInstance<TvSourceItem.Row>().size)
        assertTrue(window.filterIsInstance<TvSourceItem.Row>().all { it.groupKey == second })
    }

    @Test
    fun `installed addon identity survives reorder and asynchronous jump rejects manual focus`() {
        val first = group("First", 2, "https://one.example")
        val second = group("Second", 2, "https://two.example")
        assertEquals(tvSourceGroupKey(first, 0), tvSourceGroupKey(first, 1))
        val key = tvSourceGroupKey(second, 1)
        val lease = TvSourceJumpLease(key, requestRevision = 2, focusRevision = 7L)

        assertTrue(lease.stillOwns(2, 7L, listOf(key)))
        assertFalse(lease.stillOwns(2, 8L, listOf(key)))
        assertFalse(lease.stillOwns(3, 7L, listOf(key)))
        assertFalse(lease.stillOwns(2, 7L, emptyList()))
    }

    @Test
    fun `show more preserves source ranking and eventually exposes complete list`() {
        val groups = listOf(group("First", 50), group("Second", 50))
        val target = tvSourceGroupKey(groups[1], 1)
        val partial = tvSourceWindow(groups, emptySet(), 40, target).filterIsInstance<TvSourceItem.Row>()
        val complete = tvSourceWindow(groups, emptySet(), 120, target).filterIsInstance<TvSourceItem.Row>()

        assertEquals(80, partial.size)
        assertEquals(groups.flatMap { it.streams }.map { it.id }, complete.map { it.source.id })
    }

    @Test
    fun `empty target remains a reachable section and disappeared target has no focus index`() {
        val groups = listOf(group("First", 2), group("Empty", 0))
        val target = tvSourceGroupKey(groups[1], 1)
        val window = tvSourceWindow(groups, emptySet(), 40, target)

        assertEquals(3, tvSourceSectionIndex(window, target))
        assertNull(tvSourceSectionIndex(window, "removed"))
    }

    @Test
    fun `sort transforms source rows only and leaves section order intact`() {
        val groups = listOf(group("Z", 3), group("A", 3))
        val window = tvSourceWindow(groups, emptySet(), 40, null) { it.reversed() }

        assertEquals(listOf("Z", "A"), window.filterIsInstance<TvSourceItem.Header>().map { it.addon })
        assertEquals(listOf("Z-2", "Z-1", "Z-0", "A-2", "A-1", "A-0"), window.filterIsInstance<TvSourceItem.Row>().map { it.source.id })
    }

    private fun group(name: String, count: Int, base: String = "") = StreamGroup(
        addon = name,
        streams = (0 until count).map { StreamSource("$name-$it", name, "Source $it") },
        base = base,
    )
}
