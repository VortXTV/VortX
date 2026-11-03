package com.vortx.android.sync

import com.vortx.android.backup.AccountFilePlist
import com.vortx.android.backup.BinaryPlist
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

/** Actual pure admission/material/parser sources, synthetic account bytes. No JNI, credentials,
 * account, network or persistence. Authored but UNRUN in the proposal task. */
class AccountFileLegacyAdmissionTest {
    private val owner = "00000000-0000-0000-0000-00000000A11C"
    private val child = "10000000-0000-0000-0000-000000000001"
    private val pin = "sha256:" + "a".repeat(64)
    private val scope = VortxAccountScope("account.synthetic", owner)
    private fun profile(id: String = owner, main: Boolean = true, kids: Boolean = false): ByteArray =
        """{"id":"$id","name":"[RD] Viewer","avatar":"🍿","accentID":"ember","oled":false,"textScale":1.0,"usesOwnAccount":false,"isOwner":$main,"familyEdit":$kids,"isKids":$kids,"pin":"$pin"}""".toByteArray()
    private fun rows() = OHJson.array(listOf(profile(), profile(child, false, true)))
    private fun full(roster: ByteArray = rows(), clock: String? = "10.25"): ByteArray {
        val carrier = OHJson.Obj().set("roster", roster)
        clock?.let { carrier.set("rosterModified", OHJson.literal(it)) }
        return OHJson.Obj().set("vortx", carrier.encoded()).encoded()
    }
    private fun settings(roster: ByteArray = rows(), clock: Any? = 10.25, extra: Map<String, Any> = emptyMap()): ByteArray {
        val domain = linkedMapOf<String, Any>("stremiox.profiles" to roster); clock?.let { domain["stremiox.profiles.modified"] = it }
        domain.putAll(extra)
        return settingsPayload(requireNotNull(BinaryPlist.encode(domain)))
    }
    private fun settingsPayload(payload: ByteArray): ByteArray = OHJson.quote(OHJson.b64(OHJson.Obj()
        .set("format", OHJson.quote("vortx-backup")).set("schema", OHJson.literal("1"))
        .set("payloadBase64", OHJson.quote(OHJson.b64(payload))).encoded()))
    private fun admit(bytes: ByteArray) = AccountFileLegacyAdmission.admitLegacy(bytes, owner)
    private fun refuses(action: () -> Unit) { assertTrue("Expected strict admission refusal", runCatching(action).isFailure) }

    @Test fun bothFullCarriersAndSettingsOnlyRetainRawValuesAndParentalPolicy() {
        val source = OHJson.Obj(full()).set("settings", settings())
            .set("apiKeys", OHJson.literal("""{ "futureCredential":"synthetic-only" }"""))
            .set("future", OHJson.literal("""{ "number":9007199254740991.123, "lexeme":1e300, "nativeSync":null }"""))
            .encoded()
        for (bytes in listOf(source, OHJson.Obj().set("settings", settings()).encoded(), full())) {
            val admitted = admit(bytes)
            assertEquals(owner, admitted.ownerProfileID); assertEquals(2, admitted.profileCount)
            assertEquals(10.25, admitted.modifiedSeconds!!, 0.0)
            assertArrayEquals(bytes, admitted.originalPlaintext())
            admitted.originalPlaintext().fill(0); assertArrayEquals(bytes, admitted.originalPlaintext())
            val material = OHJson.Obj(admitted.prepareMaterial(scope))
            val profiles = OHJson.array(material.raw("roster")).map { OHJson.Obj(it) }
            val kid = profiles.single { it.text("id") == child }
            assertEquals("shared", kid.obj("account").text("kind")); assertEquals(owner, kid.obj("account").text("value"))
            assertEquals("true", OHJson.utf8(kid.obj("parental").raw("kids")))
            assertEquals("true", OHJson.utf8(kid.obj("parental").raw("familyEdit"))); assertEquals(pin, kid.text("pin"))
            assertEquals("[RD] Viewer", kid.text("name"))
            // This method proves conservation only. Synthetic native is intentionally NOT kernel admission.
            val next = OHJson.Obj(admitted.addingNativeSync(OHJson.literal("{\"synthetic\":true}")))
            val original = OHJson.Obj(bytes)
            assertEquals(original.keys + "nativeSync", next.keys)
            original.keys.forEach { assertArrayEquals(original.raw(it), next.raw(it)) }
        }
    }

