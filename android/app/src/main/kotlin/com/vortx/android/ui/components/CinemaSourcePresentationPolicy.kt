package com.vortx.android.ui.components

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource

/** An installed transport, not its possibly-aliased display name, owns jump/collapse state. */
internal fun cinemaSourceGroupKey(group: StreamGroup, index: Int): String =
    group.base.ifBlank { "ordinal:$index|${group.addon}" }

/** Keep a captured transport selection across arrival/reorder; never adopt a display-name alias. */
internal fun cinemaSourceSelectedGroupKey(groups: List<StreamGroup>, requestedKey: String?): String? =
    requestedKey?.takeIf { key -> groups.withIndex().any { cinemaSourceGroupKey(it.value, it.index) == key } }

internal data class CinemaSourceTab(val key: String, val addon: String, val count: Int)

/** Embedded + stream responses can share one real transport. Present one provider tab, in first-seen order. */
internal fun cinemaSourceTabs(groups: List<StreamGroup>): List<CinemaSourceTab> {
    val providers = linkedMapOf<String, CinemaSourceTab>()
    groups.forEachIndexed { index, group ->
        val key = cinemaSourceGroupKey(group, index)
        val previous = providers[key]
        providers[key] = CinemaSourceTab(key, previous?.addon ?: group.addon, (previous?.count ?: 0) + group.streams.size)
    }
    return providers.values.toList()
}

internal sealed interface CinemaSourceItem {
    data class Header(
        val key: String,
        val addon: String,
        val count: Int,
        val collapsed: Boolean,
        val firstProviderSection: Boolean,
    ) : CinemaSourceItem
    data class Row(val source: StreamSource, val addon: String, val groupKey: String) : CinemaSourceItem
}

/**
 * Keep every section in incoming/user order. Jumping exposes at most one extra 60-row window in its
 * target, so a late add-on is usable without building thousands of preceding rows. This is rendering
 * only: the caller retains the existing sort, quality/audio selection, ranking and resolve owners.
 */
internal fun cinemaSourceWindow(
    groups: List<StreamGroup>,
    collapsed: Set<String>,
    renderLimit: Int,
    jumpGroupKey: String?,
    sort: (List<StreamSource>) -> List<StreamSource> = { it },
): List<CinemaSourceItem> = buildList {
    var budget = renderLimit.coerceAtLeast(0)
    var selectedProviderRows = 0
    val seenProviders = HashSet<String>()
    groups.forEachIndexed { index, group ->
        val key = cinemaSourceGroupKey(group, index)
        val folded = key in collapsed
        add(CinemaSourceItem.Header(key, group.addon, group.streams.size, folded, seenProviders.add(key)))
        if (!folded) {
            val regular = minOf(group.streams.size, budget)
            budget -= regular
            // The nearby budget is for ONE provider, not one per embedded/stream response section.
            val targetRemaining = (CINEMA_SOURCE_JUMP_WINDOW - selectedProviderRows).coerceAtLeast(0)
            val count = if (key == jumpGroupKey) maxOf(regular, minOf(group.streams.size, targetRemaining)) else regular
            if (key == jumpGroupKey) selectedProviderRows += count
            if (count > 0) sort(group.streams).take(count).forEach { add(CinemaSourceItem.Row(it, group.addon, key)) }
        }
    }
}

private const val CINEMA_SOURCE_JUMP_WINDOW = 60
