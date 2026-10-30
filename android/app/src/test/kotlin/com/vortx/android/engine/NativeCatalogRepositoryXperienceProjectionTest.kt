package com.vortx.android.engine

import com.vortx.android.xperience.XperienceAddonBinding
import com.vortx.android.xperience.XperienceCollections
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Proposed source-level projection regression. It exercises the real NativeCatalogRepository
 * registry/filter/CatalogSpec projection over synthetic descriptor snapshots; no fake binding
 * projector replaces the production path. UNRUN.
 */
class NativeCatalogRepositoryXperienceProjectionTest {
    private val firstURL = "https://same.example/first/manifest.json"
    private val secondURL = "https://same.example/second/manifest.json"

    private fun read(disabled: List<String> = emptyList(), order: List<String>? = null): VortxNativeRead {
        val profile = JSONObject()
            .put("addons", "own")
            .put("settings", JSONObject().put("disabledAddons", JSONArray(disabled)))
        val preferences = JSONObject()
        if (order != null) {
            preferences.put("profile-a", JSONObject().put("addonPreferences", JSONObject()
                .put("rankingOverride", JSONObject().put("addonOrder", JSONArray(order)))))
        }
        val state = JSONObject()
            .put("roster", JSONObject().put("profiles", JSONObject().put("profile-a", profile)))
            .put("hostProfilePreferences", preferences)
        val scope = VortxAccountScope("account-fixture", "profile-a")
        return VortxNativeRead(VortxNativeOwner(scope, "profile-a", 41), state)
    }

    private fun descriptor(url: String): JSONObject = descriptorWithCatalog(url, JSONObject()
        .put("type", "movie")
        .put("id", "popular")
        .put("extra", JSONArray()
            .put(JSONObject().put("name", "genre"))
            .put(JSONObject().put("name", "skip"))))

    private fun descriptorWithCatalog(url: String, catalog: JSONObject): JSONObject = JSONObject()
        .put("transportUrl", url)
        .put("manifest", JSONObject()
            .put("id", "org.example.catalogs")
            .put("name", "Same configured display name")
            .put("catalogs", JSONArray().put(catalog)))

    private fun source(genre: String? = null): XperienceCollections.Source {
        val extra = genre?.let { ",\"genre\":\"$it\"" }.orEmpty()
        val raw = """[{"id":"collection","title":"Collection","folders":[{"id":"folder","title":"Folder","sources":[{"provider":"addon","addonId":"org.example.catalogs","type":"movie","catalogId":"popular","url":"https://untrusted.example/manifest.json"$extra}]}]}]"""
        return XperienceCollections.parse(raw.toByteArray(Charsets.UTF_8))
            .collections.single().folders.single().sources.single()
    }

    @Test fun sameNameInstancesAreAmbiguousThenExactTransportMappingResolves() {
        val read = read(order = listOf(secondURL, firstURL))
        val descriptors = listOf(descriptor(firstURL), descriptor(secondURL))
        val before = descriptors.map { it.toString() }
        val repository = NativeCatalogRepository(sessionProvider = { error("snapshot projection must not resample Session") })

        val snapshot = repository.xperienceCandidatesFromDescriptorSnapshot(read, descriptors)

        assertEquals(read.owner, snapshot.owner)
        assertEquals("profile-a", snapshot.installedAddonProfileID)
        assertEquals(before, descriptors.map { it.toString() })
        val candidates = snapshot.candidates
        assertEquals(listOf(
            "https://same.example/second/manifest.json",
            "https://same.example/first/manifest.json",
        ), candidates.map { it.canonicalTransport })
        val ambiguous = XperienceAddonBinding.resolve(source(), candidates)
        assertTrue(ambiguous is XperienceAddonBinding.Resolution.Ambiguous)
        val selected = candidates.first()
        assertEquals(XperienceAddonBinding.Resolution.Resolved(selected),
            XperienceAddonBinding.resolve(source(), candidates, selected.mapping))
        assertEquals("https://same.example/second/manifest.json", selected.canonicalTransport)
    }

