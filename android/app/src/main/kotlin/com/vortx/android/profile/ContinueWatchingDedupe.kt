package com.vortx.android.profile

import java.util.Locale

/**
 * Provider-backed, order-stable Continue Watching identity fold.
 *
 * Display ids and independently-carried played-video aliases reduce to canonical title ids. Mutable names and
 * poster URLs never participate. Alias overlap is transitive, and an explicit removal competes by the same
 * freshness clock as live progress, so stale aliases cannot resurrect a dismissed title.
 */
internal object ContinueWatchingDedupe {
    data class Identity(
        val id: String,
        val type: String,
        val aliases: List<String> = emptyList(),
        val freshness: Double? = null,
        val hasValidProgress: Boolean = true,
        val removed: Boolean = false,
    )

    private data class Candidate<T>(
        val item: T,
        val identity: Identity,
        val keys: Set<String>,
        val sourceIndex: Int,
    )

    private data class Group<T>(
        val candidates: MutableList<Candidate<T>>,
        val keys: MutableSet<String>,
        val firstIndex: Int,
    )

    fun <T> fold(items: List<T>, identity: (T) -> Identity): List<T> {
        val groups = mutableListOf<Group<T>>()
        items.forEachIndexed { sourceIndex, item ->
            val value = identity(item)
            val keys = identityKeys(value)
            if (keys.isEmpty()) return@forEachIndexed
            val candidate = Candidate(item, value, keys, sourceIndex)
            val matches = groups.indices.filter { index -> groups[index].keys.any(keys::contains) }
            if (matches.isEmpty()) {
                groups += Group(mutableListOf(candidate), keys.toMutableSet(), sourceIndex)
                return@forEachIndexed
            }

            val target = matches.first()
            groups[target].candidates += candidate
            groups[target].keys += keys
            // A late bridge can join components that appeared under separate providers earlier.
            for (index in matches.drop(1).asReversed()) {
                groups[target].candidates += groups[index].candidates
                groups[target].keys += groups[index].keys
                groups.removeAt(index)
            }
        }

        return groups.sortedBy { it.firstIndex }.mapNotNull { group ->
            val eligible = group.candidates.filter { it.identity.removed || it.identity.hasValidProgress }
            // Preserve fail-soft engine membership when every row is sparse; a valid row wins when present.
            var winner = eligible.firstOrNull() ?: group.candidates.firstOrNull() ?: return@mapNotNull null
            for (candidate in eligible.drop(1)) {
                if (preferred(candidate, winner)) winner = candidate
            }
            winner.item.takeUnless { winner.identity.removed }
        }
    }

    private fun <T> preferred(candidate: Candidate<T>, incumbent: Candidate<T>): Boolean {
        val candidateFreshness = candidate.identity.freshness?.takeIf(Double::isFinite)
        val incumbentFreshness = incumbent.identity.freshness?.takeIf(Double::isFinite)
        if (candidateFreshness != null && incumbentFreshness != null && candidateFreshness != incumbentFreshness) {
            return candidateFreshness > incumbentFreshness
        }
        if (candidateFreshness != null && incumbentFreshness == null) return true
        if (candidateFreshness == null && incumbentFreshness != null) return false
        if (candidateFreshness == null && incumbentFreshness == null) {
            return candidate.sourceIndex < incumbent.sourceIndex
        }
        if (candidate.identity.removed != incumbent.identity.removed) return candidate.identity.removed
        return candidate.sourceIndex < incumbent.sourceIndex
    }

    private fun identityKeys(identity: Identity): Set<String> {
        val type = normalizeType(identity.type)
        if (type.isEmpty()) return emptySet()
        return (listOf(identity.id) + identity.aliases).mapNotNull { raw ->
            canonicalProviderId(raw, type)?.let { "$type\u001f$it" }
        }.toSet()
    }

    private fun normalizeType(value: String): String = when (val type = value.trim().lowercase(Locale.ROOT)) {
        "show", "tv", "series" -> "series"
        "film", "movie" -> "movie"
        else -> type
    }

    private fun canonicalProviderId(value: String, type: String): String? {
        val raw = value.trim().lowercase(Locale.ROOT)
        if (raw.isEmpty()) return null
        val retainsEpisodeSuffix = type != "series" && EPISODE_SUFFIX.containsMatchIn(raw)
        if (IMDB.matches(raw)) {
            if (retainsEpisodeSuffix) return raw
            return "imdb:${raw.removePrefix("imdb:").substringBefore(":")}"
        }
        val tmdb = TMDB.matchEntire(raw)
        if (tmdb != null) {
            if (retainsEpisodeSuffix) return raw
            val explicit = tmdb.groupValues[1].ifEmpty { null }
            val namespace = when (explicit) {
                "tv", "series", "show" -> "series"
                "movie" -> "movie"
                else -> type
            }
            return "tmdb:$namespace:${tmdb.groupValues[2]}"
        }
        val anime = ANIME.matchEntire(raw)
        if (anime != null) {
            if (retainsEpisodeSuffix) return raw
            return "${anime.groupValues[1]}:${anime.groupValues[2]}"
        }
        return raw
    }

    private val EPISODE_SUFFIX = Regex(":[0-9]{1,4}:[0-9]{1,4}$")
    private val IMDB = Regex("^(?:imdb:)?tt[0-9]{1,10}(?::[0-9]{1,4}:[0-9]{1,4})?$")
    private val TMDB = Regex("^tmdb:(?:(movie|tv|series|show):)?([0-9]{1,10})(?::[0-9]{1,4}:[0-9]{1,4})?$")
    private val ANIME = Regex("^(kitsu|anilist|mal|anidb):([0-9]{1,10})(?::[0-9]{1,4}:[0-9]{1,4})?$")
}
