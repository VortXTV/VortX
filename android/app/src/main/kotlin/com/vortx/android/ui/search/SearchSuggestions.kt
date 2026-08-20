package com.vortx.android.ui.search

import com.vortx.android.model.CoreSearchSuggestion
import com.vortx.android.model.MetaItem
import java.text.Normalizer
import java.util.Locale

/// Ceiling on how many as-you-type suggestions the search field offers at once, matching Apple's
/// `CoreBridge.searchSuggestionTitles` cap so the two form factors surface the same short list.
private const val MAX_SEARCH_SUGGESTIONS = 10

private val COMBINING_MARKS = Regex("\\p{Mn}+")

/// Fold diacritics and lowercase so "amelie" matches "Amelie" and "Amelie". Mirrors Apple's
/// diacritic-insensitive comparison for search completion (folding + case-insensitive contains).
internal fun normalizeForSuggestion(value: String): String =
    Normalizer.normalize(value.trim(), Normalizer.Form.NFD)
        .replace(COMBINING_MARKS, "")
        .lowercase(Locale.ROOT)

/**
 * As-you-type search suggestions, in Apple's priority order (`CoreBridge.searchSuggestionTitles` /
 * SearchView `searchSuggestions`): Continue Watching first, then the engine's local-search suggestions
 * interleaved, then the current settled results, then the Home board. Titles are matched
 * diacritic-insensitively as a substring of the trimmed query, de-duplicated by their normalized form
 * (first occurrence wins, preserving the priority order), and capped at [MAX_SEARCH_SUGGESTIONS].
 *
 * The suggestion SURFACE opens from a SINGLE non-empty character, decoupled from the engine DISPATCH gate:
 * Apple's `CoreBridge.searchSuggestionTitles` guards only on a non-empty trimmed query (not the two-char
 * gate), so at one character the client-side sources (Continue Watching, the Home board, any already-settled
 * results) still offer completions before the first engine round-trip. The engine `local_search` Search is
 * separately gated at two characters by the repository, so [engineSuggestions] is simply empty below it.
 * [engineSuggestions] is the wired seam for [CoreSearchSuggestion]: when the engine exposes a local-search
 * index those titles interleave here; when it does not the list degrades to the client-side sources, never
 * spinning or erroring.
 */
internal fun searchSuggestionTitles(
    query: String,
    continueWatching: List<MetaItem> = emptyList(),
    engineSuggestions: List<CoreSearchSuggestion> = emptyList(),
    currentResults: List<MetaItem> = emptyList(),
    homeBoard: List<MetaItem> = emptyList(),
): List<String> {
    val needle = normalizeForSuggestion(query)
    if (needle.isEmpty()) return emptyList()

    val ordered = sequence {
        continueWatching.forEach { yield(it.name) }
        engineSuggestions.forEach { yield(it.name) }
        currentResults.forEach { yield(it.name) }
        homeBoard.forEach { yield(it.name) }
    }

    val seen = HashSet<String>()
    val output = mutableListOf<String>()
    for (rawTitle in ordered) {
        val title = rawTitle.trim()
        if (title.isEmpty()) continue
        val normalized = normalizeForSuggestion(title)
        if (!normalized.contains(needle)) continue
        if (!seen.add(normalized)) continue
        output += title
        if (output.size >= MAX_SEARCH_SUGGESTIONS) break
    }
    return output
}
