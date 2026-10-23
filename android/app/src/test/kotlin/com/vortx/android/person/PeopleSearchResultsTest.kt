package com.vortx.android.person

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PeopleSearchResultsTest {
    private fun results(vararg entries: String) = JSONArray("[" + entries.joinToString(",") + "]")

    @Test fun `most popular person comes first with photo and department`() {
        val people = TMDBPersonClient.peopleResults(
            results(
                """{"id":2,"name":"Tom Hanks Jr","popularity":3.0,"profile_path":"/b.jpg","known_for":[]}""",
                """{"id":31,"name":"Tom Hanks","popularity":80.5,"profile_path":"/a.jpg","known_for_department":"Acting","known_for":[{}]}""",
            ),
            limit = 20,
        )
        assertEquals(listOf(31, 2), people.map { it.id })
        assertEquals("https://image.tmdb.org/t/p/w185/a.jpg", people[0].profileUrl)
        assertEquals("Acting", people[0].character)
        assertNull(people[1].character)
    }

    @Test fun `a bare name collision with no photo and no credits is dropped`() {
        val people = TMDBPersonClient.peopleResults(
            results(
                """{"id":7,"name":"Nobody","popularity":9.0,"profile_path":null,"known_for":[]}""",
                """{"id":8,"name":"Credited","popularity":1.0,"known_for":[{"id":1}]}""",
            ),
            limit = 20,
        )
        assertEquals(listOf(8), people.map { it.id })
        assertNull(people[0].profileUrl)
    }

    @Test fun `entries without a real id or name are skipped and the limit holds`() {
        val people = TMDBPersonClient.peopleResults(
            results(
                """{"id":0,"name":"Zero","profile_path":"/z.jpg"}""",
                """{"id":5,"name":"","profile_path":"/e.jpg"}""",
                """{"id":10,"name":"A","popularity":3.0,"profile_path":"/1.jpg"}""",
                """{"id":11,"name":"B","popularity":2.0,"profile_path":"/2.jpg"}""",
                """{"id":12,"name":"C","popularity":1.0,"profile_path":"/3.jpg"}""",
            ),
            limit = 2,
        )
        assertEquals(listOf(10, 11), people.map { it.id })
    }
}
