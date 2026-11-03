package com.vortx.android.engine

/** Disposable GENERIC handles only. No coordinator, mounted session, read capability, archive,
 * checkpoint, ACK, floor, key, clock injection or delta drain. Native dispatch owns its real clock.
 * [checkCurrent] belongs to the caller's original operation and must throw on retirement/cancellation.
 * Fake bindings can verify call/cleanup discipline; only the real packaged JNI proves admission. */
internal object DetachedAccountFileKernel {
    private const val MAX_BYTES = 5 * 1024 * 1024

    fun legacySync(scope: VortxAccountScope, ownerName: String, material: ByteArray,
        bindings: VortxRuntimeBindings, checkCurrent: () -> Unit): ByteArray {
        requireInputSize(material)
        val originalMaterial = material.copyOf(); materialSchema(originalMaterial)
        return cold(scope, ownerName, bindings, checkCurrent) { runtime ->
            apply(runtime, legacyAction("import_legacy_sync", scope, originalMaterial), checkCurrent)
            val state = state(runtime, scope, checkCurrent)
            val native = OHJson.Obj(state).raw("nativeSync")
            generic(native, scope); requireReceipt(native, originalMaterial)
            native
        }
    }

    /** Return a scope-validated cold STATE for full host validation. Callers retain the original
     * native input, including unknown siblings; this normalized return never replaces source bytes. */
    fun fileRestoreState(scope: VortxAccountScope, originalNativeBytes: ByteArray,
        bindings: VortxRuntimeBindings, checkCurrent: () -> Unit): ByteArray {
        requireInputSize(originalNativeBytes)
        val native = originalNativeBytes.copyOf(); generic(native, scope)
        return cold(scope, "Owner", bindings, checkCurrent) { runtime ->
            apply(runtime, action("merge_native_sync").set("document", native).encoded(), checkCurrent)
            state(runtime, scope, checkCurrent)
        }
    }

    /** Independent second runtime must accept this exact native carrier/material receipt, using
     * real import replay or the kernel's causal reconciliation. A held/unsupported result refuses.
     * This is compatibility, not an exclusivity proof that the selected native history is only legacy. */
    fun requireLegacyReplay(scope: VortxAccountScope, ownerName: String, originalNativeBytes: ByteArray,
        material: ByteArray, bindings: VortxRuntimeBindings, checkCurrent: () -> Unit) {
        requireInputSize(originalNativeBytes)
        requireInputSize(material)
        val native = originalNativeBytes.copyOf(); val originalMaterial = material.copyOf()
        generic(native, scope); materialSchema(originalMaterial)
        cold(scope, ownerName, bindings, checkCurrent) { runtime ->
            apply(runtime, action("merge_native_sync").set("document", native).encoded(), checkCurrent)
            requireReceipt(OHJson.Obj(state(runtime, scope, checkCurrent)).raw("nativeSync"), originalMaterial)
            val replay = dispatch(runtime, legacyAction("import_legacy_sync", scope, originalMaterial), checkCurrent)
            if (!ok(replay)) {
                apply(runtime, legacyAction("reconcile_legacy_sync", scope, originalMaterial), checkCurrent)
            }
            val accepted = OHJson.Obj(state(runtime, scope, checkCurrent)).raw("nativeSync")
            requireReceipt(accepted, originalMaterial)
        }
    }

    // Every selected argument is bounded before any defensive copy, JSON parser or JNI call.
    private fun requireInputSize(input: ByteArray) {
        require(input.size <= MAX_BYTES) { "Cold account input exceeds limit" }
    }

    private fun <T> cold(scope: VortxAccountScope, ownerName: String, bindings: VortxRuntimeBindings,
        checkCurrent: () -> Unit, work: (VortxNativeRuntime) -> T): T {
        require(ownerName.isNotBlank()); checkCurrent()
        return VortxNativeRuntime.create(bindings, scope.ownerProfileID, ownerName).use { runtime ->
            checkCurrent()
            apply(runtime, action("bind_sync_scope").set("scope", OHJson.quote(scope.accountID)).encoded(), checkCurrent)
            val result = work(runtime)
            checkCurrent(); result
        }
    }
    private fun action(type: String) = OHJson.Obj().set("type", OHJson.quote(type))
    private fun legacyAction(type: String, scope: VortxAccountScope, material: ByteArray): ByteArray =
        action(type).set("scope", OHJson.quote(scope.accountID)).set("ownerProfileId", OHJson.quote(scope.ownerProfileID))
            .set("material", material).encoded()
    private fun dispatch(runtime: VortxNativeRuntime, action: ByteArray, checkCurrent: () -> Unit): OHJson.Obj {
        checkCurrent()
        val result = runtime.dispatch(OHJson.utf8(action)).toByteArray(Charsets.UTF_8)
        checkCurrent(); require(result.size <= OHJson.MAX) { "Cold native response exceeds limit" }
        return OHJson.Obj(result)
    }
    private fun ok(reply: OHJson.Obj): Boolean {
        val value = OHJson.utf8(reply.raw("ok"))
        require(value == "true" || value == "false") { "Malformed cold native response" }; return value == "true"
    }
    private fun apply(runtime: VortxNativeRuntime, action: ByteArray, checkCurrent: () -> Unit) {
        require(ok(dispatch(runtime, action, checkCurrent))) { "Cold native account action rejected" }
    }
    private fun state(runtime: VortxNativeRuntime, scope: VortxAccountScope, checkCurrent: () -> Unit): ByteArray {
        checkCurrent(); val text = runtime.stateJson(); checkCurrent()
        // Full runtime state includes both native carriers and materialized projections. Its
        // existing raw-state budget is larger than the 5 MiB selected plaintext/input budget.
        val raw = text.toByteArray(Charsets.UTF_8); require(raw.size <= OHJson.MAX)
        val parsed = OHJson.Obj(raw) // Duplicate/UTF-8 framing before the typed presentation validator.
        generic(parsed.raw("nativeSync"), scope)
        scope.validateSnapshot(text)
        checkCurrent(); return raw
    }
    private fun generic(native: ByteArray, scope: VortxAccountScope) {
        require(native.size <= MAX_BYTES); val root = OHJson.Obj(native)
        require(OHJson.integer(root.raw("schemaVersion")) in 1L..5L && root["ownerHistory"] == null &&
            root.text("scope") == scope.accountID && root.text("ownerProfileId") == scope.ownerProfileID) { "Unsupported cold native scope" }
        listOf("profiles", "addons", "libraries", "watches").forEach { OHJson.Obj(root.raw(it)) }
    }
    private fun materialSchema(material: ByteArray): Long = OHJson.integer(OHJson.Obj(material).raw("schemaVersion")).also {
        require(it == 1L || it == 2L) { "Unsupported legacy material schema" }
    }
    private fun requireReceipt(native: ByteArray, material: ByteArray) {
        val receipt = OHJson.Obj(OHJson.Obj(native).raw("legacyImport"))
        require(OHJson.integer(receipt.raw("schemaVersion")) == materialSchema(material)) { "Missing or incompatible native import receipt" }
    }
}
