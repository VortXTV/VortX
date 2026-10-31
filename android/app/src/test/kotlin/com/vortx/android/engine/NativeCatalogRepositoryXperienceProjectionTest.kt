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
 * captured-registry/filter/projection over synthetic descriptor snapshots; no fake binding
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
        val ambiguous = snapshot.resolve(source())
        assertTrue(ambiguous is XperienceAddonBinding.Resolution.Ambiguous)
        val selected = candidates.first()
        assertEquals(XperienceAddonBinding.Resolution.Resolved(selected),
            snapshot.resolve(source(), selected.mapping))
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
            afterDisable.resolve(source(), stale))
        assertEquals(XperienceAddonBinding.Resolution.Resolved(afterDisable.candidates.single()),
            afterDisable.resolve(source()))
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
            snapshot.resolve(source(genre = "Drama")))
        assertEquals(XperienceAddonBinding.Resolution.UnsupportedGenreConfiguration,
            snapshot.resolve(source()))

        val unsupportedSearch = descriptorWithCatalog(secondURL, JSONObject()
            .put("type", "movie")
            .put("id", "popular")
            .put("extraRequired", JSONArray().put("search")))
        val omitted = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(unsupportedSearch))
        assertTrue(omitted.candidates.single().catalogs.isEmpty())
        assertEquals(XperienceAddonBinding.Resolution.Missing,
            omitted.resolve(source()))
    }

    @Test fun malformedPresentLegacyRequiredExtrasIsolateOnlyTheirKnownDescriptor() {
        val repository = NativeCatalogRepository(sessionProvider = { error("snapshot projection must not resample Session") })
        val malformed = descriptorWithCatalog(firstURL, JSONObject()
            .put("type", "movie").put("id", "popular").put("extraRequired", "genre"))
        val snapshot = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(malformed))
        assertTrue(snapshot.candidates.isEmpty())
        assertEquals(XperienceAddonBinding.Resolution.InvalidRegistry, snapshot.resolve(source()))
    }

    @Test fun actualXperienceExtrasDriveGenreAndSkipProjection() {
        val repository = NativeCatalogRepository(sessionProvider = { error("snapshot projection must not resample Session") })
        val snapshot = repository.xperienceCandidatesFromDescriptorSnapshot(
            read(), listOf(descriptor(firstURL)),
        )
        val catalog = snapshot.candidates.single().catalogs.single()
        assertTrue(catalog.acceptsGenre)
        assertTrue(catalog.supportsSkip)
        assertEquals(XperienceAddonBinding.Resolution.Resolved(snapshot.candidates.single()),
            snapshot.resolve(source(genre = "Drama")))
    }
    private fun isolatedDescriptor(id: String?, url: String, catalogs: Any? = JSONArray()
        .put(JSONObject().put("type", "movie").put("id", "popular"))): JSONObject {
        val manifest = JSONObject().put("futureOpaque", JSONObject().put("keep", 17))
        if (id != null) manifest.put("id", id)
        if (catalogs != null) manifest.put("catalogs", catalogs)
        return JSONObject().put("transportUrl", url).put("manifest", manifest)
    }
    private fun isolatedSource(id: String): XperienceCollections.Source {
        val source = JSONObject().put("provider", "addon").put("addonId", id)
            .put("type", "movie").put("catalogId", "popular")
            .put("url", "https://untrusted.example.invalid/manifest.json")
        val folder = JSONObject().put("id", "folder").put("title", "Folder")
            .put("sources", JSONArray().put(source))
        val collection = JSONObject().put("id", "collection").put("title", "Synthetic")
            .put("folders", JSONArray().put(folder))
        return XperienceCollections.parse(JSONArray().put(collection).toString().toByteArray(Charsets.UTF_8))
            .collections.single().folders.single().sources.single()
    }
    @Test fun malformedUnrelatedBeforeGoodRetainsOriginalRequestPairAndUnknownConfiguration() {
        val goodURL = "https://catalog.example.invalid/b/manifest.json?token=two"
        val descriptors = listOf(isolatedDescriptor("fixture.a", "https://catalog.example.invalid/a bad/manifest.json"),
            isolatedDescriptor("fixture.b", goodURL))
        val before = descriptors.map { it.toString() }
        val repository = NativeCatalogRepository(sessionProvider = { error("must not recapture Session") })
        val snapshot = repository.xperienceCandidatesFromDescriptorSnapshot(read(), descriptors)
        val resolved = snapshot.resolve(isolatedSource("fixture.b")) as XperienceAddonBinding.Resolution.Resolved
        assertEquals(goodURL, snapshot.pairedAddon(resolved.candidate).transportUrl)
        assertEquals(descriptors[1].getJSONObject("manifest").toString(), snapshot.pairedAddon(resolved.candidate).manifestJson)
        assertEquals(before, descriptors.map { it.toString() })
        val clone = XperienceAddonBinding.Candidate.fromInstalled(XperienceAddonBinding.InstalledDescriptor(
            "fixture.b", goodURL, resolved.candidate.catalogs))
        try {
            snapshot.pairedAddon(clone)
            throw AssertionError("A matching digest substituted a different candidate object")
        } catch (_: IllegalArgumentException) { }
    }
    @Test fun knownSameIdRejectionNeedsExplicitExactNoncollidingMapping() {
        val url = "https://catalog.example.invalid/a/manifest.json?token=one"
        val repository = NativeCatalogRepository(sessionProvider = { error("must not recapture Session") })
        val snapshot = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
            isolatedDescriptor("fixture.a", "https://catalog.example.invalid/a bad/manifest.json"),
            isolatedDescriptor("fixture.a", url)))
        val source = isolatedSource("fixture.a")
        assertTrue(snapshot.resolve(source) !is XperienceAddonBinding.Resolution.Resolved)
        val candidate = snapshot.candidates.single()
        assertEquals(XperienceAddonBinding.Resolution.Resolved(candidate), snapshot.resolve(source, candidate.mapping))
        assertEquals(url, snapshot.pairedAddon(candidate).transportUrl)
        assertEquals(XperienceAddonBinding.Resolution.MappingUnavailable,
            snapshot.resolve(source, XperienceAddonBinding.Mapping("fixture.a", "0".repeat(64))))
        for (badURL in listOf(url, "HTTPS://CATALOG.EXAMPLE.INVALID/a/manifest.json?token=one")) {
            val collision = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
                isolatedDescriptor("fixture.a", badURL, "malformed"), isolatedDescriptor("fixture.a", url)))
            assertTrue(collision.resolve(source, collision.candidates.single().mapping) !is XperienceAddonBinding.Resolution.Resolved)
        }
    }
    @Test fun validAmbiguityDuplicateIdentityNoCatalogAndMalformedCatalogSemanticsRemain() {
        val a = "https://catalog.example.invalid/a/manifest.json?token=one"
        val b = "https://catalog.example.invalid/b/manifest.json?token=two"
        val repository = NativeCatalogRepository(sessionProvider = { error("must not recapture Session") })
        val two = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
            isolatedDescriptor("fixture.a", a), isolatedDescriptor("fixture.a", b)))
        assertTrue(two.resolve(isolatedSource("fixture.a")) is XperienceAddonBinding.Resolution.Ambiguous)
        val duplicate = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
            isolatedDescriptor("fixture.a", a), isolatedDescriptor("fixture.a", a)))
        assertEquals(XperienceAddonBinding.Resolution.InvalidRegistry,
            duplicate.resolve(isolatedSource("fixture.a"), duplicate.candidates.first().mapping))
        val omitted = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
            isolatedDescriptor("fixture.a", b, null), isolatedDescriptor("fixture.a", a)))
        val resolved = omitted.resolve(isolatedSource("fixture.a")) as XperienceAddonBinding.Resolution.Resolved
        assertEquals(a, omitted.pairedAddon(resolved.candidate).transportUrl)
        val malformed = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
            isolatedDescriptor("fixture.a", a, "not-an-array"), isolatedDescriptor("fixture.b", b)))
        val unrelated = malformed.resolve(isolatedSource("fixture.b")) as XperienceAddonBinding.Resolution.Resolved
        assertEquals(b, malformed.pairedAddon(unrelated.candidate).transportUrl)
    }
    @Test fun unattributableOrScalarInvalidIdentityDeniesWholeCaptureAndUtf8TaintStaysExact() {
        val a = "https://catalog.example.invalid/a/manifest.json?token=one"
        val b = "https://catalog.example.invalid/b/manifest.json?token=two"
        val repository = NativeCatalogRepository(sessionProvider = { error("must not recapture Session") })
        for (id in listOf(null, "", " \t", "\uD800")) {
            try {
                repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
                    isolatedDescriptor(id, a), isolatedDescriptor("fixture.b", b)))
                throw AssertionError("Unknown/scalar-invalid manifest identity was quarantined instead of global denial")
            } catch (_: IllegalArgumentException) { }
        }
        val nfc = "caf\u00e9.addon"
        val nfd = "cafe\u0301.addon"
        assertTrue(!nfc.toByteArray(Charsets.UTF_8).contentEquals(nfd.toByteArray(Charsets.UTF_8)))
        val unicode = repository.xperienceCandidatesFromDescriptorSnapshot(read(), listOf(
            isolatedDescriptor(nfc, "https://catalog.example.invalid/a bad/manifest.json"), isolatedDescriptor(nfd, b)))
        val resolved = unicode.resolve(isolatedSource(nfd)) as XperienceAddonBinding.Resolution.Resolved
        assertEquals(b, unicode.pairedAddon(resolved.candidate).transportUrl)
        assertEquals(XperienceAddonBinding.Resolution.MappingUnavailable,
            unicode.resolve(isolatedSource(nfd), XperienceAddonBinding.Mapping(nfc, resolved.candidate.transportFingerprint)))
    }

}
