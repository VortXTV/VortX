package com.vortx.android.foryou

import android.content.Context
import com.vortx.android.R

/** Localized For You labels and row titles from string resources (Apple formats the same strings). */
class ForYouText(context: Context) {
    private val resources = context.applicationContext.resources
    private fun s(id: Int, vararg args: Any): String = resources.getString(id, *args)

    fun title(title: ForYouTitle): String = when (title) {
        is ForYouTitle.Person -> s(if (title.director) R.string.for_you_title_from else R.string.for_you_title_with, title.name)
        is ForYouTitle.Extra -> extra(title.extra)
        is ForYouTitle.Genre -> when (title.singleEra) {
            null -> s(R.string.for_you_title_rated, genreRow(title.genre))
            ForYouEra.RECENT -> s(R.string.for_you_title_recent, genrePhrase(title.genre))
            ForYouEra.CLASSICS -> s(R.string.for_you_title_classic, genrePhrase(title.genre))
            ForYouEra.EIGHTIES_NINETIES -> s(R.string.for_you_title_eighties_nineties, genreRow(title.genre))
            ForYouEra.TWO_THOUSANDS -> s(R.string.for_you_title_two_thousands, genreRow(title.genre))
        }
    }

    fun reason(reason: ForYouReason): String = s(when (reason) {
        ForYouReason.INTERESTS -> R.string.for_you_eyebrow_interests
        ForYouReason.PEOPLE -> R.string.for_you_eyebrow_people
        ForYouReason.COLLECTION -> R.string.for_you_eyebrow_collection
    })

    fun extra(extra: ForYouExtra): String = s(when (extra) {
        ForYouExtra.ANIME -> R.string.for_you_extra_anime
        ForYouExtra.KDRAMA -> R.string.for_you_extra_kdrama
        ForYouExtra.BOLLYWOOD -> R.string.for_you_extra_bollywood
        ForYouExtra.BRITISH -> R.string.for_you_extra_british
        ForYouExtra.STANDUP -> R.string.for_you_extra_standup
        ForYouExtra.TRUECRIME -> R.string.for_you_extra_truecrime
    })

    fun era(era: ForYouEra): String = s(when (era) {
        ForYouEra.CLASSICS -> R.string.for_you_era_classics
        ForYouEra.EIGHTIES_NINETIES -> R.string.for_you_era_eighties_nineties
        ForYouEra.TWO_THOUSANDS -> R.string.for_you_era_two_thousands
        ForYouEra.RECENT -> R.string.for_you_era_recent
    })

    fun genre(genre: ForYouGenre): String = s(genreIds(genre).first)
    private fun genreRow(genre: ForYouGenre): String = s(genreIds(genre).second)
    private fun genrePhrase(genre: ForYouGenre): String = s(genreIds(genre).third)

    /** One line describing a collection's rules, shown under its name. */
    fun summary(rules: SmartCollectionRules): String {
        val parts = mutableListOf<String>()
        rules.genreChoices.map(::genre).takeIf { it.isNotEmpty() }?.let { parts += it.joinToString(s(R.string.smart_collections_summary_or)) }
        rules.extraChoices.firstOrNull()?.let { parts += extra(it) }
        if (rules.people.isNotEmpty()) parts += s(R.string.smart_collections_summary_with, rules.people.joinToString(", ") { it.name })
        when {
            rules.yearFrom != null && rules.yearTo == null -> parts += s(R.string.smart_collections_summary_from_now, rules.yearFrom.toString())
            rules.yearFrom == null && rules.yearTo != null -> parts += s(R.string.smart_collections_summary_up_to, rules.yearTo.toString())
            rules.yearFrom != null && rules.yearTo != null ->
                parts += s(R.string.smart_collections_summary_range, rules.yearFrom.toString(), rules.yearTo.toString())
        }
        rules.minRating?.takeIf { it > 0 }?.let { parts += s(R.string.smart_collections_summary_rated, "%.0f".format(it)) }
        when (rules.type) {
            SmartCollectionRules.Kind.ALL -> Unit
            SmartCollectionRules.Kind.MOVIE -> parts += s(R.string.smart_collections_type_movies)
            SmartCollectionRules.Kind.SERIES -> parts += s(R.string.smart_collections_type_shows)
        }
        if (rules.hideWatched) parts += s(R.string.smart_collections_summary_unwatched)
        return if (parts.isEmpty()) s(R.string.smart_collections_summary_popular) else parts.joinToString(" · ")
    }

