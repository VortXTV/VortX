package com.vortx.android.foryou

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.UUID

/**
 * A profile's stated taste and its smart collections, shared with Apple byte for byte.
 *
 * Synced as host profile fields beside the watchlist: `forYou.interests` and one
 * `forYou.collection.<lowercase uuid>` per collection (null is a retained deletion), so two devices
 * editing different collections never overwrite each other and an older app keeps the fields
 * untouched. Decoding is lenient everywhere: a missing list is empty and an unknown `type` or `sort`
 * falls back to the default, so a newer app's value never makes a profile unreadable here.
 */
data class ForYouPerson(val id: Int, val name: String, val department: String? = null) {
    val isDirector: Boolean get() = department == "Directing" || department == "Writing"

    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).also { if (department != null) it.put("department", department) }

    companion object {
        fun fromJson(value: Any?): ForYouPerson? {
            val json = value as? JSONObject ?: return null
            val id = (json.opt("id") as? Number)?.toInt()?.takeIf { it > 0 } ?: return null
            val name = json.optString("name").takeIf { it.isNotBlank() } ?: return null
            return ForYouPerson(id, name, json.optString("department").takeIf { json.has("department") && it.isNotBlank() })
        }
    }
}

data class ForYouInterests(
    val genres: List<String> = emptyList(),
    val extras: List<String> = emptyList(),
    val eras: List<String> = emptyList(),
    val people: List<ForYouPerson> = emptyList(),
    /** True once the profile pressed Done or Skip, on any device: the picker is never offered again. */
    val decided: Boolean = false,
) {
    val genreChoices: List<ForYouGenre> get() = genres.mapNotNull(ForYouGenre::fromKey)
    val extraChoices: List<ForYouExtra> get() = extras.mapNotNull(ForYouExtra::fromKey)
    val eraChoices: List<ForYouEra> get() = eras.mapNotNull(ForYouEra::fromKey)
    val isEmpty: Boolean get() = genreChoices.isEmpty() && extraChoices.isEmpty() && people.isEmpty()

    fun toJson(): JSONObject = JSONObject().put("genres", JSONArray(genres)).put("extras", JSONArray(extras))
        .put("eras", JSONArray(eras)).put("people", JSONArray(people.map(ForYouPerson::toJson))).put("decided", decided)

    companion object {
        const val FIELD = "forYou.interests"

        fun fromJson(value: Any?): ForYouInterests? {
            val json = value as? JSONObject ?: return null
            return ForYouInterests(
                genres = json.strings("genres"), extras = json.strings("extras"), eras = json.strings("eras"),
                people = json.optJSONArray("people")?.let { array -> (0 until array.length()).mapNotNull { ForYouPerson.fromJson(array.opt(it)) } }.orEmpty(),
                decided = json.optBoolean("decided", false),
            )
        }
    }
}

