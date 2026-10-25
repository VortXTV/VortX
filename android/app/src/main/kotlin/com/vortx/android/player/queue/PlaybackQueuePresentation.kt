package com.vortx.android.player.queue

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MetaItem

/** Native parental admission is a presentation filter, never permission to rewrite saved queue data. */
internal object PlaybackQueuePresentation {
    fun project(
        source: PlaybackQueueState,
        owner: ContinueWatchingOwner,
        currentOwner: () -> ContinueWatchingOwner,
        admit: (List<MetaItem>, ContinueWatchingOwner) -> Result<List<MetaItem>>,
    ): PlaybackQueueState {
        fun unavailable() = source.copy(ready = false, entries = emptyList(),
            error = "Queue is unavailable for the current profile. Saved entries were not changed.")
        if (source.owner != owner || runCatching(currentOwner).getOrNull() != owner) return unavailable()
        val allowed = runCatching { admit(source.entries.map { it.item }, owner).getOrThrow() }.getOrNull()
            ?: return unavailable()
        if (runCatching(currentOwner).getOrNull() != owner) return unavailable()
        val originalTargets = source.entries.map { it.item.type to it.item.id }.toSet()
        val admittedTargets = allowed.map { it.type to it.id }.toSet()
        if (!originalTargets.containsAll(admittedTargets)) return unavailable()
        val entries = source.entries.filter { (it.item.type to it.item.id) in admittedTargets }
        return source.copy(entries = entries, error = source.error ?: if (entries.size != source.entries.size) {
            "Some saved queue entries are unavailable for this profile."
        } else null)
    }
}
