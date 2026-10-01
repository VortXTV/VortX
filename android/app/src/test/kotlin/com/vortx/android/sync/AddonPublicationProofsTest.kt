package com.vortx.android.sync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

internal fun publicationAddon(url: String) = requireNotNull(VortXSyncDoc.addonDescriptor(JSONObject().put("transportUrl", url)
    .put("manifest", JSONObject().put("id", "sample").put("name", "Sample"))))

class AddonPublicationProofsTest {
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
            lease.install(native, expected, { if (mode == "missing") emptyList() else listOf(actual) }) { writes++ }
            assertEquals(mode, mode == "good", proofs.published("B", native, actual) != null)
            assertEquals(if (mode == "expired") 0 else 1, writes)
        }
    }
}
