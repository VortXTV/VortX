package com.vortx.android.foryou

import com.vortx.android.home.HomeRail
import com.vortx.android.model.Catalog

/** What Home shows for For You on the active profile. */
data class ForYouUi(
    val enabled: Boolean = false,
    val profileId: String? = null,
    val interests: ForYouInterests? = null,
    /** No interests (skipped or cleared): show the "Tell VortX what you like" invite instead of rows. */
    val showInvite: Boolean = false,
    /** Choices known and never decided on any device: the first-run picker may be offered. */
    val undecided: Boolean = false,
)

/** Home catalogs for the fetched rows. Ids route them to the For You and Smart Collections sections. */
internal fun forYouCatalogs(rows: ForYouRows, title: (ForYouTitle) -> String): List<Catalog> =
    rows.interest.map { row ->
        Catalog(id = "${HomeRail.FOR_YOU.catalogId}:${row.plan.id}", title = title(row.plan.title), items = row.items, readOnly = true)
    } + rows.collections.map { row ->
        Catalog(id = "${HomeRail.SMART_COLLECTIONS.catalogId}:${row.collection.id}", title = row.collection.name,
            items = row.items, readOnly = true)
    }

/** The reason a For You / smart collection catalog is on Home, from its id; null for any other rail. */
internal fun forYouReason(catalog: Catalog): ForYouReason? = when (HomeRail.forCatalog(catalog)) {
    HomeRail.FOR_YOU -> if (catalog.id.contains(":forYou.person.")) ForYouReason.PEOPLE else ForYouReason.INTERESTS
    HomeRail.SMART_COLLECTIONS -> ForYouReason.COLLECTION
    else -> null
}

/** English fallback for tests and previews; the app formats titles from string resources (ForYouText). */
fun englishForYouTitle(title: ForYouTitle): String = when (title) {
    is ForYouTitle.Person -> if (title.director) "From ${title.name}" else "With ${title.name}"
    is ForYouTitle.Extra -> when (title.extra) {
        ForYouExtra.ANIME -> "Anime"
        ForYouExtra.KDRAMA -> "Korean drama"
        ForYouExtra.BOLLYWOOD -> "Bollywood"
        ForYouExtra.BRITISH -> "British TV"
        ForYouExtra.STANDUP -> "Stand-up"
        ForYouExtra.TRUECRIME -> "True crime"
    }
    is ForYouTitle.Genre -> {
        val label = title.genre.key.replaceFirstChar { it.uppercase() }
        when (title.singleEra) {
            null -> "$label you'd rate highly"
            ForYouEra.RECENT -> "Recent ${title.genre.key} you'd rate highly"
            ForYouEra.CLASSICS -> "Classic ${title.genre.key}"
            ForYouEra.EIGHTIES_NINETIES -> "$label from the 80s and 90s"
            ForYouEra.TWO_THOUSANDS -> "$label from the 2000s"
        }
    }
}
