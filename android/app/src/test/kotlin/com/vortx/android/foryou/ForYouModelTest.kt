package com.vortx.android.foryou

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/** The same cases and expected TMDB queries as Apple `app/Tests/ForYouModelTests.swift`. */
class ForYouModelTest {
    private val today = LocalDate.of(2026, 10, 13)
    private fun throws(block: () -> Unit) = runCatching(block).isFailure

    @Test fun `lenient decoding keeps unknown keys and falls back on unknown values`() {
        assertEquals(ForYouInterests(), ForYouInterests.fromJson(JSONObject("{}")))
        val partial = ForYouInterests.fromJson(JSONObject("""{"genres":["scifi","laterGenre"],"eras":["recent"],"decided":true,"futureKey":1}""")) !!
        assertEquals(listOf(ForYouGenre.SCIFI), partial.genreChoices)
        assertEquals(listOf("scifi", "laterGenre"), partial.genres)
        assertTrue(partial.decided && partial.eraChoices == listOf(ForYouEra.RECENT))
        val loose = SmartCollection.fromJson(JSONObject(
            """{"id":"0f8fad5b-d9cb-469f-a165-70867728950e","name":"Later","rules":{"type":"documentaryOnly","sort":"trending","genres":["drama"]}}"""))!!
        assertEquals(SmartCollectionRules.Kind.ALL, loose.rules.type)
        assertEquals(SmartCollectionRules.Sort.POPULAR, loose.rules.sort)
        assertFalse(loose.home); assertEquals(0.0, loose.createdAt, 0.0)
        val bare = SmartCollection.fromJson(JSONObject("""{"id":"0f8fad5b-d9cb-469f-a165-70867728950e","name":"Bare"}"""))!!
        assertEquals(SmartCollectionRules(), bare.rules)
        val made = SmartCollection.make("Villeneuve night", SmartCollectionRules(), true)
        assertEquals(made, SmartCollection.fromJson(made.toJson()))
        assertTrue(ForYouSync.isCollectionField(made.field))
    }

    @Test fun `apple encoded interests and collections decode here`() {
        val apple = JSONObject("""{"genres":["scifi"],"extras":["kdrama"],"eras":["80s90s"],"decided":true,
            "people":[{"id":137427,"name":"Denis Villeneuve","department":"Directing"},{"id":1373737,"name":"Florence Pugh"}]}""")
        val interests = ForYouInterests.fromJson(apple)!!
        assertEquals(listOf(ForYouExtra.KDRAMA), interests.extraChoices)
        assertEquals(listOf(ForYouEra.EIGHTIES_NINETIES), interests.eraChoices)
        assertTrue(interests.people[0].isDirector); assertNull(interests.people[1].department)
        val rules = SmartCollectionRules.fromJson(JSONObject("""{"genres":["scifi"],"yearFrom":2010,"minRating":7,"type":"movie","sort":"rating","hideWatched":true}"""))
        assertEquals(2010, rules.yearFrom); assertEquals(7.0, rules.minRating!!, 0.0)
        assertEquals(SmartCollectionRules.Kind.MOVIE, rules.type); assertEquals(SmartCollectionRules.Sort.RATING, rules.sort)
        assertEquals(rules, SmartCollectionRules.fromJson(rules.toJson()))
    }

    @Test fun `validation is structural only`() {
        val made = SmartCollection.make("x", SmartCollectionRules(), false)
        assertFalse(throws { ForYouSync.validate(ForYouInterests.FIELD, JSONObject.NULL) })
        assertFalse(throws { ForYouSync.validate(ForYouInterests.FIELD, JSONObject("""{"genres":7,"newer":{"x":[1]}}""")) })
        assertTrue(throws { ForYouSync.validate(ForYouInterests.FIELD, org.json.JSONArray()) })
        assertTrue(throws { ForYouSync.validate("forYou.other", JSONObject.NULL) })
        assertTrue(throws { ForYouSync.validate("forYou.collection.0F8FAD5B-D9CB-469F-A165-70867728950E", JSONObject.NULL) })
        assertTrue(throws { ForYouSync.validate("forYou.collection.not-a-uuid", JSONObject.NULL) })
        assertTrue(throws { ForYouSync.validate(made.field, JSONObject().put("name", "x".repeat(ForYouSync.MAX_BYTES))) })
    }

    @Test fun `host fields read interests and live collections only`() {
        val made = SmartCollection.make("Mine", SmartCollectionRules(), true)
        val fields = JSONObject()
            .put("forYou.interests", JSONObject().put("clock", 3).put("actor", "a").put("value", JSONObject("""{"genres":["thriller"],"decided":true}""")))
            .put(made.field, JSONObject().put("clock", 4).put("actor", "a").put("value", made.toJson()))
            .put("forYou.collection.1b4e28ba-2fa1-41d2-883f-0016d3cca427", JSONObject().put("clock", 5).put("actor", "a").put("value", JSONObject.NULL))
            .put("forYou.collection.6fa459ea-ee8a-4ca4-894e-db77e160355e", JSONObject().put("clock", 6).put("actor", "a")
                .put("value", JSONObject().put("id", "1b4e28ba-2fa1-41d2-883f-0016d3cca427").put("name", "Moved")))
        val (interests, collections) = ForYouSync.read(fields)
        assertEquals(listOf(ForYouGenre.THRILLER), interests!!.genreChoices)
        assertEquals(listOf(made.id), collections.map { it.id })
    }

