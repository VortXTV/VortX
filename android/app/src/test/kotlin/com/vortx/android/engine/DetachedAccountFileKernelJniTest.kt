package com.vortx.android.engine

import com.vortx.android.sync.AccountFileLegacyAdmission
import java.io.File
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in ACTUAL JNI, no mounted session, store, credentials, network or fake response. Authored
 * UNRUN. A skip is not proof. Root must pin library SHA and require zero skips for its native gate. */
class DetachedAccountFileKernelJniTest {
    private fun load(): VortxRuntimeBindings {
        assumeTrue("Explicit reviewed generic JNI gate required", System.getenv("VORTX_JNI_FILE_ADMISSION") == "1")
        val path = requireNotNull(System.getenv("VORTX_JNI_LIBRARY"))
        val expected = requireNotNull(System.getenv("VORTX_JNI_SHA256"))
        require(Regex("[0-9a-f]{64}").matches(expected))
        val file = File(path); require(file.isAbsolute && file.isFile)
        assertEquals("Reviewed native artifact hash", expected, OHJson.sha(file.readBytes()))
        System.load(file.absolutePath)
        // Direct forwarding to the existing actual production JNI symbols permits an explicit
        // host library path without pretending System.loadLibrary located a packaged Android .so.
        return object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(
                OHJson.utf8(OHJson.Obj().set("ownerId", OHJson.quote(ownerId)).set("ownerName", OHJson.quote(ownerName)).encoded()))
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
            override fun hydrate(snapshot: String): Long = error("No hydration path in this gate")
            override fun resolve(handle: Long, request: String): String? = error("No mounted read capability")
            override fun delta(handle: Long): String? = error("No delta drain")
        }
    }
    @Test fun actualLegacyImportSeparateReplayAndColdMergeRetainOwnerAndSharedKidsPolicy() {
        val bindings = load()
        val owner = "00000000-0000-0000-0000-00000000A11C"
        val child = "10000000-0000-0000-0000-000000000001"
        val scope = VortxAccountScope("account.file-jni-fixture", owner)
        val pin = "sha256:" + "a".repeat(64)
        fun row(id: String, main: Boolean, kids: Boolean) = OHJson.literal(
            """{"id":"$id","name":"[RD] Viewer","avatar":"🍿","accentID":"ember","oled":false,"textScale":1,"isOwner":$main,"usesOwnAccount":false,"familyEdit":$kids,"isKids":$kids,"pin":"$pin"}""")
        val source = OHJson.Obj().set("vortx", OHJson.Obj().set("roster", OHJson.array(listOf(row(owner, true, false), row(child, false, true))))
            .set("rosterModified", OHJson.literal("1720000000.25")).encoded())
            .set("future", OHJson.literal("{ \"unknown\":9007199254740991.123 }")).encoded()
        val admission = AccountFileLegacyAdmission.admitLegacy(source, owner)
        val material = admission.prepareMaterial(scope)
        val native = DetachedAccountFileKernel.legacySync(scope, admission.ownerName, material, bindings) {}
        DetachedAccountFileKernel.requireLegacyReplay(scope, admission.ownerName, native, material, bindings) {}
        val cold = OHJson.Obj(DetachedAccountFileKernel.fileRestoreState(scope, native, bindings) {})
        val profiles = cold.obj("roster").obj("profiles")
        val kid = profiles.obj(child)
        assertEquals("shared", kid.obj("account").text("kind")); assertEquals(owner, kid.obj("account").text("value"))
        assertEquals("true", OHJson.utf8(kid.obj("parental").raw("kids")))
        assertEquals("true", OHJson.utf8(kid.obj("parental").raw("familyEdit"))); assertEquals(pin, kid.text("pin"))
        assertEquals("true", OHJson.utf8(profiles.obj(owner).raw("owner")))
        assertEquals("[RD] Viewer", kid.text("name"))
        val receipt = OHJson.Obj(native).obj("legacyImport")
        assertEquals(OHJson.integer(OHJson.Obj(material).raw("schemaVersion")), OHJson.integer(receipt.raw("schemaVersion")))
        receipt["baseline"]?.let { baseline ->
            val rows = OHJson.array(OHJson.Obj(baseline).raw("roster")).map { OHJson.Obj(it) }
            val saved = rows.single { it.text("id") == child }
            assertEquals(pin, saved.text("pin")); assertEquals("true", OHJson.utf8(saved.obj("parental").raw("kids")))
            assertEquals("true", OHJson.utf8(saved.obj("parental").raw("familyEdit")))
        }
        val candidate = OHJson.Obj(admission.addingNativeSync(native)); val original = OHJson.Obj(source)
        original.keys.forEach { assertArrayEquals(original.raw(it), candidate.raw(it)) }
        assertArrayEquals(native, candidate.raw("nativeSync"))
        assertArrayEquals(source, admission.originalPlaintext())
        // Genuine accepted semantics at the inclusive boundary: actual material above and actual
        // native output above, padded only with legal JSON trailing whitespace. No fake carrier.
        val maximum = 5 * 1024 * 1024
        fun padded(raw: ByteArray): ByteArray {
            require(raw.size <= maximum)
            return ByteArray(maximum) { 0x20 }.also { raw.copyInto(it) }
        }
        val exactMaterial = padded(material); val exactNative = padded(native)
        val originalMaterial = exactMaterial.copyOf(); val originalNative = exactNative.copyOf()
        assertEquals(maximum, exactMaterial.size); assertEquals(maximum, exactNative.size)
        val exactImport = DetachedAccountFileKernel.legacySync(scope, admission.ownerName, exactMaterial, bindings) {}
        assertEquals(owner, OHJson.Obj(exactImport).text("ownerProfileId"))
        val exactCold = OHJson.Obj(DetachedAccountFileKernel.fileRestoreState(scope, exactNative, bindings) {})
        assertEquals(owner, exactCold.obj("nativeSync").text("ownerProfileId"))
        DetachedAccountFileKernel.requireLegacyReplay(scope, admission.ownerName, exactNative, exactMaterial, bindings) {}
        assertArrayEquals(originalMaterial, exactMaterial); assertArrayEquals(originalNative, exactNative)

    }
}
