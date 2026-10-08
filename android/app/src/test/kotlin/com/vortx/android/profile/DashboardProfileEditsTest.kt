package com.vortx.android.profile

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DashboardProfileEditsTest {
    private val id = "00000000-0000-0000-0000-000000000001"
    private fun edits(row: String, stamp: Double = 200000.0) = JSONObject("""{"editedAt":$stamp,"roster":[$row]}""")

    @Test fun partialEditPreservesOwnAccountAndOmittedFields() {
        val original = UserProfile(id = id, name = "Old", avatar = "🌙", usesOwnAccount = true,
            email = "fixture@example.invalid", pin = "stored-hash")
        val patch = edits("""{"id":"$id","name":" New ","settings":{"avatar":"🚀","accent":"ocean","playback":{"audioLang":"en","forced":"always","maxResolution":2160}}}""")
        val result = DashboardProfileEdits.apply(listOf(original), emptySet(), 100.0, patch)
        val updated = result.profiles.single()
        assertEquals("New", updated.name)
        assertEquals("🚀", updated.avatar)
        assertEquals("ocean", updated.accentID)
        assertTrue(updated.usesOwnAccount)
        assertEquals(original.email, updated.email)
        assertEquals(original.pin, updated.pin)
        assertEquals("en", updated.playback?.audioLang)
        assertEquals("always", updated.playback?.forcedPolicy)
        assertEquals(4000, updated.playback?.maxResolution)
        assertEquals(200.0, result.modified, 0.0)
        assertEquals(result.profiles, DashboardProfileEdits.apply(result.profiles, emptySet(), result.modified, patch).profiles)
    }

    @Test fun createAndExplicitClearsWork() {
        val created = DashboardProfileEdits.apply(emptyList(), emptySet(), 0.0,
            edits("""{"id":"$id","name":"New","pin":"hash","settings":{"avatar":"🌻","oled":true}}""")).profiles.single()
        assertFalse(created.isOwner)
        assertFalse(created.usesOwnAccount)
        assertTrue(created.oled)
        assertEquals("🌻", created.avatar)
        val clear = DashboardProfileEdits.apply(listOf(created.copy(disabledAddons = listOf("addon"))), emptySet(), 200.0,
            edits("""{"id":"$id","pin":null,"disabledAddons":[]}""", 300000.0)).profiles.single()
        assertNull(clear.pin)
        assertNull(clear.disabledAddons)
    }

    @Test fun staleNativeFieldsStayButNewIdsAndDeletesPropagate() {
        val current = UserProfile(id = id, name = "Native newer", avatar = "🌙")
        assertEquals(current, DashboardProfileEdits.apply(listOf(current), emptySet(), 300.0,
            edits("""{"id":"$id","name":"Stale"}""")).profiles.single())
        val deletion = DashboardProfileEdits.apply(listOf(current), emptySet(), 300.0,
            edits("""{"id":"$id","deleted":true},{"id":"${UserProfile.OWNER_ID}","deleted":true}"""))
        assertEquals(setOf(id), deletion.deletedIDs)
        assertTrue(deletion.profiles.isEmpty())
        assertTrue(DashboardProfileEdits.apply(emptyList(), setOf(id), 300.0,
            edits("""{"id":"$id","name":"Resurrection"}""")).profiles.isEmpty())
        assertTrue(DashboardProfileEdits.apply(emptyList(), emptySet(), 0.0,
            edits("""{"id":"1-1-1-1-1","name":"Invalid"}""")).profiles.isEmpty())
    }

    @Test fun lossySummaryCannotStripLocalAccountOrDonateItsClock() {
        val full = UserProfile(id = id, name = "Full", avatar = "🌙", usesOwnAccount = true, pin = "hash")
        val summary = full.copy(usesOwnAccount = false, pin = null)
        assertTrue(DashboardProfileEdits.safeIncoming(listOf(full), listOf(summary), false).isEmpty())
        assertEquals(listOf(summary), DashboardProfileEdits.safeIncoming(listOf(full), listOf(summary), true))
    }

    @Test fun invalidClockAndLibraryOnlyNeverChangeRoster() {
        val full = UserProfile(id = id, name = "Full", avatar = "🌙")
        val invalid = JSONObject("""{"editedAt":true,"roster":[{"id":"$id","name":"Bad"}]}""")
        assertEquals(listOf(full), DashboardProfileEdits.apply(listOf(full), emptySet(), 100.0, invalid).profiles)
        val library = JSONObject("""{"editedAt":200000,"libraryAdds":{"$id":[{"id":"ttfixture"}]}}""")
        assertEquals(listOf(full), DashboardProfileEdits.apply(listOf(full), emptySet(), 100.0, library).profiles)
        assertTrue(library.has("libraryAdds"))
    }

    @Test fun oldMirrorEditAndMalformedFieldsCannotUndoStoredProfile() {
        val full = UserProfile(id = id, name = "Native", avatar = "🌙", disabledAddons = listOf("kept"))
        val stale = edits("""{"id":"$id","name":"Stale"}""", 1500.0)
        assertEquals(full, DashboardProfileEdits.apply(listOf(full), emptySet(), 0.0, stale, 2000.0).profiles.single())
        val malformed = edits("""{"id":"$id","settings":{"playback":{"maxResolution":"bad"}}}""")
        val rejected = DashboardProfileEdits.apply(listOf(full), emptySet(), 0.0, malformed)
        assertEquals(full, rejected.profiles.single())
        assertEquals(0.0, rejected.modified, 0.0)
        val corrected = edits("""{"id":"$id","name":"Corrected"}""")
        assertEquals("Corrected", DashboardProfileEdits.apply(rejected.profiles, emptySet(),
            rejected.modified, corrected).profiles.single().name)
        val badAddons = edits("""{"id":"$id","disabledAddons":[7]}""")
        assertEquals(full.disabledAddons,
            DashboardProfileEdits.apply(listOf(full), emptySet(), 0.0, badAddons).profiles.single().disabledAddons)
        assertEquals(0.0, DashboardProfileEdits.apply(listOf(full), emptySet(), 0.0, badAddons).modified, 0.0)
        assertEquals(200.0, DashboardProfileEdits.apply(listOf(full), emptySet(), 0.0,
            edits("""{"id":"$id","name":"Native"}""")).modified, 0.0)
    }
}