    @Test fun `eras widen and recent is five years`() {
        assertEquals(1980 to 2009, ForYouEra.span(listOf(ForYouEra.EIGHTIES_NINETIES, ForYouEra.TWO_THOUSANDS), 2026))
        assertEquals(null to null, ForYouEra.span(listOf(ForYouEra.CLASSICS, ForYouEra.RECENT), 2026))
        assertEquals(2022 to null, ForYouEra.span(listOf(ForYouEra.RECENT), 2026))
    }

    @Test fun `row plan matches apple`() {
        val interests = ForYouInterests(listOf("scifi", "thriller", "comedy"), listOf("kdrama"), listOf("recent"),
            listOf(ForYouPerson(137427, "Denis Villeneuve", "Directing"), ForYouPerson(1373737, "Florence Pugh", "Acting")), true)
        val plan = ForYouQuery.plan(interests, today)
        assertEquals(listOf("forYou.genre.scifi", "forYou.person.137427", "forYou.extra.kdrama", "forYou.genre.thriller", "forYou.person.1373737"),
            plan.map { it.id })
        assertEquals(ForYouTitle.Genre(ForYouGenre.SCIFI, ForYouEra.RECENT), plan[0].title)
        assertEquals(ForYouTitle.Person("Denis Villeneuve", true), plan[1].title)
        assertEquals(ForYouTitle.Person("Florence Pugh", false), plan[4].title)
        assertEquals(ForYouSource.Discover(
            "with_genres=878&sort_by=popularity.desc&vote_average.gte=7.0&vote_count.gte=300&primary_release_date.gte=2022-01-01&primary_release_date.lte=2026-10-13",
            "with_genres=10765&sort_by=popularity.desc&vote_average.gte=7.5&vote_count.gte=200&first_air_date.gte=2022-01-01&first_air_date.lte=2026-10-13"),
            plan[0].source)
        assertEquals(ForYouSource.Discover(null,
            "with_original_language=ko&sort_by=popularity.desc&vote_average.gte=7.0&vote_count.gte=80&first_air_date.gte=2022-01-01&first_air_date.lte=2026-10-13"),
            plan[2].source)
        assertNull((plan[3].source as ForYouSource.Discover).tv)
        assertEquals(ForYouSource.Person(137427), plan[1].source)
        assertEquals(ForYouTitle.Genre(ForYouGenre.SCIFI, null), ForYouQuery.plan(interests.copy(eras = emptyList()), today)[0].title)
        assertTrue(ForYouQuery.plan(ForYouInterests(), today).isEmpty())
        val many = ForYouInterests(listOf("scifi", "drama", "crime"), listOf("anime", "british", "standup"), emptyList(),
            (1..4).map { ForYouPerson(it, "P$it") })
        assertEquals(ForYouQuery.MAX_ROWS, ForYouQuery.plan(many, today).size)
    }

    @Test fun `collection queries match apple`() {
        val villeneuve = SmartCollectionRules(genres = listOf("scifi", "thriller"), people = listOf(ForYouPerson(137427, "Denis Villeneuve", "Directing")),
            yearFrom = 2010, minRating = 7.0, type = SmartCollectionRules.Kind.MOVIE, sort = SmartCollectionRules.Sort.RATING, hideWatched = true)
        assertEquals(ForYouSource.Discover(
            "with_genres=878%7C53&with_people=137427&sort_by=vote_average.desc&vote_average.gte=7.0&vote_count.gte=300&primary_release_date.gte=2010-01-01&primary_release_date.lte=2026-10-13",
            null), ForYouQuery.collectionSource(villeneuve, today))
        assertNull(ForYouQuery.collectionSource(villeneuve.copy(type = SmartCollectionRules.Kind.ALL), today).tv)
        val anime = SmartCollectionRules(extras = listOf("anime", "kdrama"), genres = listOf("comedy"))
        assertEquals(ForYouSource.Discover(
            "with_genres=16&with_original_language=ja&sort_by=popularity.desc&vote_count.gte=100&primary_release_date.lte=2026-10-13",
            "with_genres=16&with_original_language=ja&sort_by=popularity.desc&vote_count.gte=50&first_air_date.lte=2026-10-13"),
            ForYouQuery.collectionSource(anime, today))
        val horror = SmartCollectionRules(genres = listOf("horror"), yearTo = 1999, sort = SmartCollectionRules.Sort.NEWEST)
        assertEquals(ForYouSource.Discover("with_genres=27&sort_by=primary_release_date.desc&vote_count.gte=20&primary_release_date.lte=1999-12-31", null),
            ForYouQuery.collectionSource(horror, today))
        val future = SmartCollectionRules(yearTo = 2030, type = SmartCollectionRules.Kind.SERIES)
        assertEquals(ForYouSource.Discover(null, "sort_by=popularity.desc&vote_count.gte=50&first_air_date.lte=2026-10-13"),
            ForYouQuery.collectionSource(future, today))
    }
}
