package com.vortx.android.ui.library

import com.vortx.android.model.LibraryGenreFacts
import com.vortx.android.model.MetaItem

/** Local Library refinement only: no fetch, persisted preference or owner/fact cache. */
internal object LibraryGenrePolicy {
    class Choice private constructor(val id: String, val name: String) {
        override fun equals(other: Any?): Boolean = other is Choice && id == other.id
        override fun hashCode(): Int = id.hashCode()
        companion object {
            val All = Choice("all", "")
            val Unknown = Choice("unknown", "")
            fun genre(name: String) = Choice("genre:" + LibraryGenreFacts.key(name), name)
        }
    }
    fun choices(items: List<MetaItem>, selected: Choice): List<Choice> {
        val names = linkedMapOf<String, Choice>()
        items.forEach { item -> LibraryGenreFacts.normalized(item.genres).forEach { label ->
            val choice = Choice.genre(label); names.putIfAbsent(choice.id, choice)
        } }
        // Keep a selected empty genre visible and stably keyed until the user clears it.
        if (selected.id.startsWith("genre:")) names.putIfAbsent(selected.id, selected)
        return listOf(Choice.All, Choice.Unknown) + names.values.sortedBy(Choice::id)
    }
    /** Keep the existing smart-filter applicability anchored to the pre-genre set. A genre with no
     * watched matches must yield empty, never silently relax the selected Watched filter. */
    fun refine(items: List<MetaItem>, selected: Choice, smartSelected: Set<LibrarySmartFilter>): List<MetaItem> {
        val active = smartSelected intersect LibrarySmartFilter.applicable(items).toSet()
        return LibrarySmartFilter.apply(filter(items, selected), active)
    }
    fun filter(items: List<MetaItem>, selected: Choice): List<MetaItem> = when (selected) {
        Choice.All -> items
        Choice.Unknown -> items.filter { LibraryGenreFacts.normalized(it.genres).isEmpty() }
        else -> items.filter { item -> LibraryGenreFacts.normalized(item.genres)
            .any { "genre:" + LibraryGenreFacts.key(it) == selected.id } }
    }
}
