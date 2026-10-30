package com.vortx.android.engine

import org.json.JSONObject

/** App-only whole cloud account composition. Never pass its output to JNI or host archives. */
internal object NativePlaylistAccountComposer {
    /** Budget the WHOLE genuine Session host, including earlier unsynced namespaces. Only a
     * currently admitted Session-issued preview may replace this raw host; arbitrary DTOs/raw
     * arrays never receive that permission. Original account authority stays with the caller. */
    fun composeXperience(raw: ByteArray, originalNativeProjection: ByteArray, native: ByteArray,
        preview: VortxNativeSession.XperienceHostPreview, providers: JSONObject): ByteArray {
        val base = NativeOwnerHistoryAccount(raw)
        val sourceNative = OHJson.Obj(checkNotNull(base.raw("nativeSync")))
        val scope = VortxAccountScope(sourceNative.text("scope"), sourceNative.text("ownerProfileId"))
        return preview.withRawHost(scope) { host -> composeWholeHost(raw, originalNativeProjection, native, host, providers) }
    }

    /** Ordinary generic upload uses a newly issued POST-GET Session checkpoint snapshot,
     * including after cold reopen. No per-edit receipt or prefix permits raw replacement. */
    fun composeExport(raw: ByteArray, originalNativeProjection: ByteArray,
        snapshot: VortxNativeSession.RawHostExport, providers: JSONObject): ByteArray {
        snapshot.requireActive()
        val native = OHJson.Obj(checkNotNull(NativeOwnerHistoryAccount(raw).raw("nativeSync")))
        val scope = VortxAccountScope(native.text("scope"), native.text("ownerProfileId"))
        return snapshot.composeHost(scope, raw, originalNativeProjection) { currentNative, host ->
            composeWholeHost(raw, originalNativeProjection, currentNative, host, providers)
        }
    }

    private fun composeWholeHost(raw: ByteArray, originalNativeProjection: ByteArray, native: ByteArray,
        host: ByteArray, providers: JSONObject): ByteArray {
        val base = NativeOwnerHistoryAccount(raw)
        val sourceNative = OHJson.Obj(checkNotNull(base.raw("nativeSync")))
        val scope = VortxAccountScope(sourceNative.text("scope"), sourceNative.text("ownerProfileId"))
        NativeHostPreferences.validate(scope, JSONObject(OHJson.utf8(host)))
        NativeXperienceWrite.maximumClock(host)
        base.raw("nativeHostPreferences")?.let { source -> requireHostConservation(scope, source, host) }
        // Only the owned raw host is supplied by Session. Native/root/provider source slices
        // still cross the original conservative composer and actual encrypted account budget.
        val previewBase = base.replacingOwned(mapOf("nativeHostPreferences" to host)).encoded()
        return try { compose(previewBase, originalNativeProjection, native, host, providers) }
        finally { previewBase.fill(0) }
    }

    private fun requireHostConservation(scope: VortxAccountScope, source: ByteArray, host: ByteArray) {
        NativeHostPreferences.validate(scope, JSONObject(OHJson.utf8(source)))
        val original = OHJson.Obj(source); val next = OHJson.Obj(host)
        fun fields(before: OHJson.Obj, after: OHJson.Obj, profile: Boolean) {
            for (field in before.keys) {
                val first = before.raw(field); val second = checkNotNull(after[field]) { "Source host register was omitted" }
                val a = OHJson.Obj(first); val b = OHJson.Obj(second)
                val comparison = compareValuesBy(b, a,
                    { NativeRawHostPreferences.exactClock(it.raw("clock")) }, { it.text("actor") })
                require(comparison >= 0) { "Source host event regressed" }
                if (comparison == 0) NativeRawHostPreferences.requireEqualEvent(field, profile, first, second)
            }
        }
        fields(original.obj("globals").obj("fields"), next.obj("globals").obj("fields"), false)
        val before = original.obj("profiles"); val after = next.obj("profiles")
        val names = after.keys.associateBy(NativeHostPreferences::canonicalProfileID)
        for (key in before.keys) {
            val current = checkNotNull(names[NativeHostPreferences.canonicalProfileID(key)]) { "Source host profile was omitted" }
            fields(before.obj(key).obj("fields"), after.obj(current).obj("fields"), true)
        }
    }

