package com.vortx.android.home

import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.trickplay.TmdbImdbResolution
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionsHubProviderPolicyTest {
    @Test
    fun `provider aliases collapse to one canonical brand`() {
        assertEquals(350, CollectionsHubProviderPolicy.canonicalId(2))
        assertEquals(9, CollectionsHubProviderPolicy.canonicalId(119))
        assertEquals(1899, CollectionsHubProviderPolicy.canonicalId(384))
        assertEquals(2336, CollectionsHubProviderPolicy.canonicalId(970))
    }

    @Test
    fun `provider family contains canonical id first and every alias once`() {
        assertEquals(listOf(531, 2303, 2304, 2616), CollectionsHubProviderPolicy.familyMembers(2303))
        assertEquals(listOf(9, 119), CollectionsHubProviderPolicy.familyMembers(9))
        assertEquals(listOf(232), CollectionsHubProviderPolicy.familyMembers(232))
    }

    @Test
    fun `merged brands use current display names`() {
        assertEquals("JioHotstar", CollectionsHubProviderPolicy.displayName(122, "Disney+ Hotstar"))
        assertEquals("Paramount+", CollectionsHubProviderPolicy.displayName(2304, "Paramount Plus Essential"))
        assertEquals("ZEE5", CollectionsHubProviderPolicy.displayName(232, "ZEE5"))
    }

    @Test
    fun `saved service selection preserves order canonicalizes and rejects malformed ids`() {
        assertEquals(
            listOf(2336, 232, 9),
            CollectionsHubProviderPolicy.selectedProviderIds(" 970, bad,232,-1,122,119,9 "),
        )
        assertTrue(CollectionsHubProviderPolicy.selectedProviderIds("8,9", limit = -1).isEmpty())
    }

    @Test
    fun `service regions keep viewer first then bounded carried markets`() {
        assertEquals(
            listOf("GB", "IN", "US", "CA"),
            CollectionsHubProviderPolicy.serviceRegions("gb", listOf("IN", "GB", "us", "IN", "CA", "AU")),
        )
    }

    @Test
    fun `invalid region rows and negative extra limits fail closed`() {
        assertEquals(
            listOf("GB"),
            CollectionsHubProviderPolicy.serviceRegions("GB", listOf("", "USA", "1", "IN"), maxExtra = -1),
        )
    }

    @Test
    fun `regional results interleave without duplicate titles`() {
        val result = CollectionsHubProviderPolicy.roundRobin(
            listOf(listOf("gb-a", "shared", "gb-b"), listOf("in-a", "shared", "in-b"), listOf("us-a")),
            identity = { it },
        )

        assertEquals(listOf("gb-a", "in-a", "us-a", "shared", "gb-b", "in-b"), result)
    }

    @Test
    fun `shared preference contract keeps exact keys and defaults`() {
        assertEquals("vortx.home.showCollectionsHub", SHOW_COLLECTIONS_HUB_KEY)
        assertEquals("vortx.collections.refreshCadence", COLLECTIONS_REFRESH_CADENCE_KEY)
        assertEquals("vortx.collections.selectedProviders", COLLECTIONS_SELECTED_PROVIDERS_KEY)
        assertTrue(COLLECTIONS_HUB_ENABLED_DEFAULT)
        assertEquals("daily", COLLECTIONS_REFRESH_CADENCE_DEFAULT)
        assertEquals("", COLLECTIONS_SELECTED_PROVIDERS_DEFAULT)
    }

    @Test
    fun `tmdb support requires an enabled meta addon with a matching declared prefix`() {
        val supported = addon(
            providesMeta = true,
            raw = """{"manifest":{"resources":[{"name":"meta","idPrefixes":["tmdb:"]}]}}""",
        )
        val manifestLevel = addon(
            providesMeta = true,
            raw = """{"manifest":{"resources":["meta"],"idPrefixes":["tmdb"]}}""",
        )
        val imdbOnly = addon(
            providesMeta = true,
            raw = """{"manifest":{"resources":[{"name":"meta","idPrefixes":["tt"]}]}}""",
        )

        assertTrue(CollectionsHubProviderPolicy.supportsTmdbCatalogItems(listOf(supported)))
        assertTrue(CollectionsHubProviderPolicy.supportsTmdbCatalogItems(listOf(manifestLevel)))
        assertFalse(CollectionsHubProviderPolicy.supportsTmdbCatalogItems(listOf(supported.copy(isDisabled = true))))
        assertFalse(CollectionsHubProviderPolicy.supportsTmdbCatalogItems(listOf(imdbOnly)))
        assertFalse(CollectionsHubProviderPolicy.supportsTmdbCatalogItems(listOf(supported.copy(providesMeta = false))))
    }

    @Test
    fun `typed resolver failures preserve a valid tmdb item only when downstream supports it`() {
        val item = MetaItem("tmdb:movie:123", MediaType.MOVIE, "Title")
        val failures = listOf(
            TmdbImdbResolution.NoImdbId,
            TmdbImdbResolution.TransportFailure,
            TmdbImdbResolution.HttpFailure(429),
            TmdbImdbResolution.ParseFailure,
        )

        failures.forEach { resolution ->
            assertEquals(
                "tmdb:123",
                CollectionsHubItemPolicy.resolvedItem(item, resolution, tmdbCatalogSupported = true)?.id,
            )
            assertNull(CollectionsHubItemPolicy.resolvedItem(item, resolution, tmdbCatalogSupported = false))
        }
    }

    @Test
    fun `typed resolver prefers imdb and rejects invalid input`() {
        val item = MetaItem("tmdb:tv:456", MediaType.SERIES, "Series")

        assertEquals(
            "tt1234567",
            CollectionsHubItemPolicy.resolvedItem(
                item,
                TmdbImdbResolution.Resolved("tt1234567"),
                tmdbCatalogSupported = true,
            )?.id,
        )
        assertNull(
            CollectionsHubItemPolicy.resolvedItem(
                item.copy(id = "not-tmdb"),
                TmdbImdbResolution.InvalidId,
                tmdbCatalogSupported = true,
            ),
        )
    }

    private fun addon(providesMeta: Boolean, raw: String) = InstalledAddon(
        transportUrl = "https://example.com/manifest.json",
        name = "Example",
        providesMeta = providesMeta,
        rawDescriptorJson = raw,
    )
}
