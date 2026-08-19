package com.vortx.android.data

import com.vortx.android.model.AdvancedDiscoverFilters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class CatalogPreferencesStoreTest {
    @Test
    fun `filters persist with Apple field names and round trip`() {
        val persistence = RecordingCatalogPreferencesPersistence()
        val store = CatalogPreferencesStore(persistence)
        val filters = AdvancedDiscoverFilters(
            includedGenres = setOf("Drama"),
            excludedGenres = setOf("Horror"),
            minYear = 2010,
            maxYear = 2029,
            ageRatings = setOf("PG-13", "R"),
            minMinutes = 90,
            maxMinutes = 120,
            minSeasons = 2,
            maxSeasons = 3,
            upcomingOnly = true,
        )

        store.setFilters(filters)

        val saved = requireNotNull(persistence.value)
        listOf(
            "includedGenres", "excludedGenres", "minYear", "maxYear", "ageRatings",
            "minMinutes", "maxMinutes", "minSeasons", "maxSeasons", "upcomingOnly",
        ).forEach { assert(saved.contains("\"$it\"")) }
        assertEquals(filters, CatalogPreferencesStore(persistence).filters.value)
    }

    @Test
    fun `empty filters remove persistence and malformed JSON fails closed to empty`() {
        val persistence = RecordingCatalogPreferencesPersistence("{not-json")
        val store = CatalogPreferencesStore(persistence)

        assertFalse(store.filters.value.isActive)
        store.setFilters(AdvancedDiscoverFilters(includedGenres = setOf("Drama")))
        store.clearFilters()

        assertNull(persistence.value)
        assertFalse(store.filters.value.isActive)
    }

    private class RecordingCatalogPreferencesPersistence(
        var value: String? = null,
    ) : CatalogPreferencesPersistence {
        override fun read(): String? = value
        override fun write(value: String?) {
            this.value = value
        }
    }
}
