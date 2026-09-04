package com.vortx.android.ui.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem

/**
 * Pure phone-home hero decisions. Keeping candidate choice and timer ownership out of Compose makes a
 * catalog refresh unable to randomly reshuffle the billboard, and lets tests cover the race-sensitive
 * behavior without an Android runtime.
 */
internal object PhoneHeroPolicy {
    const val ROTATION_INTERVAL_MS = 12_000L
    private const val MAX_CANDIDATES = 12

    /** Catalog order is editorial order. The first occurrence of an item identity wins deterministically. */
    fun candidates(catalogs: List<Catalog>): List<MetaItem> {
        val seen = linkedSetOf<String>()
        return catalogs.asSequence()
            .flatMap { it.items.asSequence() }
            .filter { seen.add(identity(it)) }
            .take(MAX_CANDIDATES)
            .toList()
    }

    fun initialIndex(candidates: List<MetaItem>, previousIdentity: String?): Int =
        previousIdentity?.let { identity -> candidates.indexOfFirst { this.identity(it) == identity } }
            ?.takeIf { it >= 0 }
            ?: 0

    fun nextIndex(current: Int, size: Int, forward: Boolean): Int {
        if (size <= 1) return 0
        return if (forward) (current + 1) % size else (current - 1 + size) % size
    }

    fun shouldRotate(candidateCount: Int, reducedMotion: Boolean, interactionHeld: Boolean): Boolean =
        candidateCount > 1 && !reducedMotion && !interactionHeld

    /** A logo replaces the textual title only while its current URL has not failed to decode/load. */
    fun shouldShowLogo(url: String?, failedForUrl: String?): Boolean =
        !url.isNullOrBlank() && url != failedForUrl

    /** A detail result is only safe to apply if it belongs to the still-visible requested identity. */
    fun acceptsEnrichment(requestIdentity: String, visibleIdentity: String, requestGeneration: Long, visibleGeneration: Long): Boolean =
        requestIdentity == visibleIdentity && requestGeneration == visibleGeneration

    fun identity(item: MetaItem): String = "${item.type.id}:${item.id}"
}

/** Immutable request token used to reject a late repository result after the hero has moved on. */
internal data class PhoneHeroRequest(val identity: String, val generation: Long)
