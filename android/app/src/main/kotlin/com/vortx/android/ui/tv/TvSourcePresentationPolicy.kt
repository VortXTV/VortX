package com.vortx.android.ui.tv

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource

/** Render identities are distinct even when two installed add-ons share a display name. */
internal fun tvSourceGroupKey(group: StreamGroup, index: Int): String =
    group.base.ifBlank { "$index|${group.addon}" }

/** A manual D-pad move, newer tab click or removed add-on revokes an asynchronous focus request. */
internal data class TvSourceJumpLease(val groupKey: String?, val requestRevision: Int, val focusRevision: Long) {
    fun stillOwns(currentRequestRevision: Int, currentFocusRevision: Long, groupKeys: List<String>): Boolean =
        requestRevision == currentRequestRevision && focusRevision == currentFocusRevision &&
            (groupKey == null || groupKey in groupKeys)
}

internal sealed interface TvSourceItem {
    data class Header(val key: String, val addon: String, val count: Int, val collapsed: Boolean) : TvSourceItem
    data class Row(val source: StreamSource, val addon: String, val groupKey: String) : TvSourceItem
}

/**
 * Keep the incoming user order and a global row budget. A jump may expose one additional small window in
 * its target section; reaching a late add-on therefore never requires building every preceding source.
 */
internal fun tvSourceWindow(
    groups: List<StreamGroup>,
    collapsed: Set<String>,
    renderLimit: Int,
    jumpGroupKey: String?,
    sort: (List<StreamSource>) -> List<StreamSource> = { it },
): List<TvSourceItem> = buildList {
    var budget = renderLimit.coerceAtLeast(0)
    groups.forEachIndexed { index, group ->
        val key = tvSourceGroupKey(group, index)
        val folded = key in collapsed
        add(TvSourceItem.Header(key, group.addon, group.streams.size, folded))
        if (!folded) {
            val regular = minOf(group.streams.size, budget)
            budget -= regular
            val count = if (key == jumpGroupKey) maxOf(regular, minOf(group.streams.size, TV_SOURCE_JUMP_WINDOW)) else regular
            if (count > 0) sort(group.streams).take(count).forEach { add(TvSourceItem.Row(it, group.addon, key)) }
        }
    }
}

internal fun tvSourceSectionIndex(items: List<TvSourceItem>, groupKey: String): Int? =
    items.indexOfFirst { it is TvSourceItem.Header && it.key == groupKey }.takeIf { it >= 0 }

private const val TV_SOURCE_JUMP_WINDOW = 40