data class SmartCollectionRules(
    val genres: List<String> = emptyList(),
    val extras: List<String> = emptyList(),
    val people: List<ForYouPerson> = emptyList(),
    val yearFrom: Int? = null,
    val yearTo: Int? = null,
    val minRating: Double? = null,
    val type: Kind = Kind.ALL,
    val hideWatched: Boolean = false,
    val sort: Sort = Sort.POPULAR,
) {
    enum class Kind(val key: String) { ALL("all"), MOVIE("movie"), SERIES("series") }
    enum class Sort(val key: String) { POPULAR("popular"), RATING("rating"), NEWEST("newest") }

    val genreChoices: List<ForYouGenre> get() = genres.mapNotNull(ForYouGenre::fromKey)
    val extraChoices: List<ForYouExtra> get() = extras.mapNotNull(ForYouExtra::fromKey)

    fun toJson(): JSONObject = JSONObject().put("genres", JSONArray(genres)).put("extras", JSONArray(extras))
        .put("people", JSONArray(people.map(ForYouPerson::toJson))).put("type", type.key)
        .put("hideWatched", hideWatched).put("sort", sort.key).also { json ->
            yearFrom?.let { json.put("yearFrom", it) }
            yearTo?.let { json.put("yearTo", it) }
            minRating?.let { json.put("minRating", it) }
        }

    companion object {
        fun fromJson(value: Any?): SmartCollectionRules {
            val json = value as? JSONObject ?: return SmartCollectionRules()
            return SmartCollectionRules(
                genres = json.strings("genres"), extras = json.strings("extras"),
                people = json.optJSONArray("people")?.let { array -> (0 until array.length()).mapNotNull { ForYouPerson.fromJson(array.opt(it)) } }.orEmpty(),
                yearFrom = json.int("yearFrom"), yearTo = json.int("yearTo"),
                minRating = (json.opt("minRating") as? Number)?.toDouble()?.takeIf { it.isFinite() },
                type = Kind.entries.firstOrNull { it.key == json.optString("type") } ?: Kind.ALL,
                hideWatched = json.optBoolean("hideWatched", false),
                sort = Sort.entries.firstOrNull { it.key == json.optString("sort") } ?: Sort.POPULAR,
            )
        }
    }
}

data class SmartCollection(
    val id: String,
    val name: String,
    val rules: SmartCollectionRules,
    /** Shown as a row on Home (true) or only in Library (false). */
    val home: Boolean,
    val createdAt: Double,
) {
    val field: String get() = FIELD_PREFIX + id

    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).put("rules", rules.toJson())
        .put("home", home).put("createdAt", createdAt)

    companion object {
        const val FIELD_PREFIX = "forYou.collection."

        fun make(name: String, rules: SmartCollectionRules, home: Boolean, nowMillis: Long = System.currentTimeMillis()) =
            SmartCollection(UUID.randomUUID().toString().lowercase(Locale.ROOT), name, rules, home, nowMillis / 1000.0)

        fun fromJson(value: Any?): SmartCollection? {
            val json = value as? JSONObject ?: return null
            val id = json.optString("id").takeIf { it.isNotBlank() } ?: return null
            val name = json.optString("name").takeIf { it.isNotBlank() } ?: return null
            return SmartCollection(id, name, SmartCollectionRules.fromJson(json.opt("rules")), json.optBoolean("home", false),
                (json.opt("createdAt") as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: 0.0)
        }
    }
}

/**
 * The `forYou.` host namespace. Every received host document is validated register by register and
 * one failure rejects the whole document, so this checks structure only (known field name, object or
 * null, bounded size). Content is read leniently where it is used. Mirrors Apple
 * `VortxNativeHostPreferences.validateForYouField`.
 */
object ForYouSync {
    const val PREFIX = "forYou."
    const val MAX_BYTES = 16_384

    fun isCollectionField(field: String): Boolean {
        if (!field.startsWith(SmartCollection.FIELD_PREFIX)) return false
        val id = field.removePrefix(SmartCollection.FIELD_PREFIX)
        return runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)
    }

    fun validate(field: String, value: Any?) {
        require(field == ForYouInterests.FIELD || isCollectionField(field)) { "Unknown For You field" }
        if (value == null || value == JSONObject.NULL) return
        require(value is JSONObject) { "For You value must be an object" }
        require(value.toString().toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "For You value is too large" }
    }

    /** The active profile's interests and live collections from its host `fields` object. */
    fun read(fields: JSONObject?): Pair<ForYouInterests?, List<SmartCollection>> {
        if (fields == null) return null to emptyList()
        val interests = ForYouInterests.fromJson(fields.optJSONObject(ForYouInterests.FIELD)?.opt("value"))
        val collections = fields.keys().asSequence().filter(::isCollectionField).mapNotNull { field ->
            SmartCollection.fromJson(fields.optJSONObject(field)?.opt("value"))?.takeIf { it.field == field }
        }.sortedWith(compareBy<SmartCollection> { it.createdAt }.thenBy { it.id }).toList()
        return interests to collections
    }
}