    private fun genreIds(genre: ForYouGenre): Triple<Int, Int, Int> = when (genre) {
        ForYouGenre.SCIFI -> Triple(R.string.for_you_genre_scifi, R.string.for_you_genre_row_scifi, R.string.for_you_genre_phrase_scifi)
        ForYouGenre.THRILLER -> Triple(R.string.for_you_genre_thriller, R.string.for_you_genre_row_thriller, R.string.for_you_genre_phrase_thriller)
        ForYouGenre.ACTION -> Triple(R.string.for_you_genre_action, R.string.for_you_genre_row_action, R.string.for_you_genre_phrase_action)
        ForYouGenre.COMEDY -> Triple(R.string.for_you_genre_comedy, R.string.for_you_genre_row_comedy, R.string.for_you_genre_phrase_comedy)
        ForYouGenre.DRAMA -> Triple(R.string.for_you_genre_drama, R.string.for_you_genre_row_drama, R.string.for_you_genre_phrase_drama)
        ForYouGenre.HORROR -> Triple(R.string.for_you_genre_horror, R.string.for_you_genre_row_horror, R.string.for_you_genre_phrase_horror)
        ForYouGenre.MYSTERY -> Triple(R.string.for_you_genre_mystery, R.string.for_you_genre_row_mystery, R.string.for_you_genre_phrase_mystery)
        ForYouGenre.ANIMATION -> Triple(R.string.for_you_genre_animation, R.string.for_you_genre_row_animation, R.string.for_you_genre_phrase_animation)
        ForYouGenre.CRIME -> Triple(R.string.for_you_genre_crime, R.string.for_you_genre_row_crime, R.string.for_you_genre_phrase_crime)
        ForYouGenre.FANTASY -> Triple(R.string.for_you_genre_fantasy, R.string.for_you_genre_row_fantasy, R.string.for_you_genre_phrase_fantasy)
        ForYouGenre.ROMANCE -> Triple(R.string.for_you_genre_romance, R.string.for_you_genre_row_romance, R.string.for_you_genre_phrase_romance)
        ForYouGenre.DOCUMENTARY -> Triple(R.string.for_you_genre_documentary, R.string.for_you_genre_row_documentary, R.string.for_you_genre_phrase_documentary)
        ForYouGenre.ADVENTURE -> Triple(R.string.for_you_genre_adventure, R.string.for_you_genre_row_adventure, R.string.for_you_genre_phrase_adventure)
        ForYouGenre.FAMILY -> Triple(R.string.for_you_genre_family, R.string.for_you_genre_row_family, R.string.for_you_genre_phrase_family)
        ForYouGenre.WAR -> Triple(R.string.for_you_genre_war, R.string.for_you_genre_row_war, R.string.for_you_genre_phrase_war)
        ForYouGenre.WESTERN -> Triple(R.string.for_you_genre_western, R.string.for_you_genre_row_western, R.string.for_you_genre_phrase_western)
        ForYouGenre.HISTORY -> Triple(R.string.for_you_genre_history, R.string.for_you_genre_row_history, R.string.for_you_genre_phrase_history)
        ForYouGenre.MUSIC -> Triple(R.string.for_you_genre_music, R.string.for_you_genre_row_music, R.string.for_you_genre_phrase_music)
    }
}
