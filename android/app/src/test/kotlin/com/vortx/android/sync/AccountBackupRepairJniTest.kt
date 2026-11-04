package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxCore
import com.vortx.android.engine.VortxRuntimeBindings
import java.io.File
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Actual generic JNI + actual crypto/converter, only synthetic accounts. No mounted session,
 * account credentials, network, files beyond the explicitly selected library, ACK or checkpoint.
 * Authored UNRUN. Root requires the explicit artifact SHA and zero skips for this gate. */
class AccountBackupRepairJniTest {
    @Test fun actualConversionAndSelectedNativeReimportKeepSourceAndParentalPolicy() {
        assumeTrue("Explicit reviewed generic JNI gate required", System.getenv("VORTX_JNI_FILE_ADMISSION") == "1")
        val library = File(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        val expectedSHA = requireNotNull(System.getenv("VORTX_JNI_SHA256"))
        require(library.isAbsolute && library.isFile && Regex("[0-9a-f]{64}").matches(expectedSHA))
        assertEquals(expectedSHA, OHJson.sha(library.readBytes()))
        System.load(library.absolutePath)
        val live = hashSetOf<Long>(); var created = 0; var freed = 0
        val bindings = object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String): Long {
                val handle = VortxCore.nativeInitRuntime(OHJson.utf8(OHJson.Obj()
                    .set("ownerId", OHJson.quote(ownerId)).set("ownerName", OHJson.quote(ownerName)).encoded()))
                require(handle != 0L && live.add(handle)); created++; return handle
            }
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun free(handle: Long) { require(live.remove(handle)); VortxCore.nativeEngineFree(handle); freed++ }
            override fun hydrate(snapshot: String): Long = error("No live checkpoint hydration")
            override fun resolve(handle: Long, request: String): String? = error("No NativeRead/ACK")
            override fun delta(handle: Long): String? = error("No delta drain")
        }
        val f = AccountBackupRepairFixture
        val source = f.source(); val file = f.file(source, v2 = false)
        f.context().use { context ->
            val converted = AccountBackupRepair.convert(file, context, bindings) {}.use { result ->
                assertEquals(OHJson.sha(file), result.sourceSHA256)
                assertTrue(result.nativeSchema in 1..5); assertEquals(2, result.profileCount)
                result.fileBytes()
            }
            val plaintext = f.plaintext(converted); val candidate = OHJson.Obj(plaintext); val original = OHJson.Obj(source)
            original.keys.forEach { assertArrayEquals(original.raw(it), candidate.raw(it)) }
            val native = candidate.obj("nativeSync")
            assertEquals("account.${f.account}", native.text("scope")); assertEquals(f.owner, native.text("ownerProfileId"))
            val baseline = native.obj("legacyImport").obj("baseline")
            val profiles = OHJson.array(baseline.raw("roster")).map { OHJson.Obj(it) }
            val kid = profiles.single { it.text("id") == f.child }
            assertEquals("[RD] Viewer", kid.text("name")); assertEquals("shared", kid.obj("account").text("kind"))
            assertEquals(f.owner, kid.obj("account").text("value"))
            assertEquals("true", OHJson.utf8(kid.obj("parental").raw("kids")))
            assertEquals("true", OHJson.utf8(kid.obj("parental").raw("familyEdit")))
            assertEquals("sha256:" + "a".repeat(64), kid.text("pin"))
            // Unknown selected native values remain exact even if the kernel normalizes its
            // own cold state. This is not a claim that this synthetic field is causal history.
            val selected = f.replaceCandidate(converted) { value -> value.set("nativeSync", value.obj("nativeSync")
                .set("futureNative", OHJson.literal("{ \"precise\":1.2300 }")).encoded()) }
            val selectedBefore = selected.copyOf()
            AccountBackupRepair.validateReimport(selected, context, bindings) {}.use { reimport ->
                assertEquals(AccountBackupRepair.Disposition.VALIDATED_EXISTING_CANDIDATE, reimport.disposition)
                assertArrayEquals(selectedBefore, reimport.fileBytes())
                assertArrayEquals(OHJson.Obj(f.plaintext(selectedBefore)).raw("nativeSync"),
                    OHJson.Obj(f.plaintext(reimport.fileBytes())).raw("nativeSync"))
            }
            assertArrayEquals(selectedBefore, selected)
        }
        assertEquals(7, created); assertEquals(created, freed); assertTrue(live.isEmpty())
        assertEquals(expectedSHA, OHJson.sha(library.readBytes()))
    }
}
