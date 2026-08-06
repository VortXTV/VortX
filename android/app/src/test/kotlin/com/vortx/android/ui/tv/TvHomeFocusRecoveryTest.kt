package com.vortx.android.ui.tv

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvHomeFocusRecoveryTest {
    @Test
    fun `later focus generation revokes pending recovery before focus request`() {
        val key = TvHomeFocusKey("continue", MediaType.MOVIE, "replacement")
        val recovery = TvHomeFocusRecovery(key, rowIndex = 3, itemIndex = 7)
        val pending = TvHomeFocusRecoveryLease(recovery, generation = 11L)

        assertTrue(pending.stillOwns(pending, currentGeneration = 11L, focused = key))
        assertFalse(pending.stillOwns(pending, currentGeneration = 12L, focused = key))
        assertFalse(
            pending.stillOwns(
                pending,
                currentGeneration = 11L,
                focused = TvHomeFocusKey("popular", MediaType.MOVIE, "manual-focus"),
            ),
        )
    }

    @Test
    fun `far off focused tile recovers to composed successor with exact scroll coordinates`() {
        val oldRows = (0 until 30).map { row ->
            Catalog(
                id = "row-$row",
                title = "Row $row",
                items = (0 until 60).map { column -> movie("$row-$column") },
            )
        }
        val focused = oldRows[22].items[47]
        val previous = initialTvHomeFocusState(oldRows).withFocused(oldRows[22].id, focused)
        val newRows = oldRows.mapIndexed { row, catalog ->
            if (row == 22) catalog.copy(items = catalog.items.filterNot { it.id == focused.id }) else catalog
        }

        val reconciled = reconcileTvHomeFocus(previous, newRows)
        val recovery = requireNotNull(reconciled.recovery)

        assertEquals(22, recovery.rowIndex)
        assertEquals(47, recovery.itemIndex)
        assertEquals("22-48", recovery.key.itemId)
        assertEquals(recovery.key, reconciled.state.focused)
    }

    @Test
    fun `duplicate title in another rail does not suppress same-row adjacent recovery`() {
        val a = movie("a")
        val focused = movie("shared")
        val c = movie("c")
        val duplicateInOtherRail = focused.copy(name = "Same title, different rail")
        val oldRows = listOf(
            Catalog("continue", "Continue Watching", listOf(a, focused, c)),
            Catalog("popular", "Popular", listOf(duplicateInOtherRail)),
        )
        val previous = initialTvHomeFocusState(oldRows).withFocused("continue", focused)
        val newRows = listOf(
            Catalog("continue", "Continue Watching", listOf(a, c)),
            Catalog("popular", "Popular", listOf(duplicateInOtherRail)),
        )

        val recovery = requireNotNull(reconcileTvHomeFocus(previous, newRows).recovery)

        assertEquals(TvHomeFocusKey("continue", MediaType.MOVIE, "c"), recovery.key)
        assertEquals(0, recovery.rowIndex)
        assertEquals(1, recovery.itemIndex)
    }

    @Test
    fun `removed last tile falls back to previous composed sibling`() {
        val first = movie("first")
        val last = movie("last")
        val oldRows = listOf(Catalog("continue", "Continue Watching", listOf(first, last)))
        val previous = initialTvHomeFocusState(oldRows).withFocused("continue", last)

        val recovery = reconcileTvHomeFocus(
            previous,
            listOf(Catalog("continue", "Continue Watching", listOf(first))),
        ).recovery

        assertEquals(TvHomeFocusKey("continue", MediaType.MOVIE, "first"), recovery?.key)
        assertEquals(0, recovery?.itemIndex)
    }

    private fun movie(id: String) = MetaItem(id = id, type = MediaType.MOVIE, name = id)
}