    /** The typed Session owns this real prepared account, including schema 6/source history and
     * its exact host/native checkpoint. This method never routes it through the generic patcher. */
    fun composePrepared(raw: ByteArray, prospectiveHost: ByteArray, providers: JSONObject): ByteArray {
        val base = NativeOwnerHistoryAccount(raw)
        val native = OHJson.Obj(requireNotNull(base.raw("nativeSync")))
        require(OHJson.integer(native.raw("schemaVersion")) == 6L && native["ownerHistory"] != null &&
            base.raw(NativeOwnerHistoryAccount.ARCHIVE) != null) { "Original prepared typed account required" }
        base.validateBudget(writeV2 = true)
        OHJson.Obj(prospectiveHost)
        NativeHostPreferences.validate(VortxAccountScope(native.text("scope"), native.text("ownerProfileId")),
            JSONObject(OHJson.utf8(prospectiveHost)))
        val replacements = linkedMapOf("nativeHostPreferences" to prospectiveHost)
        preserveProviders(base, providers, replacements)
        return base.replacingOwned(replacements).validateBudget(writeV2 = true)
    }

    /** The before projection is the exact JNI normalization of the authenticated source, not the
     * post-merge mount (which can already contain pending native mutations). */
    fun compose(raw: ByteArray, originalNativeProjection: ByteArray, native: ByteArray,
        host: ByteArray, providers: JSONObject): ByteArray {
        val base = NativeOwnerHistoryAccount(raw)
        val originalNative = requireNotNull(base.raw("nativeSync"))
        val schema = OHJson.integer(OHJson.Obj(originalNative).raw("schemaVersion"))
        require(schema in 1L..5L && base.raw(NativeOwnerHistoryAccount.ARCHIVE) == null)
        val patchedNative = patch(originalNative, originalNativeProjection, native)
        val nativeWire = if (OHJson.equal(originalNativeProjection, native)) patchedNative else
            OHJson.Obj(patchedNative).set("schemaVersion", OHJson.Obj(native).raw("schemaVersion")).encoded()
        val replacements = linkedMapOf(
            "nativeSync" to nativeWire,
            "nativeHostPreferences" to preserveRegisters(base.raw("nativeHostPreferences"), host),
        )
        preserveProviders(base, providers, replacements)
        return base.replacingOwned(replacements).validateBudget(writeV2 = true)
    }

    private fun preserveProviders(base: NativeOwnerHistoryAccount, providers: JSONObject,
                                  replacements: MutableMap<String, ByteArray>) {
        // Provider mirror is prepared inside its full-record vault fence, without commit/ack.
        // Preserve untouched apiKeys siblings (and their raw numeric/string spelling).
        for (key in listOf("nativeProviderCredentials", "apiKeys")) {
            providers.optJSONObject(key)?.let { next ->
                val old = base.raw(key)
                val encoded = next.toString().toByteArray(Charsets.UTF_8)
                replacements[key] = if (old == null) encoded else patch(old,
                    JSONObject(OHJson.utf8(old)).toString().toByteArray(Charsets.UTF_8), encoded)
            }
        }
    }

    /** Apply changes between genuine source projection and prospective projection to raw slices.
     * Unobserved raw keys are never inferred deletes. Ambiguous changed opaque arrays fail closed.
     */
    private fun patch(raw: ByteArray, before: ByteArray, after: ByteArray): ByteArray {
        if (OHJson.equal(before, after)) return raw.copyOf()
        val previous = JSONObject("{\"v\":" + OHJson.utf8(before) + "}").get("v")
        val next = JSONObject("{\"v\":" + OHJson.utf8(after) + "}").get("v")
        if (previous is JSONObject && next is JSONObject) {
            val result = OHJson.Obj(raw); val a = OHJson.Obj(before); val b = OHJson.Obj(after)
            for (key in a.keys + b.keys) {
                val old = a[key]; val value = b[key]
                if (value == null) result.remove(key)
                else if (old == null) {
                    val unobserved = result[key]
                    require(unobserved == null || OHJson.equal(unobserved, value)) { "Unobserved raw sibling collision" }
                    result.set(key, value)
                } else result.set(key, patch(result[key] ?: old, old, value))
            }
            return result.encoded()
        }
        // Replacing an array/scalar is safe only when the original projection lost no raw material.
        // Unchanged opaque arrays above retain every byte. No row identity is guessed here.
        require(OHJson.equal(raw, before)) { "Opaque native value requires lossless mutation support" }
        return after.copyOf()
    }
    private fun preserveRegisters(raw: ByteArray?, host: ByteArray): ByteArray {
        if (raw == null) return host.copyOf()
        val source = OHJson.Obj(raw)
        val next = OHJson.Obj(host)
        val originalProfiles = source.obj("profiles")
        val nextProfiles = next.obj("profiles")
        val originalNames = originalProfiles.keys.associateBy(NativeHostPreferences::canonicalProfileID)
        val renamed = OHJson.Obj()
        nextProfiles.keys.forEach { key -> renamed.set(originalNames[NativeHostPreferences.canonicalProfileID(key)] ?: key,
            nextProfiles.raw(key)) }
        next.set("profiles", renamed.encoded())
        return NativeRawHostPreferences.patchDocument(raw,
            JSONObject(OHJson.utf8(raw)).toString().toByteArray(Charsets.UTF_8), next.encoded())
    }
}
