package com.vortx.android.sync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

internal fun publicationAddon(url: String) = requireNotNull(VortXSyncDoc.addonDescriptor(JSONObject().put("transportUrl", url)
    .put("manifest", JSONObject().put("id", "sample").put("name", "Sample"))))

class AddonPublicationProofsTest {
    @Test fun `explicit trusted descriptor flags require matching installed flags before publication`() {
        val expected = publicationAddon("https://fixture.invalid/manifest.json").let {
            it.copy(raw = JSONObject(it.raw.toString()).put("flags", JSONObject().put("official", true).put("protected", true)))
        }
        for (mode in listOf("protected", "official", "absent")) {
            val actual = expected.copy(raw = JSONObject(expected.raw.toString()).also { raw ->
                if (mode == "absent") raw.remove("flags") else raw.getJSONObject("flags").put(mode, false)
            })
            val proofs = AddonPublicationProofs(MemoryLibraryProofPersistence())
            val native = NativeLibraryOwner("fixture")
            assertFalse(AddonPublicationProofs.matchesInstalled(expected, actual))
            assertFalse(AddonPublicationLease("fixture-account", proofs) { it() }.install(native, expected, { listOf(actual) }) {})
            assertNull(proofs.published("fixture-account", native, actual))
        }
    }

    @Test fun `absent legacy flags retain subset semantics while explicit false cannot be promoted`() {
        val legacy = publicationAddon("https://fixture.invalid/manifest.json")
        val emptyLegacy = legacy.copy(raw = JSONObject(legacy.raw.toString()).put("flags", JSONObject()))
        assertTrue(AddonPublicationProofs.matchesInstalled(emptyLegacy, legacy))
        val native = legacy.copy(raw = JSONObject(legacy.raw.toString()).put("flags", JSONObject().put("protected", true).put("official", true)))
        assertTrue(AddonPublicationProofs.matchesInstalled(legacy, native))
        val untrusted = legacy.copy(raw = JSONObject(legacy.raw.toString()).put("flags", JSONObject().put("protected", false).put("official", false)))
        assertFalse(AddonPublicationProofs.matchesInstalled(untrusted, native))
        val actual = untrusted.copy(raw = JSONObject(untrusted.raw.toString()).also { it.getJSONObject("flags").put("futureDefault", true) })
        assertTrue(AddonPublicationProofs.matchesInstalled(untrusted, actual))
    }

    @Test fun `configured credential case exact raw fingerprint and authorized outbound survive restart`() {
        val disk = MemoryLibraryProofPersistence()
        val proofs = AddonPublicationProofs(disk)
        val native = NativeLibraryOwner(null)
        val expected = publicationAddon("https://addon.example/TokenA/manifest.json?Key=AA")
        val raw = expected.copy(raw = JSONObject(expected.raw.toString()).put("inheritedSecret", "foreign"))
        assertTrue(proofs.grant("B", native, listOf(raw to expected)))
        val reopened = AddonPublicationProofs(disk)
        assertEquals(expected.raw.toString(), reopened.published("B", native, raw)?.raw.toString())
        assertNull(reopened.published("A", native, raw))
        assertNull(reopened.published("B", NativeLibraryOwner("other"), raw))
        assertNull(reopened.published("B", native, publicationAddon(expected.transportUrl.lowercase())))
        assertNull(reopened.published("B", native, raw.copy(raw = JSONObject(raw.raw.toString()).put("inheritedSecret", "changed"))))
        disk.failWrites = true
        val another = publicationAddon("https://addon.example/other/manifest.json")
        assertFalse(proofs.grant("B", native, listOf(another to another)))
        assertNull(AddonPublicationProofs(disk).published("B", native, another))
    }

    @Test fun `local installation requires live admission and positive expected manifest postread`() {
        for (mode in listOf("good", "wrongEndpoint", "wrongManifest", "missing", "expired", "failedCommit")) {
            val disk = MemoryLibraryProofPersistence().apply { failWrites = mode == "failedCommit" }
            val proofs = AddonPublicationProofs(disk)
            val native = NativeLibraryOwner("shared")
            val expected = publicationAddon("https://addon.example/TokenA/manifest.json")
            val actual = when (mode) {
                "wrongEndpoint" -> publicationAddon(expected.transportUrl.lowercase())
                "wrongManifest" -> expected.copy(raw = JSONObject(expected.raw.toString()).put("manifest", JSONObject().put("id", "other").put("name", "Other")))
                else -> expected
            }
            var writes = 0
            val lease = AddonPublicationLease("B", proofs) { if (mode == "expired") false else it() }
            val installed = lease.install(native, expected, { if (mode == "missing") emptyList() else listOf(actual) }) { writes++ }
            assertEquals(mode, mode == "good", installed)
            assertEquals(mode, mode == "good", proofs.published("B", native, actual) != null)
            assertEquals(if (mode == "expired") 0 else 1, writes)
        }
    }
}
