package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import org.junit.Assert.*
import org.junit.Test

/** Actual strict admission + actual legacy adapter + file-only projection. Synthetic source
 * accounts, no JNI or persistence. Shared vectors also feed the actual Apple projector fixture.
 * AUTHORED UNRUN: expectations are source-derived, not a claimed cross-platform execution. */
class AccountFileProfileMaterialTest {
    private fun vectors() = OHJson.Obj(requireNotNull(javaClass.classLoader?.getResourceAsStream(
        "account-file-profile-material.json")).use { it.readBytes() })
    private fun cases() = OHJson.array(vectors().raw("cases")).map { OHJson.Obj(it) }
    private fun rows(material: ByteArray) = OHJson.array(OHJson.Obj(material).raw("roster")).map { OHJson.Obj(it) }
    private fun same(expected: ByteArray, actual: ByteArray, name: String) {
        assertTrue(name, OHJson.equal(expected, actual))
    }

    @Test fun strictAdmittedFileProfilesMatchSharedAppleProjectionVectors() {
        val vectors = vectors(); val owner = vectors.text("owner"); val child = vectors.text("child")
        val scope = VortxAccountScope("account.file-profile-parity", owner)
        var positives = 0; var negatives = 0
        for (case in cases()) {
            val name = case.text("name"); val selected = case.raw("source"); val unchanged = selected.copyOf()
            val admitted = AccountFileLegacyAdmission.admitLegacy(selected, owner)
            val result = runCatching { admitted.prepareMaterial(scope) }
            if (OHJson.utf8(case.raw("expectReject")) == "true") {
                assertTrue("Must refuse held preference: $name", result.isFailure); negatives++
            } else {
                val material = result.getOrThrow(); val profiles = rows(material)
                val kid = profiles.single { it.text("id") == child }; val actual = kid.obj("settings")
                val expected = case.obj("expectedChildSettings")
                for (key in listOf("disabledAddons", "languages")) same(expected.raw(key), actual.raw(key), "$name/$key")
                if (expected["ranking"] == null) assertNull("$name/ranking", actual["ranking"])
                else same(expected.raw("ranking"), actual.raw("ranking"), "$name/ranking")
                assertEquals("shared", kid.obj("account").text("kind")); assertEquals(owner, kid.obj("account").text("value"))
                assertEquals("true", OHJson.utf8(kid.obj("parental").raw("kids")))
                assertEquals("true", OHJson.utf8(kid.obj("parental").raw("familyEdit")))
                assertEquals("sha256:" + "a".repeat(64), kid.text("pin"))
                assertEquals("local_only", profiles.single { it.text("id") == owner }.obj("account").text("kind"))
                assertNull(actual["source_type_order"])
                actual["ranking"]?.let { assertNull(OHJson.Obj(it)["source_type_order"]) }
                positives++
            }
            // Both accepted and refused preference paths preserve the exact selected account.
            assertArrayEquals(name, unchanged, selected)
            assertArrayEquals(name, unchanged, admitted.originalPlaintext())
            // Conservation seam only: this fake native value confers no admission authority.
            val candidate = OHJson.Obj(admitted.addingNativeSync(OHJson.literal("{\"syntheticOnly\":true}")))
            val original = OHJson.Obj(unchanged)
            original.keys.forEach { assertArrayEquals("$name/$it", original.raw(it), candidate.raw(it)) }
        }
        assertTrue("Meaningful positive matrix", positives >= 15)
        assertTrue("Meaningful held-preference matrix", negatives >= 6)
    }

    @Test fun generatedUnknownMaterialValuesAndUnprojectedInt64SourceSurviveExactly() {
        val case = cases().single { it.text("name") == "int64_ui_fields_and_transport_order_are_preserved_not_cast" }
        val source = case.raw("source"); val vectors = vectors(); val owner = vectors.text("owner")
        val scope = VortxAccountScope("account.file-profile-parity", owner)
        val admitted = AccountFileLegacyAdmission.admitLegacy(source, owner)
        val material = OHJson.Obj(admitted.prepareMaterial(scope))
        val unknown = OHJson.literal("{ \"precise\":9007199254740991.123,\"lexeme\":1.2300 }")
        material.set("futureMaterial", unknown)
        val withUnknown = rows(material.encoded()).map { row ->
            val settings = row.obj("settings").set("futureSetting", unknown)
            val ranking = settings["ranking"]?.let { OHJson.Obj(it) } ?: OHJson.Obj()
            settings.set("ranking", ranking.set("futureRanking", unknown).encoded())
            row.set("settings", settings.encoded()).set("futureProfile", unknown).encoded()
        }
        material.set("roster", OHJson.array(withUnknown))
        // This fixture contains only valid known fields plus a root unknown. Its raw roster is
        // therefore the same input shape produced by strict admission, without adding an API
        // that would expose private known records as a reusable authority token.
        val known = OHJson.array(OHJson.Obj(source).obj("vortx").raw("roster"))
        val projected = OHJson.Obj(AccountFileProfileMaterial.project(material.encoded(), known, owner))
        assertArrayEquals(unknown, projected.raw("futureMaterial"))
        rows(projected.encoded()).forEach { row ->
            assertArrayEquals(unknown, row.raw("futureProfile"))
            assertArrayEquals(unknown, row.obj("settings").raw("futureSetting"))
            assertArrayEquals(unknown, row.obj("settings").obj("ranking").raw("futureRanking"))
        }
        val rawKid = OHJson.array(OHJson.Obj(admitted.originalPlaintext()).obj("vortx").raw("roster"))
            .map { OHJson.Obj(it) }.single { it.text("id") == vectors.text("child") }
        assertEquals("9007199254740991", OHJson.utf8(rawKid.obj("playback").raw("minResolution")))
        assertEquals("9007199254740991", OHJson.utf8(rawKid.obj("playback").raw("titleMatchThreshold")))
        assertArrayEquals(source, admitted.originalPlaintext())
        // Reprojection is finite and stable; no converter/native/session invocation occurs here.
        same(projected.encoded(), AccountFileProfileMaterial.project(projected.encoded(), known, owner), "repeat projection")
    }

    @Test fun materialIdentityAndPolicyCannotBeChangedByThePreferenceOverlay() {
        val case = cases().first(); val source = case.raw("source"); val vectors = vectors()
        val owner = vectors.text("owner"); val scope = VortxAccountScope("account.file-profile-parity", owner)
        val admitted = AccountFileLegacyAdmission.admitLegacy(source, owner)
        val material = admitted.prepareMaterial(scope)
        val known = OHJson.array(OHJson.Obj(source).obj("vortx").raw("roster"))
        for ((key, value) in listOf("name" to OHJson.quote("different"), "owner" to OHJson.literal("false"),
            "addons" to OHJson.quote("own"), "pin" to OHJson.quote("sha256:" + "b".repeat(64)),
            "account" to OHJson.literal("{\"kind\":\"own\",\"value\":\"other\"}"),
            "parental" to OHJson.literal("{\"kids\":true,\"familyEdit\":true}"))) {
            val changed = rows(material).mapIndexed { index, row -> if (index == 0) row.set(key, value).encoded() else row.encoded() }
            val wrong = OHJson.Obj(material).set("roster", OHJson.array(changed)).encoded()
            assertTrue(key, runCatching { AccountFileProfileMaterial.project(wrong, known, owner) }.isFailure)
        }
        assertTrue(runCatching { AccountFileProfileMaterial.project(material, known, vectors.text("child")) }.isFailure)
    }
}
