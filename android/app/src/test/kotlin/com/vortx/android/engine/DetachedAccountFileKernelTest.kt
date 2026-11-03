package com.vortx.android.engine

import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

/** SYNTHETIC binding results prove orchestration, exact action slices and cleanup only.
 * They are not JNI, serde, native causal receipt or checkpoint proof. Authored, UNRUN. */
class DetachedAccountFileKernelTest {
    private val owner = "00000000-0000-0000-0000-00000000A11C"
    private val scope = VortxAccountScope("account.synthetic", owner)
    private val material = OHJson.literal("{\"schemaVersion\":1,\"roster\":[],\"future\":1.2300}")
    private fun native(): ByteArray = OHJson.Obj().set("schemaVersion", OHJson.literal("1"))
        .set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(owner))
        .set("profiles", OHJson.literal("{}")).set("addons", OHJson.literal("{}"))
        .set("libraries", OHJson.literal("{}")).set("watches", OHJson.literal("{}"))
        .set("legacyImport", OHJson.literal("{\"schemaVersion\":1,\"baseline\":{\"schemaVersion\":1}}"))
        .set("future", OHJson.literal("{ \"n\":9007199254740991.123,\"space\":\" kept \" }")).encoded()

    private inner class Bindings : VortxRuntimeBindings {
        var created = 0; var freed = 0
        val live = linkedMapOf<Long, OHJson.Obj>()
        val actions = arrayListOf<Pair<Long, OHJson.Obj>>()
        var onDispatch: ((String) -> Unit)? = null
        var refuse: Set<String> = emptySet()
        var malformedReply: String? = null
        var stripUnknownNative = false
        var wrongOwner = false
        override fun create(ownerId: String, ownerName: String): Long {
            val id = (++created).toLong()
            val profile = OHJson.Obj().set("id", OHJson.quote(ownerId)).set("name", OHJson.quote(ownerName))
                .set("owner", OHJson.literal("true")).set("deleted", OHJson.literal("false"))
            live[id] = OHJson.Obj().set("roster", OHJson.Obj().set("profiles", OHJson.Obj().set(ownerId, profile.encoded()).encoded()).encoded())
                .set("activeProfileId", OHJson.quote(ownerId)).set("libraries", OHJson.Obj().set(ownerId, OHJson.literal("{}")).encoded())
                .set("nativeSync", native())
            return id
        }
        override fun dispatch(handle: Long, action: String): String {
            val parsed = OHJson.Obj(action.toByteArray()); val type = parsed.text("type"); actions.add(handle to parsed)
            onDispatch?.invoke(type)
            if (type in refuse) return "{\"ok\":false,\"error\":\"synthetic refusal\"}"
            val state = requireNotNull(live[handle])
            when (type) {
                "bind_sync_scope" -> state.set("nativeSync", state.obj("nativeSync").set("scope", parsed.raw("scope")).encoded())
                "merge_native_sync" -> {
                    val raw = parsed.obj("document"); if (stripUnknownNative) raw.remove("future")
                    state.set("nativeSync", raw.encoded())
                }
                "import_legacy_sync", "reconcile_legacy_sync" -> {
                    val receipt = OHJson.Obj().set("schemaVersion", parsed.obj("material").raw("schemaVersion")).set("baseline", parsed.raw("material"))
                    state.set("nativeSync", state.obj("nativeSync").set("legacyImport", receipt.encoded()).encoded())
                }
                else -> error("Unexpected cold action")
            }
            return malformedReply ?: "{\"ok\":true}"
        }
        override fun state(handle: Long): String {
            val state = requireNotNull(live[handle]).copy()
            if (wrongOwner) state.set("nativeSync", state.obj("nativeSync").set("ownerProfileId", OHJson.quote("wrong")).encoded())
            return OHJson.utf8(state.encoded())
        }
        override fun free(handle: Long) { check(live.remove(handle) != null); freed++ }
        override fun hydrate(snapshot: String): Long = error("Cold file helper must not hydrate a live snapshot")
        override fun resolve(handle: Long, request: String): String? = error("No read/ACK capability is used")
        override fun delta(handle: Long): String? = error("No delta drain is permitted")
    }
    private fun refuses(action: () -> Unit) { assertTrue(runCatching(action).isFailure) }

    @Test fun importAndIndependentReplayUseDifferentHandlesAndExactMaterial() {
        val bindings = Bindings()
        val imported = DetachedAccountFileKernel.legacySync(scope, "[RD] Owner", material, bindings) {}
        assertEquals(1, bindings.created); assertEquals(1, bindings.freed)
        DetachedAccountFileKernel.requireLegacyReplay(scope, "[RD] Owner", imported, material, bindings) {}
        assertEquals(2, bindings.created); assertEquals(2, bindings.freed); assertTrue(bindings.live.isEmpty())
        assertEquals(listOf("bind_sync_scope", "import_legacy_sync", "bind_sync_scope", "merge_native_sync", "import_legacy_sync"),
            bindings.actions.map { it.second.text("type") })
        val imports = bindings.actions.filter { it.second.text("type") == "import_legacy_sync" }
        assertNotEquals(imports[0].first, imports[1].first)
        imports.forEach { assertArrayEquals(material, it.second.raw("material")) }
        assertArrayEquals(imported, bindings.actions.single { it.second.text("type") == "merge_native_sync" }.second.raw("document"))
    }

    @Test fun coldStateNeverMutatesOriginalNativeBytesOrReexportsNormalizedUnknowns() {
        val bindings = Bindings().apply { stripUnknownNative = true }
        val selected = native(); val original = selected.copyOf()
        val state = DetachedAccountFileKernel.fileRestoreState(scope, selected, bindings) {}
        assertArrayEquals(original, selected)
        assertNotNull(OHJson.Obj(selected)["future"])
        assertNull(OHJson.Obj(state).obj("nativeSync")["future"])
        assertArrayEquals(selected, bindings.actions.single { it.second.text("type") == "merge_native_sync" }.second.raw("document"))
        assertEquals(1, bindings.freed)
    }

    @Test fun replayRefusalUsesRealReconcileActionAndHeldOrMalformedResultsFail() {
        val accepted = Bindings().apply { refuse = setOf("import_legacy_sync") }
        DetachedAccountFileKernel.requireLegacyReplay(scope, "Owner", native(), material, accepted) {}
        assertEquals("reconcile_legacy_sync", accepted.actions.last().second.text("type")); assertEquals(1, accepted.freed)
        val held = Bindings().apply { refuse = setOf("import_legacy_sync", "reconcile_legacy_sync") }
        refuses { DetachedAccountFileKernel.requireLegacyReplay(scope, "Owner", native(), material, held) {} }
        assertEquals(1, held.freed); assertTrue(held.live.isEmpty())
        for (reply in listOf("{\"ok\":\"true\"}", "{\"ok\":1}", "{\"ok\":true,\"ok\":false}", "{}")) {
            val malformed = Bindings().apply { malformedReply = reply }
            refuses { DetachedAccountFileKernel.legacySync(scope, "Owner", material, malformed) {} }
            assertEquals(1, malformed.freed)
        }
    }

    @Test fun cancellationBeforeOrAfterEveryBoundaryClosesActualAllocatedHandle() {
        for (stopAt in 1..10) {
            val bindings = Bindings(); var checks = 0
            refuses { DetachedAccountFileKernel.legacySync(scope, "Owner", material, bindings) {
                if (++checks == stopAt) throw CancellationException("synthetic original operation retired")
            } }
            assertEquals("Boundary $stopAt", bindings.created, bindings.freed); assertTrue(bindings.live.isEmpty())
        }
        val bindings = Bindings(); var current = true
        bindings.onDispatch = { if (it == "import_legacy_sync") current = false }
        refuses { DetachedAccountFileKernel.legacySync(scope, "Owner", material, bindings) { check(current) } }
        assertEquals(1, bindings.freed)
        assertTrue(bindings.actions.none { it.second.text("type") == "reconcile_legacy_sync" })
    }

    @Test fun typedUnknownScopeAndMissingReceiptCannotBecomeGenericImportAuthority() {
        for (candidate in listOf(OHJson.Obj(native()).set("schemaVersion", OHJson.literal("6")).encoded(),
            OHJson.Obj(native()).set("ownerHistory", OHJson.literal("null")).encoded(),
            OHJson.Obj(native()).set("scope", OHJson.quote("other")).encoded(),
            OHJson.Obj(native()).set("schemaVersion", OHJson.literal("1.0")).encoded())) {
            val bindings = Bindings()
            refuses { DetachedAccountFileKernel.fileRestoreState(scope, candidate, bindings) {} }
            assertEquals(0, bindings.created)
        }
        val missing = Bindings()
        refuses { DetachedAccountFileKernel.requireLegacyReplay(scope, "Owner", OHJson.Obj(native()).remove("legacyImport").encoded(), material, missing) {} }
        assertEquals(1, missing.freed)
        val wrong = Bindings().apply { wrongOwner = true }
        refuses { DetachedAccountFileKernel.legacySync(scope, "Owner", material, wrong) {} }
        assertEquals(1, wrong.freed)
    }

    private fun padded(raw: ByteArray, length: Int): ByteArray {
        require(raw.size <= length)
        return ByteArray(length) { 0x20 }.also { raw.copyInto(it) }
    }

    @Test fun oversizedSelectedInputsRefuseBeforeBindingsOrCurrentChecks() {
        val maximum = 5 * 1024 * 1024
        val tooLargeNative = padded(native(), maximum + 1)
        val tooLargeMaterial = padded(material, maximum + 1)
        val invalidTooLarge = ByteArray(maximum + 1) { 0x21 }
        for (payload in listOf(tooLargeMaterial, invalidTooLarge)) {
            val bindings = Bindings(); var checks = 0
            val failure = runCatching { DetachedAccountFileKernel.legacySync(scope, "Owner", payload, bindings) { checks++ } }.exceptionOrNull()
            assertEquals("Cold account input exceeds limit", failure?.message)
            assertEquals(0, bindings.created); assertTrue(bindings.actions.isEmpty()); assertEquals(0, checks)
        }
        for (payload in listOf(tooLargeNative, invalidTooLarge)) {
            val bindings = Bindings(); var checks = 0
            val failure = runCatching { DetachedAccountFileKernel.fileRestoreState(scope, payload, bindings) { checks++ } }.exceptionOrNull()
            assertEquals("Cold account input exceeds limit", failure?.message)
            assertEquals(0, bindings.created); assertTrue(bindings.actions.isEmpty()); assertEquals(0, checks)
        }
        // Both arguments are bounded before either is parsed: malformed small opposite input
        // cannot mask the oversized input refusal, and neither order may allocate a handle.
        val malformedSmall = OHJson.literal("!")
        for ((nativeInput, materialInput) in listOf(tooLargeNative to material, native() to tooLargeMaterial,
            malformedSmall to tooLargeMaterial, tooLargeNative to malformedSmall, invalidTooLarge to invalidTooLarge)) {
            val bindings = Bindings(); var checks = 0
            val failure = runCatching { DetachedAccountFileKernel.requireLegacyReplay(scope, "Owner", nativeInput, materialInput, bindings) { checks++ } }.exceptionOrNull()
            assertEquals("Cold account input exceeds limit", failure?.message)
            assertEquals(0, bindings.created); assertTrue(bindings.actions.isEmpty()); assertEquals(0, checks)
        }
    }

    @Test fun exactLimitValidJsonIsNotRejectedBySyntheticBoundaryChecks() {
        val maximum = 5 * 1024 * 1024
        val selectedNative = padded(native(), maximum)
        val selectedMaterial = padded(material, maximum)
        val beforeNative = selectedNative.copyOf(); val beforeMaterial = selectedMaterial.copyOf()
        val bindings = Bindings()
        DetachedAccountFileKernel.legacySync(scope, "Owner", selectedMaterial, bindings) {}
        DetachedAccountFileKernel.fileRestoreState(scope, selectedNative, bindings) {}
        DetachedAccountFileKernel.requireLegacyReplay(scope, "Owner", selectedNative, selectedMaterial, bindings) {}
        assertEquals(3, bindings.created); assertEquals(3, bindings.freed); assertTrue(bindings.live.isEmpty())
        assertArrayEquals(beforeNative, selectedNative); assertArrayEquals(beforeMaterial, selectedMaterial)
        // These synthetic native/material objects prove boundary mechanics only. The opt-in JNI
        // test separately pads actual admitted material and actual kernel-produced native state.
    }

}