    @Test fun profileDisabledConfigurationCannotRetargetStaleMappingToSiblingInstance() {
        val descriptors = listOf(descriptor(firstURL), descriptor(secondURL))
        val repository = NativeCatalogRepository(sessionProvider = { error("snapshot projection must not resample Session") })
        val original = repository.xperienceCandidatesFromDescriptorSnapshot(
            read(order = listOf(secondURL, firstURL)), descriptors,
        )
        val stale = original.candidates.first().mapping
        val afterDisable = repository.xperienceCandidatesFromDescriptorSnapshot(
            read(disabled = listOf(secondURL), order = listOf(secondURL, firstURL)), descriptors,
        )

        assertEquals(listOf("https://same.example/first/manifest.json"),
            afterDisable.candidates.map { it.canonicalTransport })
        assertEquals(XperienceAddonBinding.Resolution.MappingUnavailable,
            XperienceAddonBinding.resolve(source(), afterDisable.candidates, stale))
        assertEquals(XperienceAddonBinding.Resolution.Resolved(afterDisable.candidates.single()),
            XperienceAddonBinding.resolve(source(), afterDisable.candidates))
    }


    @Test fun appleLegacyExtraFieldsAffectOnlyXperienceProjection() {
        val repository = NativeCatalogRepository(sessionProvider = { error("snapshot projection must not resample Session") })
        val legacyGenre = descriptorWithCatalog(firstURL, JSONObject()
            .put("type", "movie")
            .put("id", "popular")
            .put("extraSupported", JSONArray().put("genre").put("skip"))
            .put("extraRequired", JSONArray().put("genre")))
        val snapshot = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(legacyGenre))
        val candidate = snapshot.candidates.single()
        val catalog = candidate.catalogs.single()
        assertTrue(catalog.acceptsGenre)
        assertTrue(catalog.requiresGenre)
        assertTrue(catalog.supportsSkip)
        assertEquals(XperienceAddonBinding.Resolution.Resolved(candidate),
            XperienceAddonBinding.resolve(source(genre = "Drama"), snapshot.candidates))
        assertEquals(XperienceAddonBinding.Resolution.UnsupportedGenreConfiguration,
            XperienceAddonBinding.resolve(source(), snapshot.candidates))

        val unsupportedSearch = descriptorWithCatalog(secondURL, JSONObject()
            .put("type", "movie")
            .put("id", "popular")
            .put("extraRequired", JSONArray().put("search")))
        val omitted = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(unsupportedSearch))
        assertTrue(omitted.candidates.single().catalogs.isEmpty())
        assertEquals(XperienceAddonBinding.Resolution.Missing,
            XperienceAddonBinding.resolve(source(), omitted.candidates))
    }

    @Test fun malformedPresentLegacyRequiredExtrasRejectTheInstalledProjection() {
        val repository = NativeCatalogRepository(sessionProvider = { error("snapshot projection must not resample Session") })
        val malformed = descriptorWithCatalog(firstURL, JSONObject()
            .put("type", "movie")
            .put("id", "popular")
            .put("extraRequired", "genre"))
        try {
            repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(malformed))
            throw AssertionError("Expected invalid installed registry")
        } catch (_: IllegalArgumentException) { }
    }

    @Test fun actualCatalogSpecExtrasDriveGenreAndSkipProjection() {
        val repository = NativeCatalogRepository(sessionProvider = { error("snapshot projection must not resample Session") })
        val snapshot = repository.xperienceCandidatesFromDescriptorSnapshot(
            read(), listOf(descriptor(firstURL)),
        )
        val catalog = snapshot.candidates.single().catalogs.single()
        assertTrue(catalog.acceptsGenre)
        assertTrue(catalog.supportsSkip)
        assertEquals(XperienceAddonBinding.Resolution.Resolved(snapshot.candidates.single()),
            XperienceAddonBinding.resolve(source(genre = "Drama"), snapshot.candidates))
    }
}