    @Test fun allPresentCarriersMustBeValidAndAgreeIncludingClockAndKnownOptionals() {
        for (bad in listOf("null", "7", "\"bad\"", "{}")) {
            refuses { admit(OHJson.Obj(full()).set("settings", OHJson.literal(bad)).encoded()) }
            if (bad != "{}") refuses { admit(OHJson.Obj().set("settings", settings()).set("vortx", OHJson.literal(bad)).encoded()) }
        }
        assertEquals(2, admit(OHJson.Obj().set("settings", settings()).set("vortx", OHJson.literal("{}")).encoded()).profileCount)
        refuses { admit(OHJson.Obj(full()).set("settings", settings(clock = 11.0)).encoded()) }
        refuses { admit(OHJson.Obj(full()).set("settings", settings(clock = null)).encoded()) }
        refuses { admit(full(clock = "null")) }; refuses { admit(full(clock = "true")) }
        refuses { admit(full(clock = "9007199254740991.1")) }
        refuses { admit(OHJson.Obj(full()).set("settings", settings(clock = 9007199254740993L)).encoded()) }
        val changed = OHJson.array(listOf(OHJson.Obj(profile()).set("isKids", OHJson.literal("true")).encoded(), profile(child, false, true)))
        refuses { admit(OHJson.Obj(full()).set("settings", settings(changed)).encoded()) }
        val absentClock = OHJson.Obj().set("settings", settings(clock = null)).set("vortx", OHJson.Obj(full(clock = null)).raw("vortx")).encoded()
        assertNull(admit(absentClock).modifiedSeconds)
        assertEquals(owner, admit(OHJson.Obj(full(clock = "10.0")).set("settings", settings(clock = 10L)).encoded()).ownerProfileID)
        // Unknown siblings can differ: both remain raw and neither becomes typed authority.
        val unknown = OHJson.array(listOf(OHJson.Obj(profile()).set("future", OHJson.literal("1e300")).encoded(), profile(child, false, true)))
        assertEquals(2, admit(OHJson.Obj(full()).set("settings", settings(unknown)).encoded()).profileCount)
    }

    @Test fun malformedPresentRosterNeverFallsBackAndSummaryCannotSupplyAuthority() {
        val validSettings = OHJson.Obj().set("settings", settings())
        for (bad in listOf("null", "{}", "[]", "\"bad\"")) {
            refuses { admit(validSettings.copy().set("vortx", OHJson.Obj().set("roster", OHJson.literal(bad)).encoded()).encoded()) }
        }
        refuses { admit(OHJson.Obj().set("vortx", OHJson.literal("{\"profiles\":[{\"id\":\"$owner\",\"name\":\"Summary\"}]}")).encoded()) }
        refuses { admit(OHJson.Obj().set("settings", settingsPayload(requireNotNull(BinaryPlist.encode(mapOf("stremiox.profiles.modified" to 10.0))))).encoded()) }
        refuses { admit(OHJson.Obj(full()).set("settings", settingsPayload(requireNotNull(BinaryPlist.encode(mapOf("stremiox.profiles" to "not data"))))).encoded()) }
    }

