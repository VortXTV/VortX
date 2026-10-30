package com.vortx.android.xperience

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Focused source proposal; not compiled or run. */
class XperienceAddonBindingTest {
    private fun source(
        provider: String = "addon",
        addon: String? = "org.example.catalogs",
        type: String? = "movie",
        catalog: String? = "popular",
        genre: String? = null,
    ): XperienceCollections.Source {
        val fields = listOfNotNull(
            "\"provider\":\"$provider\"",
            addon?.let { "\"addonId\":\"$it\"" },
            type?.let { "\"type\":\"$it\"" },
            catalog?.let { "\"catalogId\":\"$it\"" },
            genre?.let { "\"genre\":\"$it\"" },
            "\"url\":\"https://untrusted.example/manifest.json\"",
        ).joinToString(",")
        val json = "[{\"id\":\"c\",\"title\":\"C\",\"folders\":[{" +
            "\"id\":\"f\",\"title\":\"F\",\"sources\":[{$fields}]}]}]"
        return XperienceCollections.parse(json.toByteArray(Charsets.UTF_8))
            .collections.single().folders.single().sources.single()
    }

    private fun descriptor(url: String, manifest: String = "org.example.catalogs") =
        XperienceAddonBinding.Candidate.fromInstalled(
            XperienceAddonBinding.InstalledDescriptor(
                manifestID = manifest,
                transportURL = url,
                catalogs = listOf(XperienceAddonBinding.Catalog("movie", "popular", true, false, true)),
                displayName = "Same display name",
            ),
        )

    @Test fun sameNamedConfiguredInstancesRequireExactStoredTransportMapping() {
        val first = descriptor("https://one.example/manifest.json")
        val second = descriptor("https://two.example/manifest.json")
        val installed = listOf(first, second)
        assertNotEquals(first.transportFingerprint, second.transportFingerprint)
        assertTrue(XperienceAddonBinding.resolve(source(), installed) is XperienceAddonBinding.Resolution.Ambiguous)
        val resolved = XperienceAddonBinding.resolve(source(), installed, second.mapping)
        assertEquals(XperienceAddonBinding.Resolution.Resolved(second), resolved)
        assertEquals("https://two.example/manifest.json",
            (resolved as XperienceAddonBinding.Resolution.Resolved).candidate.canonicalTransport)
        assertEquals(XperienceAddonBinding.Resolution.MappingUnavailable,
            XperienceAddonBinding.resolve(source(), installed, first.mapping.copy(manifestID = "other")))
    }

    @Test fun missingChangedAndDuplicateRegistryInstancesFailClosed() {
        val one = descriptor("https://one.example/manifest.json")
        assertEquals(XperienceAddonBinding.Resolution.Missing,
            XperienceAddonBinding.resolve(source(), emptyList()))
        assertEquals(XperienceAddonBinding.Resolution.MappingUnavailable,
            XperienceAddonBinding.resolve(source(), listOf(descriptor("https://replacement.example/manifest.json")), one.mapping))
        assertEquals(XperienceAddonBinding.Resolution.InvalidRegistry,
            XperienceAddonBinding.resolve(source(), listOf(one, descriptor("https://one.example/manifest.json"))))
    }

    @Test fun providerAndCatalogCapabilitiesAreExactAndImportedUrlsAreNotInputs() {
        val candidate = descriptor("https://installed.example/base/manifest.json?tenant=a%2Fb")
        assertEquals(XperienceAddonBinding.Resolution.UnsupportedProvider,
            XperienceAddonBinding.resolve(source(provider = "community"), listOf(candidate)))
        assertEquals(XperienceAddonBinding.Resolution.UnsupportedGenreConfiguration,
            XperienceAddonBinding.resolve(source(genre = "Drama"), listOf(
                XperienceAddonBinding.Candidate.fromInstalled(
                    XperienceAddonBinding.InstalledDescriptor(
                        "org.example.catalogs", "https://installed.example/manifest.json",
                        listOf(XperienceAddonBinding.Catalog("movie", "popular", false, false, false)),
                    ),
                ),
            )))
        assertEquals("https://installed.example/base/manifest.json?tenant=a%2Fb", candidate.canonicalTransport)
        assertTrue(XperienceAddonBinding.key(source()).matches(Regex("[0-9a-f]{64}")))
    }

    @Test fun invalidTransportAndDuplicateCatalogDefinitionsReject() {
        val badURLs = listOf(
            "file:///tmp/manifest.json", "https://user@host.example/manifest.json",
            "https://host.example/manifest.json#fragment", "https://host.example/not-manifest.json",
            "https://host.example:0/manifest.json",
        )
        badURLs.forEach { url ->
            try {
                descriptor(url)
                throw AssertionError("Expected invalid installed transport")
            } catch (_: IllegalArgumentException) { }
        }
        try {
            XperienceAddonBinding.Candidate.fromInstalled(
                XperienceAddonBinding.InstalledDescriptor(
                    "org.example.catalogs", "https://host.example/manifest.json",
                    listOf(
                        XperienceAddonBinding.Catalog("movie", "popular", false, false, false),
                        XperienceAddonBinding.Catalog("movie", "popular", true, false, true),
                    ),
                ),
            )
            throw AssertionError("Expected invalid duplicate catalog")
        } catch (_: IllegalArgumentException) { }
    }
}