enum class ForYouGenre(val key: String, val movieGenreId: Int, val tvGenreId: Int?) {
    SCIFI("scifi", 878, 10765), THRILLER("thriller", 53, null), ACTION("action", 28, 10759), COMEDY("comedy", 35, 35),
    DRAMA("drama", 18, 18), HORROR("horror", 27, null), MYSTERY("mystery", 9648, 9648), ANIMATION("animation", 16, 16),
    CRIME("crime", 80, 80), FANTASY("fantasy", 14, 10765), ROMANCE("romance", 10749, null), DOCUMENTARY("documentary", 99, 99),
    ADVENTURE("adventure", 12, 10759), FAMILY("family", 10751, 10751), WAR("war", 10752, 10768), WESTERN("western", 37, 37),
    HISTORY("history", 36, null), MUSIC("music", 10402, null);

    companion object {
        /** The twelve offered in the first-run picker; the rest appear in the smart collection builder. */
        val PICKER = listOf(SCIFI, THRILLER, ACTION, COMEDY, DRAMA, HORROR, MYSTERY, ANIMATION, CRIME, FANTASY, ROMANCE, DOCUMENTARY)
        fun fromKey(key: String): ForYouGenre? = entries.firstOrNull { it.key == key }
    }
}

/** "Also into" scenes. TMDB keyword ids verified against /search/keyword: 9716 stand-up, 33722 true crime. */
enum class ForYouExtra(val key: String) {
    ANIME("anime"), KDRAMA("kdrama"), BOLLYWOOD("bollywood"), BRITISH("british"), STANDUP("standup"), TRUECRIME("truecrime");

    /** Discover parameters per media; null means that media has no meaningful equivalent. */
    fun parameters(series: Boolean): String? = when (this) {
        ANIME -> "with_genres=16&with_original_language=ja"
        KDRAMA -> if (series) "with_original_language=ko" else null
        BOLLYWOOD -> if (series) null else "with_original_language=hi"
        BRITISH -> if (series) "with_origin_country=GB" else null
        STANDUP -> "with_keywords=9716"
        TRUECRIME -> "with_keywords=33722"
    }

    companion object { fun fromKey(key: String): ForYouExtra? = entries.firstOrNull { it.key == key } }
}

enum class ForYouEra(val key: String) {
    CLASSICS("classics"), EIGHTIES_NINETIES("80s90s"), TWO_THOUSANDS("2000s"), RECENT("recent");

    /** Inclusive release-year bounds; null is open. "Recent" is the last five years. */
    fun years(currentYear: Int): Pair<Int?, Int?> = when (this) {
        CLASSICS -> null to 1979
        EIGHTIES_NINETIES -> 1980 to 1999
        TWO_THOUSANDS -> 2000 to 2009
        RECENT -> (currentYear - 4) to null
    }

    companion object {
        fun fromKey(key: String): ForYouEra? = entries.firstOrNull { it.key == key }
        fun span(eras: List<ForYouEra>, currentYear: Int): Pair<Int?, Int?> {
            if (eras.isEmpty()) return null to null
            val bounds = eras.map { it.years(currentYear) }
            val from = if (bounds.any { it.first == null }) null else bounds.mapNotNull { it.first }.minOrNull()
            val to = if (bounds.any { it.second == null }) null else bounds.mapNotNull { it.second }.maxOrNull()
            return from to to
        }
    }
}

private fun JSONObject.strings(key: String): List<String> =
    optJSONArray(key)?.let { array -> (0 until array.length()).mapNotNull { array.opt(it) as? String } }.orEmpty()

private fun JSONObject.int(key: String): Int? = (opt(key) as? Number)?.let { number ->
    number.toDouble().takeIf { it.isFinite() && it == Math.floor(it) }?.toInt()
}