    @Test fun noKnownFieldCoercionDefaultsRandomIDsOrRoundedNumbers() {
        for (key in listOf("id", "name", "avatar", "accentID", "oled", "textScale", "usesOwnAccount", "isOwner", "familyEdit", "isKids")) {
            refuses { admit(full(OHJson.array(listOf(OHJson.Obj(profile()).remove(key).encoded())))) }
            refuses { admit(full(OHJson.array(listOf(OHJson.Obj(profile()).set(key, OHJson.literal("null")).encoded())))) }
        }
        for ((key, value) in listOf("isOwner" to "\"true\"", "textScale" to "1.00000000000000001", "textScale" to "1e999",
            "familyEdit" to "1", "disabledAddons" to "[7]", "pin" to "\"1234\"", "id" to "\"bad\"")) {
            refuses { admit(full(OHJson.array(listOf(OHJson.Obj(profile()).set(key, OHJson.literal(value)).encoded())))) }
        }
        refuses { admit(full(OHJson.array(listOf(profile(), profile())))) }
        refuses { admit(full(OHJson.array(listOf(profile(), profile(child, true))))) }
        refuses { AccountFileLegacyAdmission.admitLegacy(full(), child) }
        refuses { admit(OHJson.literal("{\"vortx\":{},\"vortx\":{}}")) }
        refuses { admit(OHJson.Obj(full()).set("future", OHJson.literal("{\"é\":1,\"e\\u0301\":2}")).encoded()) }
        val withApplePreferences = OHJson.Obj(profile()).set("addonPreferences", OHJson.literal("""{"rankingOverride":{"sourceTypeOrder":["future"],"useAddonOrder":false,"addonOrder":[]}}"""))
            .set("discovery", OHJson.literal("""{"selectedProviders":[9223372036854775807],"filtersData":"e30="}"""))
        assertEquals(1, admit(full(OHJson.array(listOf(withApplePreferences.encoded())))).profileCount)
        refuses { admit(full(OHJson.array(listOf(withApplePreferences.copy().set("addonPreferences", OHJson.literal("{\"rankingOverride\":{}}")).encoded())))) }
        val playback = OHJson.literal("""{"audioLang":"en","subtitleLang":"fr","forcedPolicy":"auto","subFont":"default","subSize":"100","subColor":"white","subBackground":"none","titleMatchThreshold":71,"maxResolution":9223372036854775807}""")
        // The UI decoder would normalize/narrow these. Material consumes only validated languages;
        // the complete known preferences and original bytes remain intact, with no fabricated default.
        val source = full(OHJson.array(listOf(OHJson.Obj(profile()).set("playback", playback).encoded())))
        assertArrayEquals(source, admit(source).originalPlaintext())
        val material = OHJson.Obj(admit(source).prepareMaterial(scope))
        val languages = OHJson.Obj(OHJson.array(material.raw("roster")).single()).obj("settings").raw("languages")
        assertEquals(listOf("en", "fr"), OHJson.array(languages).map(OHJson::text))
    }

    @Test fun knownRecoverySidecarsIndependentAccountsHeldAndPendingSourcesRefuseMaterial() {
        for (key in listOf("nativeSync", "nativeHostPreferences", "nativeProviderCredentials", "nativeOwnerHistorySources",
            "ownAccountSources", "ownAccountOverlayPending", "nativeLegacyMembershipPending", "hostDocument", "authenticatedSourceArchive",
            "authenticatedOwnAccountSources", "nativeOwnAccountPending", "nativeOwnAccountCandidates", "nativeWatchlistMigrationPending",
            "websiteProfileEditPending", "websiteAddonEditPending", "nativeHostPreferenceState", "legacyWebsiteBootstrap")) {
            refuses { admit(OHJson.Obj(full()).set(key, OHJson.literal("null")).encoded()) }
            refuses { admit(OHJson.Obj(full()).set("vortx", OHJson.Obj(OHJson.Obj(full()).raw("vortx")).set(key, OHJson.literal("null")).encoded()).encoded()) }
            refuses { admit(OHJson.Obj(full()).set("settings", settings(extra = mapOf(key to true))).encoded()) }
        }
        val independent = full(OHJson.array(listOf(profile(), OHJson.Obj(profile(child, false)).set("usesOwnAccount", OHJson.literal("true")).encoded())))
        refuses { admit(independent).prepareMaterial(scope) }
        for (key in listOf("profileEdits", "profileEditEvents", "webAddonEdits"))
            refuses { admit(OHJson.Obj(full()).set(key, OHJson.literal("null")).encoded()).prepareMaterial(scope) }
        for ((key, value) in listOf("addons" to """[{"transportUrl":"https://fixture.invalid/manifest.json","name":"old"}]""",
            "deletedAddonsTs" to """{"https://fixture.invalid/manifest.json":{"addedAt":1000.75}}""")) {
            val source = OHJson.Obj(full()); source.set("vortx", source.obj("vortx").set(key, OHJson.literal(value)).encoded())
            refuses { admit(source.encoded()).prepareMaterial(scope) }
        }
    }

