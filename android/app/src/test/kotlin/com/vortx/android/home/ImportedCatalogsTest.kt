package com.vortx.android.home

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImportedCatalogsTest {
    @Test
    fun `public Apple-shaped list decodes into normal playable items`() {
        val raw = """[{"id":"imported:trakt:me:marvel","title":"Marvel","provider":"trakt","sourceURL":"https://trakt.tv/users/me/lists/marvel","requiresConnection":false,"items":[{"id":"tt0371746","type":"movie","name":"Iron Man","poster":"https://img.example/iron.jpg"}]}]"""

        val decoded = ImportedCatalogCodec.decode(raw)

        assertEquals(1, decoded.size)
        assertEquals("tt0371746", decoded.single().items.single().id)
        assertEquals(MediaType.MOVIE, decoded.single().items.single().type)
    }

    @Test
    fun `base64 settings payload is accepted but private rows fail closed`() {
        val raw = """[{"id":"imported:trakt:me:private","title":"Private","provider":"trakt","sourceURL":"https://trakt.tv/users/me/lists/private","requiresConnection":true,"items":[{"id":"tt1","type":"movie","name":"Private"}]}]"""
        val encoded = Base64.getEncoder().encodeToString(raw.toByteArray())

        assertTrue(ImportedCatalogCodec.decode(encoded).isEmpty())
    }

    @Test
    fun `malformed ids urls and empty rows are rejected`() {
        val raw = """[
          {"id":"wrong","title":"Bad","provider":"trakt","sourceURL":"https://trakt.tv/x","items":[{"id":"tt1","type":"movie","name":"One"}]},
          {"id":"imported:trakt:me:ssrf","title":"Bad URL","provider":"trakt","sourceURL":"file:///etc/passwd","items":[{"id":"tt1","type":"movie","name":"One"}]},
          {"id":"imported:trakt:me:empty","title":"Empty","provider":"trakt","sourceURL":"https://trakt.tv/x","items":[{"id":"bad","type":"movie","name":"Bad"}]}
        ]"""

        assertTrue(ImportedCatalogCodec.decode(raw).isEmpty())
    }

    @Test
    fun `codec deduplicates and caps imported items`() {
        val items = (1..200).map { MetaItem("tt$it", MediaType.MOVIE, "Movie $it") } +
            MetaItem("tt1", MediaType.MOVIE, "Duplicate")
        val catalog = ImportedListCatalog(
            "imported:mdblist:user:list",
            "List",
            ImportedListProvider.MDBLIST,
            "https://mdblist.com/lists/user/list",
            items,
        )

        val decoded = ImportedCatalogCodec.decode(ImportedCatalogCodec.encode(listOf(catalog)))

        assertEquals(150, decoded.single().items.size)
        assertEquals(150, decoded.single().items.map(MetaItem::id).distinct().size)
    }

    @Test
    fun `imported rails follow media servers and replace stale rows`() {
        val base = listOf(
            Catalog("${MEDIA_ID}server:movie", "Server", listOf(item("tt1"))),
            Catalog("addon", "Popular", listOf(item("tt2"))),
            Catalog("${IMPORTED_CATALOG_PREFIX}old", "Old", listOf(item("tt3"))),
        )
        val catalog = ImportedListCatalog(
            "imported:letterboxd:user:new",
            "New",
            ImportedListProvider.LETTERBOXD,
            "https://letterboxd.com/user/list/new",
            listOf(item("tt4")),
        )

        val result = withImportedCatalogRails(base, importedCatalogRails(listOf(catalog)))

        assertEquals(listOf("Server", "New", "Popular"), result.map(Catalog::title))
    }

    private fun item(id: String) = MetaItem(id, MediaType.MOVIE, id)

    private companion object {
        const val MEDIA_ID = "vortx.home.mediaServers:"
    }
}
