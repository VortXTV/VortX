package com.vortx.android.foryou

import java.time.LocalDate
import java.time.ZoneOffset

/** Why a For You row is on Home; the UI turns this into the row's eyebrow. */
enum class ForYouReason { INTERESTS, PEOPLE, COLLECTION }

/** A row title the UI formats with string resources, so it localizes like the rest of Home. */
sealed interface ForYouTitle {
    data class Genre(val genre: ForYouGenre, val singleEra: ForYouEra?) : ForYouTitle
    data class Person(val name: String, val director: Boolean) : ForYouTitle
    data class Extra(val extra: ForYouExtra) : ForYouTitle
}

sealed interface ForYouSource {
    /** TMDB /discover parameters per media (after the base path); null skips that media. */
    data class Discover(val movie: String?, val tv: String?) : ForYouSource
    /** A followed person's best-known work. */
    data class Person(val id: Int) : ForYouSource
}

data class ForYouRowPlan(val id: String, val reason: ForYouReason, val title: ForYouTitle, val source: ForYouSource)

/**
 * Interests and smart collection rules to TMDB discover queries and row plans; a line-for-line port of
 * Apple `ForYouQuery`, producing the same query strings so both platforms fill the same rows.
 *
 * Every query is bounded to titles already released (`lte` today): TMDB lists announced titles with
 * hype ratings. Interest rows are popular titles above a rating bar (ranking by rating alone surfaced
 * obscure picks, and low vote floors let little-known adult-adjacent titles into popular anime results,
 * checked live 2026-10-13). A pipe is written percent-encoded (`%7C`) like Apple.
 */
object ForYouQuery {
    const val MAX_ROWS = 6
    private const val PER_KIND = 2

    fun plan(interests: ForYouInterests, today: LocalDate = LocalDate.now(ZoneOffset.UTC)): List<ForYouRowPlan> {
        val eras = interests.eraChoices
        val genres = interests.genreChoices.take(PER_KIND).map { genre ->
            ForYouRowPlan("forYou.genre.${genre.key}", ForYouReason.INTERESTS,
                ForYouTitle.Genre(genre, eras.singleOrNull()), genreSource(genre, eras, today))
        }
        val people = interests.people.take(PER_KIND).map { person ->
            ForYouRowPlan("forYou.person.${person.id}", ForYouReason.PEOPLE,
                ForYouTitle.Person(person.name, person.isDirector), ForYouSource.Person(person.id))
        }
        val extras = interests.extraChoices.take(PER_KIND).map { extra ->
            ForYouRowPlan("forYou.extra.${extra.key}", ForYouReason.INTERESTS, ForYouTitle.Extra(extra), extraSource(extra, eras, today))
        }
        // Round-robin so one kind of interest never pushes the others below the fold.
        val rows = mutableListOf<ForYouRowPlan>()
        for (index in 0 until PER_KIND) {
            for (kind in listOf(genres, people, extras)) if (index < kind.size) rows += kind[index]
        }
        return rows.take(MAX_ROWS)
    }

    fun genreSource(genre: ForYouGenre, eras: List<ForYouEra>, today: LocalDate): ForYouSource.Discover {
        val (from, to) = ForYouEra.span(eras, today.year)
        fun query(series: Boolean): String? {
            val id = if (series) genre.tvGenreId else genre.movieGenreId
            id ?: return null
            return join(listOf("with_genres=$id", "sort_by=popularity.desc", "vote_average.gte=${if (series) "7.5" else "7.0"}",
                "vote_count.gte=${if (series) 200 else 300}") + dateBounds(series, from, to, today))
        }
        return ForYouSource.Discover(query(false), query(true))
    }

    fun extraSource(extra: ForYouExtra, eras: List<ForYouEra>, today: LocalDate): ForYouSource.Discover {
        val (from, to) = ForYouEra.span(eras, today.year)
        fun query(series: Boolean): String? {
            val parameters = extra.parameters(series) ?: return null
            return join(listOf(parameters, "sort_by=popularity.desc", "vote_average.gte=7.0", "vote_count.gte=${if (series) 80 else 100}") +
                dateBounds(series, from, to, today))
        }
        return ForYouSource.Discover(query(false), query(true))
    }

    /**
     * Rules to one discover query per media. TMDB's TV discover has no people filter, so a rule naming
     * people searches movies only; only the first scene applies (scenes set conflicting language or
     * keyword parameters); a scene that sets its own genre replaces the genre rule.
     */
    fun collectionSource(rules: SmartCollectionRules, today: LocalDate = LocalDate.now(ZoneOffset.UTC)): ForYouSource.Discover {
        fun query(series: Boolean): String? {
            if ((rules.type == SmartCollectionRules.Kind.MOVIE && series) || (rules.type == SmartCollectionRules.Kind.SERIES && !series)) return null
            if (series && rules.people.isNotEmpty()) return null
            val parts = mutableListOf<String>()
            var sceneSetsGenre = false
            rules.extraChoices.firstOrNull()?.let { extra ->
                val parameters = extra.parameters(series) ?: return null
                parts += parameters
                sceneSetsGenre = "with_genres=" in parameters
            }
            if (rules.genreChoices.isNotEmpty() && !sceneSetsGenre) {
                val ids = rules.genreChoices.mapNotNull { if (series) it.tvGenreId else it.movieGenreId }.distinct()
                if (ids.isEmpty()) return null
                parts += "with_genres=" + ids.joinToString("%7C")
            }
            if (rules.people.isNotEmpty()) parts += "with_people=" + rules.people.joinToString("%7C") { it.id.toString() }
            var minimumVotes = when (rules.sort) {
                SmartCollectionRules.Sort.POPULAR -> { parts += "sort_by=popularity.desc"; if (series) 50 else 100 }
                SmartCollectionRules.Sort.RATING -> { parts += "sort_by=vote_average.desc"; if (series) 150 else 300 }
                SmartCollectionRules.Sort.NEWEST -> {
                    parts += "sort_by=${if (series) "first_air_date" else "primary_release_date"}.desc"; if (series) 10 else 20
                }
            }
            rules.minRating?.takeIf { it > 0 }?.let { rating ->
                parts += "vote_average.gte=${String.format(java.util.Locale.ROOT, "%.1f", rating.coerceIn(0.0, 10.0))}"
                minimumVotes = maxOf(minimumVotes, 50)
            }
            parts += "vote_count.gte=$minimumVotes"
            return join(parts + dateBounds(series, rules.yearFrom, rules.yearTo, today))
        }
        return ForYouSource.Discover(query(false), query(true))
    }

    /** Release window: inclusive years, never past today. */
    fun dateBounds(series: Boolean, from: Int?, to: Int?, today: LocalDate): List<String> {
        val field = if (series) "first_air_date" else "primary_release_date"
        val day = today.toString()
        val end = to?.let { "%04d-12-31".format(java.util.Locale.ROOT, it) }
        return listOfNotNull(
            from?.let { "$field.gte=${"%04d".format(java.util.Locale.ROOT, it)}-01-01" },
            "$field.lte=${if (end != null && end < day) end else day}",
        )
    }

    private fun join(parts: List<String>): String = parts.joinToString("&")
}
