package com.vortx.android.engine

import com.vortx.android.xperience.XperienceImportNamespace

/** Domain/raw mechanics only. No instance or raw observation here grants account authority. */
internal object NativeXperienceWrite {
    private const val PREFIX = "xperience.import."

    internal fun requireClocks(local: ByteArray): Long {
        val root = OHJson.Obj(local)
        val counter = NativeRawHostPreferences.exactClock(root.raw("counter"))
        require(counter >= maximumClock(root.raw("document"))) { "Exact host preference clock regressed" }
        return counter
    }
    internal fun maximumClock(document: ByteArray): Long {
        val root = OHJson.Obj(document)
        var maximum = 0L
        fun fields(fields: OHJson.Obj) { fields.keys.forEach { field ->
            maximum = maxOf(maximum, NativeRawHostPreferences.exactClock(fields.obj(field).raw("clock")))
        } }
        fields(root.obj("globals").obj("fields"))
        val profiles = root.obj("profiles")
        profiles.keys.forEach { fields(profiles.obj(it).obj("fields")) }
        return maximum
    }

    class Change private constructor(
        val field: String,
        private val baseline: XperienceImportNamespace.Edit,
        value: ByteArray,
        private val deleting: Boolean,
    ) {
        private val replacement = value.copyOf()
        fun admit(current: ByteArray?) {
            require(baseline.baselineMatches(current)) { "Original Xperience register changed" }
            if (deleting) XperienceImportNamespace.read(field, checkNotNull(current))
        }
        internal fun value(): ByteArray = replacement.copyOf()
        internal fun requireReplacement(register: ByteArray) {
            val event = OHJson.Obj(register)
            require(event.keys == setOf("clock", "actor", "value") && OHJson.equal(event.raw("value"), replacement)) {
                "Xperience candidate differs from admitted proposal"
            }
            if (!deleting) XperienceImportNamespace.read(field, register)
        }
        companion object {
            fun edit(edit: XperienceImportNamespace.Edit): Change {
                // Validate the actual pure domain output before any Session fork or clock mint.
                // This temporary envelope is schema validation only, never an original observation.
                val value = edit.value()
                XperienceImportNamespace.read(edit.field, envelope(0, OHJson.quote(VALIDATION_ACTOR), value))
                return Change(edit.field, edit, value, false)
            }
            fun delete(saved: XperienceImportNamespace.Saved): Change {
                val original = XperienceImportNamespace.read(saved.field, saved.register())
                // Reuse the real pure semantic raw-register CAS; do not invent a Namespace.delete.
                val baseline = original.replacement(original.document, original.label, original.bindings)
                return Change(original.field, baseline, OHJson.literal("null"), true)
            }
            private const val VALIDATION_ACTOR = "00000000-0000-0000-0000-000000000001"
        }
    }

    class Replacement(local: ByteArray, register: ByteArray) {
        private val state = local.copyOf(); private val event = register.copyOf()
        fun local() = state.copyOf()
        fun register() = event.copyOf()
    }

    /** Whole-family reads preserve future raw bytes without claiming they are editable. */
    fun fields(local: ByteArray, profileID: String): Map<String, ByteArray> {
        val profiles = OHJson.Obj(local).obj("document").obj("profiles")
        val key = profileKey(profiles, profileID) ?: return emptyMap()
        val fields = profiles.obj(key).obj("fields")
        return fields.keys.filter { it.startsWith(PREFIX) }.associateWith { fields.raw(it) }
    }

    fun register(local: ByteArray, profileID: String, field: String): ByteArray? {
        require(field.startsWith(PREFIX))
        val profiles = OHJson.Obj(local).obj("document").obj("profiles")
        val key = profileKey(profiles, profileID) ?: return null
        return profiles.obj(key).obj("fields")[field]
    }

    /** Called only after the original Session/owner/checkpoint/current-raw admission. All siblings,
     * unknown value members and original numeric tokens stay raw; only this owned envelope changes. */
    fun replace(scope: VortxAccountScope, profileID: String, original: ByteArray, change: Change): Replacement {
        val raw = NativeRawHostPreferences.captureLocal(scope, original)
        val counter = requireClocks(raw)
        val local = OHJson.Obj(raw); val document = local.obj("document"); val profiles = document.obj("profiles")
        val key = profileKey(profiles, profileID) ?: NativeHostPreferences.canonicalProfileID(profileID)
        val bucket = profiles[key]?.let { OHJson.Obj(it) } ?: OHJson.Obj().set("fields", OHJson.literal("{}"))
        val fields = bucket.obj("fields")
        change.admit(fields[change.field])
        require(counter < NativeHostPreferences.MAX_CLOCK) { "Host preference clock exhausted" }
        val event = envelope(counter + 1, local.raw("actor"), change.value())
        fields.set(change.field, event)
        profiles.set(key, bucket.set("fields", fields.encoded()).encoded())
        local.set("document", document.set("profiles", profiles.encoded()).encoded())
            .set("counter", OHJson.literal((counter + 1).toString())).set("pending", OHJson.literal("true"))
        return Replacement(NativeRawHostPreferences.captureLocal(scope, local.encoded()), event)
    }

    private fun profileKey(profiles: OHJson.Obj, profileID: String): String? {
        val names = linkedMapOf<String, String>()
        profiles.keys.forEach { key -> require(names.put(NativeHostPreferences.canonicalProfileID(key), key) == null) }
        return names[NativeHostPreferences.canonicalProfileID(profileID)]
    }
    private fun envelope(clock: Long, actor: ByteArray, value: ByteArray) = OHJson.Obj()
        .set("clock", OHJson.literal(clock.toString())).set("actor", actor).set("value", value).encoded()

    /** Every admission callback is synchronous, single-use and completion checked. An admission
     * cannot swallow a failed/duplicate/cross-thread invocation and report a successful write. */
    fun admitOnce(admission: ((() -> Unit) -> Unit), persist: () -> Unit) {
        val thread = Thread.currentThread()
        var active = true; var invoked = false; var completed = false; var violation: Throwable? = null
        val lock = Any()
        try {
            admission {
                synchronized(lock) {
                    try {
                        check(active && Thread.currentThread() === thread && !invoked) { "Expired or repeated Xperience commit" }
                        invoked = true
                    } catch (failure: Throwable) { violation = failure; throw failure }
                }
                try { persist(); synchronized(lock) { completed = true } }
                catch (failure: Throwable) { synchronized(lock) { violation = failure }; throw failure }
            }
        } finally { synchronized(lock) { active = false } }
        synchronized(lock) {
            violation?.let { throw it }
            check(invoked && completed) { "Xperience admission did not complete persistence" }
        }
    }
}