    @Test fun standardXMLAndUTF16PlistsAreAdmittedWithoutNetworkAndDataStaysData() {
        val xml = """<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>stremiox.profiles</key><data>${OHJson.b64(rows())}</data><key>stremiox.profiles.modified</key><real>10.25</real><key>future</key><string><![CDATA[<!ENTITY harmless text>]]></string></dict></plist>"""
        for (bytes in listOf(xml.toByteArray(), xml.replace("UTF-8", "UTF-16").toByteArray(Charsets.UTF_16)))
            assertEquals(2, admit(OHJson.Obj().set("settings", settingsPayload(bytes)).encoded()).profileCount)
        for (bad in listOf("<plist><dict><key>x</key><true/><key>x</key><false/></dict></plist>",
            "<plist><dict><key>é</key><true/><key>e&#769;</key><false/></dict></plist>",
            "<!DOCTYPE plist [<!ENTITY x 'expanded'>]><plist><dict><key>x</key><string>&x;</string></dict></plist>",
            "<!DOCTYPE plist SYSTEM 'file:///never-open'><plist><dict/></plist>",
            "<plist><dict><key>x</key><array>" + "<array>".repeat(65) + "<true/>" + "</array>".repeat(65) + "</array></dict></plist>"))
            refuses { AccountFilePlist.decode(bad.toByteArray()) }
        val number = AccountFilePlist.decode("<plist><dict><key>x</key><integer>0xFFFFFFFFFFFFFFFF</integer></dict></plist>".toByteArray())["x"]
        assertEquals(BigInteger("18446744073709551615"), number)
    }

    /** Tiny raw bplist fixture writer allows duplicate keys/references the production writer cannot emit. */
    private fun binary(objects: List<ByteArray>): ByteArray {
        val out = ByteArrayOutputStream(); out.write("bplist00".toByteArray()); val offsets = arrayListOf<Int>()
        objects.forEach { offsets.add(out.size()); out.write(it) }; val table = out.size()
        fun number(value: Long, width: Int) { for (i in width - 1 downTo 0) out.write(((value ushr (i * 8)) and 255).toInt()) }
        offsets.forEach { number(it.toLong(), 4) }; repeat(6) { out.write(0) }; out.write(4); out.write(1)
        number(objects.size.toLong(), 8); number(0, 8); number(table.toLong(), 8); return out.toByteArray()
    }
    @Test fun binaryRejectsDuplicatesCyclesDepthVisitsExpansionAndInvalidStringBounds() {
        refuses { AccountFilePlist.decode(binary(listOf(byteArrayOf(0xd2.toByte(), 1, 1, 2, 3), byteArrayOf(0x51, 120), byteArrayOf(8), byteArrayOf(9)))) }
        refuses { AccountFilePlist.decode(binary(listOf(byteArrayOf(0xd1.toByte(), 1, 0), byteArrayOf(0x51, 120)))) }
        fun graph(levels: Int, leaf: ByteArray): ByteArray {
            val objects = mutableListOf(byteArrayOf(0xd1.toByte(), 1, 2), byteArrayOf(0x51, 120))
            repeat(levels) { objects.add(byteArrayOf(0xa2.toByte(), (it + 3).toByte(), (it + 3).toByte())) }
            objects.add(leaf); return binary(objects)
        }
        refuses { AccountFilePlist.decode(graph(65, byteArrayOf(9))) }
        refuses { AccountFilePlist.decode(graph(17, byteArrayOf(9))) }
        refuses { AccountFilePlist.decode(graph(15, byteArrayOf(0x4f, 0x11, 4, 0) + ByteArray(1024))) }
        refuses { AccountFilePlist.decode(binary(listOf(byteArrayOf(0xd1.toByte(), 1, 2), byteArrayOf(0x51, 120), byteArrayOf(0x61, 0xd8.toByte(), 0)))) }
        refuses { AccountFilePlist.decode(binary(listOf(byteArrayOf(0xd1.toByte(), 1, 2), byteArrayOf(0x51, 120), byteArrayOf(0x4f, 0x13) + ByteArray(8) { 0xff.toByte() }))) }
        refuses { AccountFilePlist.decode(ByteArray(AccountFilePlist.MAX_BYTES + 1)) }
    }
}
