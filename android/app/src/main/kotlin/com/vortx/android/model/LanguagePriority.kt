package com.vortx.android.model

/**
 * Pure ordering rules for audio and subtitle language preferences.
 *
 * The persisted wire format already supports an arbitrary comma-separated list. Keeping these
 * mutations framework-free lets the settings UI expose that full model without truncating an
 * existing list to a primary/fallback pair.
 */
object LanguagePriority {
    fun normalized(languages: List<String>): List<String> {
        val seen = LinkedHashSet<String>()
        languages.forEach { raw ->
            raw.trim().lowercase().takeIf { it.isNotEmpty() }?.let(seen::add)
        }
        return seen.toList().ifEmpty { listOf("en") }
    }

    fun add(languages: List<String>, language: String): List<String> =
        normalized(languages + language)

    fun remove(languages: List<String>, index: Int): List<String> {
        val current = normalized(languages)
        if (current.size == 1 || index !in current.indices) return current
        return current.toMutableList().also { it.removeAt(index) }
    }

    fun move(languages: List<String>, index: Int, delta: Int): List<String> {
        val current = normalized(languages)
        val destination = index + delta
        if (index !in current.indices || destination !in current.indices) return current
        return current.toMutableList().also {
            val moved = it.removeAt(index)
            it.add(destination, moved)
        }
    }
}
