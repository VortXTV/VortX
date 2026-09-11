package com.vortx.android.engine

import com.vortx.android.model.MediaRelation
import com.vortx.android.model.MediaType
import org.junit.Assert.*
import org.junit.Test

class MediaRelationsTest {
    private fun parse(url: String, category: String = "Sequel", name: String = " Next ") =
        MediaRelation.parse(category, name, url)

    @Test fun internalRoutesPreserveNamespacedAnimeIdsAndLiteralPlus() {
        val result = parse("stremio:///detail/series/kitsu%3A123+4")!!
        assertEquals("kitsu:123+4", result.item.id)
        assertEquals(MediaType.SERIES, result.item.type)
        assertEquals("Next", result.item.name)
        assertEquals(MediaRelation.Kind.SEQUEL, result.kind)
        assertEquals("tt123", parse("https://web.stremio.com/#/detail/movie/tt123")!!.item.id)
        assertEquals("kitsu%3A123", parse("stremio:///detail/series/kitsu%253A123")!!.item.id)
    }

    @Test fun rejectsExternalOrAmbiguousRoutesWithoutConvertingCustomTypesToMovies() {
        listOf(
            "https://evil.invalid/#/detail/movie/tt1",
            "https://user@web.stremio.com/#/detail/movie/tt1",
            "https://web.stremio.com:443/#/detail/movie/tt1",
            "https://web.stremio.com/other#/detail/movie/tt1",
            "https://web.stremio.com/?x=1#/detail/movie/tt1",
            "https://web.stremio.com/#/detail/movie/tt1?extra=1",
            "stremio://host/detail/movie/tt1", "stremio:///detail/movie/tt1?x=1",
            "stremio:///detail/movie/tt1#x", "stremio:///detail/movie/tt%2F1",
            "stremio:///detail/movie/tt%001", "stremio:///detail/movie/tt%ZZ",
            "stremio:///detail/movie/", "stremio:///detail/movie/tt1/extra",
            "stremio:///detail/anime/kitsu:1", "stremio:///detail/custom/1",
        ).forEach { assertNull(it, parse(it)) }
        assertNull(parse("stremio:///detail/movie/tt1", "next"))
        assertNull(parse("stremio:///detail/movie/tt1", name = "  "))
    }

    @Test fun selfRemovalAndTypeAwareDedupePreserveFirstRelation() {
        val movie = parse("stremio:///detail/movie/tt1")!!
        val series = parse("stremio:///detail/series/tt1")!!
        assertEquals(listOf(movie, series), MediaRelation.visible(listOf(movie, movie, series), emptySet()))
        assertTrue(MediaRelation.visible(listOf(movie, series), setOf("tt1")).isEmpty())
    }

    @Test fun productionEnginePayloadSkipsBadSiblingsAndRetainsReadyMetadataRelations() {
        val json = """{"metaItems":[{"content":{"type":"Ready","content":{
          "id":"tt1","type":"series","name":"Current","links":[
          null,42,{"category":"Sequel","name":12,"url":"stremio:///detail/series/tt2"},
          {"category":"Sequel","name":"Self","url":"stremio:///detail/series/tt1"},
          {"category":" Sequel ","name":"Next","url":"stremio:///detail/series/kitsu%3A2"},
          {"category":"Related","name":"Duplicate","url":"stremio:///detail/series/kitsu%3A2"}
          ]}}}]}"""
        val meta = EngineState.parseMetaDetail(json)!!
        assertEquals(1, meta.relations.size)
        assertEquals("kitsu:2", meta.relations.single().item.id)
        assertEquals("Next", meta.relations.single().item.name)
        assertTrue(EngineState.parseMetaDetail(json.replace("\"links\"", "\"unused\""))!!.relations.isEmpty())
    }
}
