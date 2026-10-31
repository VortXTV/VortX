package com.vortx.android.engine

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Base64

/** Raw slices are persistence material, never org.json/Double presentation values. */
internal object OHJson {
    const val MAX = 32 * 1024 * 1024
    fun utf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()
    fun text(bytes: ByteArray): String = Parser(bytes).run { val result = string(); end(); result }
    fun quote(value: String): ByteArray {
        val out = StringBuilder("\"")
        var i = 0
        while (i < value.length) {
            val c = value[i++]
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                else -> when {
                    c.code < 32 -> out.append("\\u%04x".format(c.code))
                    Character.isHighSurrogate(c) -> {
                        require(i < value.length && Character.isLowSurrogate(value[i]))
                        out.append(c).append(value[i++])
                    }
                    Character.isLowSurrogate(c) -> error("Unpaired JSON surrogate")
                    else -> out.append(c)
                }
            }
        }
        return out.append('"').toString().toByteArray(Charsets.UTF_8)
    }
    fun literal(value: String) = value.toByteArray(Charsets.UTF_8)
    fun array(bytes: ByteArray): List<ByteArray> = Parser(bytes).run { val value = array(); end(); value }
    fun array(values: List<ByteArray>): ByteArray = join('[', ']', values)
    private fun join(open: Char, close: Char, values: List<ByteArray>): ByteArray {
        val out = ByteArrayOutputStream(); out.write(open.code)
        values.forEachIndexed { i, value -> if (i > 0) out.write(','.code); out.write(value); require(out.size() <= MAX) }
        out.write(close.code); return out.toByteArray()
    }
    class Obj private constructor(private val values: LinkedHashMap<String, ByteArray>) {
        constructor(bytes: ByteArray = literal("{}")) : this(Parser(bytes).run { val result = obj(); end(); result })
        fun copy() = Obj(LinkedHashMap(values)) // Private immutable byte slices may be shared.
        val keys: Set<String> get() = values.keys.toSet()
        operator fun get(key: String): ByteArray? = values[key]?.copyOf()
        fun raw(key: String): ByteArray = requireNotNull(get(key)) { "Missing owner-history field" }
        fun text(key: String) = OHJson.text(raw(key))
        fun obj(key: String) = Obj(raw(key))
        fun set(key: String, value: ByteArray): Obj {
            Parser(value).run { value(); end() }; values[key] = value.copyOf(); return this
        }
        /** Only already-parsed or locally encoded slices, never unvalidated external input. */
        fun setValidated(key: String, value: ByteArray): Obj { values[key] = value.copyOf(); return this }
        fun setFrom(other: Obj, key: String): Obj { values[key] = requireNotNull(other.values[key]); return this }
        fun remove(key: String): Obj { values.remove(key); return this }
        fun encoded(): ByteArray = join('{', '}', values.keys.sorted().map { quote(it) + literal(":") + values.getValue(it) })
    }
    fun canonical(bytes: ByteArray): ByteArray {
        val p = Parser(bytes); p.ws(); val begin = p.at; p.value(); val end = p.at; p.end()
        val raw = bytes.copyOfRange(begin, end)
        return when (raw.first().toInt().toChar()) {
            '{' -> Obj(raw).let { o -> o.keys.forEach { o.set(it, canonical(o.raw(it))) }; o.encoded() }
            '[' -> array(array(raw).map(::canonical))
            '"' -> quote(text(raw))
            else -> raw // Numeric spelling, including negative zero, is deliberately retained.
        }
    }
    fun equal(a: ByteArray, b: ByteArray) = canonical(a).contentEquals(canonical(b))
    fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    fun un64(value: String): ByteArray = Base64.getDecoder().decode(value).also { require(b64(it) == value && it.size <= MAX) }
    fun integer(bytes: ByteArray): Long {
        val s = utf8(bytes); require(Regex("0|[1-9][0-9]*").matches(s)); return s.toLong()
    }
    fun uid(value: String) { require(value.isNotEmpty() && value.toByteArray().size <= 1024 && value.none { Character.isISOControl(it) }) }
    private class Parser(val bytes: ByteArray) {
        var at = 0; private var depth = 0
        init { require(bytes.size <= MAX); utf8(bytes) }
        fun ws() { while (at < bytes.size && bytes[at].toInt() in listOf(9, 10, 13, 32)) at++ }
        fun end() { ws(); require(at == bytes.size) { "Trailing JSON" } }
        private fun take(c: Char) { ws(); require(at < bytes.size && bytes[at++].toInt() == c.code) }
        fun obj(): LinkedHashMap<String, ByteArray> {
            require(++depth <= 128); take('{'); ws(); val result = linkedMapOf<String, ByteArray>(); val names = hashSetOf<String>()
            if (at < bytes.size && bytes[at].toInt() == '}'.code) { at++; depth--; return result }
            while (true) {
                val key = string(); require(names.add(Normalizer.normalize(key, Normalizer.Form.NFC))) { "Duplicate JSON key" }
                take(':'); ws(); val begin = at; value(); result[key] = bytes.copyOfRange(begin, at); ws()
                require(at < bytes.size)
                if (bytes[at].toInt() == '}'.code) { at++; depth--; return result }; take(',')
            }
        }
        fun array(): List<ByteArray> {
            require(++depth <= 128); take('['); ws(); val result = arrayListOf<ByteArray>()
            if (at < bytes.size && bytes[at].toInt() == ']'.code) { at++; depth--; return result }
            while (true) {
                ws(); val begin = at; value(); result.add(bytes.copyOfRange(begin, at)); ws(); require(at < bytes.size)
                if (bytes[at].toInt() == ']'.code) { at++; depth--; return result }; take(',')
            }
        }
        fun string(): String {
            take('"'); val out = StringBuilder(); var begin = at
            fun flush(end: Int) { if (end > begin) out.append(utf8(bytes.copyOfRange(begin, end))) }
            fun hex(): Char { require(at + 4 <= bytes.size); val s = utf8(bytes.copyOfRange(at, at + 4)); require(s.all { it in "0123456789abcdefABCDEF" }); at += 4; return s.toInt(16).toChar() }
            while (at < bytes.size) {
                val c = bytes[at++].toInt() and 255
                require(c >= 32)
                if (c == 34) { flush(at - 1); return out.toString() }
                if (c == 92) {
                    flush(at - 1); require(at < bytes.size)
                    when (val e = bytes[at++].toInt().toChar()) {
                        '"', '\\', '/' -> out.append(e)
                        'b' -> out.append('\b'); 'f' -> out.append('\u000c'); 'n' -> out.append('\n'); 'r' -> out.append('\r'); 't' -> out.append('\t')
                        'u' -> {
                            val u = hex()
                            if (Character.isHighSurrogate(u)) {
                                require(at + 2 <= bytes.size && bytes[at++].toInt() == 92 && bytes[at++].toInt() == 117)
                                val low = hex(); require(Character.isLowSurrogate(low)); out.append(u).append(low)
                            } else { require(!Character.isLowSurrogate(u)); out.append(u) }
                        }
                        else -> error("Invalid JSON escape")
                    }
                    begin = at
                }
            }
            error("Unterminated JSON string")
        }
        fun value() {
            ws(); require(at < bytes.size)
            when (bytes[at].toInt().toChar()) {
                '{' -> obj(); '[' -> array(); '"' -> string()
                't' -> word("true"); 'f' -> word("false"); 'n' -> word("null")
                else -> number()
            }
        }
        private fun word(s: String) { require(at + s.length <= bytes.size && utf8(bytes.copyOfRange(at, at + s.length)) == s); at += s.length }
        private fun digit() = at < bytes.size && bytes[at].toInt() in 48..57
        private fun number() {
            if (at < bytes.size && bytes[at].toInt() == 45) at++
            require(digit())
            if (bytes[at].toInt() == 48) at++ else { while (digit()) at++ }
            if (at < bytes.size && bytes[at].toInt() == 46) { at++; require(digit()); while (digit()) at++ }
            if (at < bytes.size && bytes[at].toInt() in listOf(69, 101)) {
                at++; if (at < bytes.size && bytes[at].toInt() in listOf(43, 45)) at++; require(digit()); while (digit()) at++
            }
        }
    }
}

/** No authority is minted by this serializer. Every raw sibling survives unless explicitly owned. */
internal class NativeOwnerHistoryAccount(raw: ByteArray) {
    private val root = OHJson.Obj(raw)
    fun raw(key: String) = root[key]
    fun encoded() = root.encoded()
    fun bytes() = encoded()
    fun cloudPlaintext(writeV2: Boolean): ByteArray {
        val native = OHJson.Obj(requireNotNull(raw("nativeSync"))); val schema = OHJson.integer(native.raw("schemaVersion"))
        if (schema == 6L) { require(native["ownerHistory"] != null && raw(ARCHIVE) != null); return validateBudget(writeV2) }
        require(schema in 1..5 && native["ownerHistory"] == null)
        raw(ARCHIVE)?.let { require(OHJson.Obj(it).obj("journal").obj("sources").keys.isEmpty()) }
        // Pending remains in the sealed local envelope, not an unsafe legacy cloud sidecar.
        return NativeOwnerHistoryAccount(OHJson.Obj(encoded()).remove(ARCHIVE).encoded()).validateBudget(writeV2)
    }
    fun replacingOwned(replacements: Map<String, ByteArray>): NativeOwnerHistoryAccount {
        require(replacements.keys.all { it in OWNED }); val next = OHJson.Obj(encoded())
        replacements.forEach { (k, v) -> next.set(k, v) }; return NativeOwnerHistoryAccount(next.encoded())
    }
    fun projected(checkpoint: NativeOwnerHistoryCoordinator.Checkpoint, projection: NativeOwnerHistoryCoordinator.HostProjection) =
        replacingOwned(mapOf("nativeSync" to OHJson.Obj(checkpoint.snapshot).raw("nativeSync"),
            "nativeHostPreferences" to projection.document, "profileEditResults" to projection.profileEditResults,
            ARCHIVE to NativeOwnerHistorySources.carrier(checkpoint.localArchive, checkpoint.scope, checkpoint.readOwnerUID)))
    fun validateBudget(writeV2: Boolean): ByteArray {
        val bytes = encoded(); val overhead = 28L
        val sealed = 4L * ((bytes.size.toLong() + overhead + 2) / 3) + if (writeV2) 3 else 0
        require(sealed <= 7L * 1024 * 1024 && sealed + 42 <= 8L * 1024 * 1024) { "Complete account exceeds encrypted budget" }
        return bytes
    }
    companion object {
        const val ARCHIVE = "nativeOwnerHistorySources"
        private val OWNED = setOf("nativeSync", "nativeHostPreferences", "profileEditResults", "nativeProviderCredentials", "apiKeys", ARCHIVE)
    }
}

/** Cached raw state composition. Unknown roots/native siblings survive; source reuse is witness-bound. */
internal class OHState private constructor(private val root: OHJson.Obj, private val native: OHJson.Obj, val fence: ByteArray) {
    constructor(bytes: ByteArray, fence: ByteArray) : this(OHJson.Obj(bytes), OHJson.Obj(bytes).obj("nativeSync"), fence)
    val witness: String = OHJson.Obj(fence).text("sourceSetWitnessId")
    fun bytes() = root.encoded()
    fun native() = native.encoded()
    fun presentation(): ByteArray {
        val view = OHJson.Obj()
        root.keys.filter { it in ROOT && it != "nativeSync" }
            .forEach { view.setFrom(root, it) }
        val shown = OHJson.Obj(); NATIVE.filter { it in native.keys }.forEach { shown.setFrom(native, it) }
        view.setValidated("nativeSync", shown.encoded()); return view.encoded()
    }
    fun retarget(next: ByteArray): OHState {
        require(sameGeneration(fence, next)); return OHState(root, native, next)
    }
    /** Native serde cannot carry unknown peer siblings. Preserve both authenticated raw bases
     * before normalizing known fields; an unknown collision has no invented winner. */
    fun preservingPeerNative(peer: ByteArray): OHState {
        val incoming = OHJson.Obj(peer); val combined = native.copy()
        (incoming.keys - NATIVE - "ownerHistory").forEach { key ->
            val prior = native[key]
            require(prior == null || OHJson.equal(prior, incoming.raw(key))) { "Unknown native peer field collision" }
            if (prior == null) combined.setFrom(incoming, key)
        }
        return OHState(root.copy().setValidated("nativeSync", combined.encoded()), combined, fence)
    }
    private fun mergedNative(incoming: OHJson.Obj, history: ByteArray?): OHJson.Obj {
        val n = native.copy(); NATIVE.forEach(n::remove)
        incoming.keys.filter { it != "ownerHistory" }.forEach { n.setFrom(incoming, it) }
        if (history == null) n.remove("ownerHistory") else n.setValidated("ownerHistory", history)
        return n
    }
    fun full(state: ByteArray, nextFence: ByteArray): OHState {
        val incoming = OHJson.Obj(state); require(incoming.keys.all { it in ROOT })
        require(setOf("roster", "libraries", "nativeSync").all { it in incoming.keys })
        val result = root.copy()
        ROOT.filter { it != "nativeSync" }.forEach { key -> incoming[key]?.let { result.set(key, it) } ?: result.remove(key) }
        val n = incoming.obj("nativeSync"); val nextNative = mergedNative(n, n["ownerHistory"])
        result.setValidated("nativeSync", nextNative.encoded())
        return OHState(result, nextNative, nextFence)
    }
    fun delta(bytes: ByteArray, parent: ByteArray, allowKeyed: Boolean = false, expectedFence: ByteArray? = null): OHState {
        val r = OHJson.Obj(bytes)
        expectedFence?.let { require(OHJson.equal(r.raw("fence"), it)) }
        if (r["deltaEncoding"] != null) {
            require(allowKeyed) { "Unnegotiated owner-history checkpoint format" }
            return keyedDelta(r, parent)
        }
        require(r.text("kind") == "checkpoint_delta" && r.text("reuseExactOwnerHistoryFromWitness") == witness &&
            OHJson.equal(r.raw("preparedAgainst"), parent) && OHJson.utf8(r.raw("durableAck")) == "false" &&
            OHJson.utf8(r.raw("requiresCompleteArchiveEnvelope")) == "true")
        val d = r.obj("delta"); require(d.keys.all { it in setOf("accountLibraryArchives", "projectedAccountSlots", "nativeSync", "activeProfileId", "profiles", "libraries") })
        val next = root.copy(); var nextNative = native
        d["profiles"]?.let { rows ->
            val roster = next.obj("roster"); val profiles = roster.obj("profiles")
            OHJson.array(rows).forEach { profiles.set(OHJson.Obj(it).text("id"), it) }
            next.set("roster", roster.set("profiles", profiles.encoded()).encoded())
        }
        d["libraries"]?.let { rows -> val libraries = next.obj("libraries"); val changes = OHJson.Obj(rows)
            changes.keys.forEach { libraries.set(it, changes.raw(it)) }; next.set("libraries", libraries.encoded()) }
        for (k in listOf("accountLibraryArchives", "projectedAccountSlots", "activeProfileId")) d[k]?.let { next.set(k, it) }
        d["nativeSync"]?.let { raw -> val changed = OHJson.Obj(raw); require(changed["ownerHistory"] == null)
            nextNative = mergedNative(changed, native["ownerHistory"]); next.setValidated("nativeSync", nextNative.encoded()) }
        val f = r.raw("fence"); require(OHJson.Obj(f).text("sourceSetWitnessId") == witness)
        return OHState(next, nextNative, f)
    }
    /** The public keyed_rows/1 wire contract; only admitted mutable rows are interpreted.
     * Source/unknown raw slices stay in their original complete-envelope owner. */
    private fun keyedDelta(reply: OHJson.Obj, parent: ByteArray): OHState {
        require(reply.keys == setOf("kind", "fence", "preparedAgainst", "deltaEncoding", "keyedStateSteps",
            "reuseExactOwnerHistoryFromWitness", "requiresCompleteArchiveEnvelope", "durableAck"))
        require(reply.text("kind") == "checkpoint_delta" && reply.text("deltaEncoding") == KEYED_FORMAT &&
            reply.text("reuseExactOwnerHistoryFromWitness") == witness &&
            OHJson.utf8(reply.raw("durableAck")) == "false" &&
            OHJson.utf8(reply.raw("requiresCompleteArchiveEnvelope")) == "true" &&
            OHJson.equal(reply.raw("preparedAgainst"), parent) && OHJson.equal(parent, fence))
        val nextFence = reply.raw("fence"); val before = OHJson.Obj(fence); val after = OHJson.Obj(nextFence)
        var revision = generation(before); val finalRevision = generation(after)
        require(after.text("instanceId").isNotEmpty() && after.text("sourceSetWitnessId") == witness)
        for (key in listOf("instanceId", "mutationGeneration")) { before.remove(key); after.remove(key) }
        require(OHJson.equal(before.encoded(), after.encoded())) { "Keyed checkpoint changed original authority" }
        val steps = OHJson.array(reply.raw("keyedStateSteps")); require(steps.size <= 512)
        val libraries = root.obj("libraries"); val nextNative = native.copy()
        for (raw in steps) {
            val step = OHJson.Obj(raw)
            require(step.keys == setOf("baseGeneration", "revision", "edits") &&
                unsigned(step.text("baseGeneration")) == revision && revision != ULong.MAX_VALUE &&
                unsigned(step.text("revision")) == revision + 1uL)
            val edits = step.obj("edits")
            require(edits.keys == setOf("libraries", "nativeWatches", "slotWatches"))
            val changedLibraries = edits.obj("libraries")
            changedLibraries.keys.forEach { id -> libraries.set(id, libraryEdit(changedLibraries.raw(id), libraries.raw(id))) }
            val watches = edits.obj("nativeWatches")
            if (watches.keys.isNotEmpty()) {
                val values = nextNative.obj("watches")
                watches.keys.forEach { id -> values.set(id, watchEdit(watches.raw(id), values.raw(id))) }
                nextNative.setValidated("watches", values.encoded())
            }
            val profiles = edits.obj("slotWatches")
            if (profiles.keys.isNotEmpty()) {
                val states = nextNative.obj("accountSlots")
                for (id in profiles.keys) {
                    val state = states.obj(id); val slots = state.obj("slots"); val changedSlots = profiles.obj(id)
                    for (key in changedSlots.keys) {
                        val slot = slots.obj(key)
                        slot.set("watch", watchEdit(changedSlots.raw(key), slot.raw("watch")))
                        slots.setValidated(key, slot.encoded())
                    }
                    state.setValidated("slots", slots.encoded()); states.setValidated(id, state.encoded())
                }
                nextNative.setValidated("accountSlots", states.encoded())
            }
            revision += 1uL
        }
        require(revision == finalRevision) { "Incomplete keyed checkpoint journal" }
        // Encoding still produces a complete checkpoint; no incremental encryption/durable ACK.
        val next = root.copy().setValidated("libraries", libraries.encoded()).setValidated("nativeSync", nextNative.encoded())
        return OHState(next, nextNative, nextFence)
    }
    private fun generation(value: OHJson.Obj) = unsigned(value.text("mutationGeneration"))
    private fun unsigned(text: String): ULong = requireNotNull(text.toULongOrNull()).also { require(it.toString() == text) }
    private fun mapEdit(raw: ByteArray, prior: ByteArray): OHJson.Obj {
        val edits = OHJson.Obj(raw); val result = OHJson.Obj(prior)
        val identities = result.keys.associateBy { Normalizer.normalize(it, Normalizer.Form.NFC) }.toMutableMap()
        for (key in edits.keys) {
            val identity = Normalizer.normalize(key, Normalizer.Form.NFC)
            require(identities[identity]?.let { it == key } != false) { "Ambiguous keyed row identity" }
            val edit = edits.obj(key)
            when (edit.text("op")) {
                "put" -> { require(edit.keys == setOf("op", "value")); result.set(key, edit.raw("value")); identities[identity] = key }
                "remove" -> { require(edit.keys == setOf("op") && result[key] != null); result.remove(key); identities.remove(identity) }
                else -> error("Unknown keyed row operation")
            }
        }
        return result
    }
    private fun spanEdit(raw: ByteArray, prior: ByteArray): List<ByteArray> {
        val edit = OHJson.Obj(raw); require(edit.keys == setOf("at", "remove", "insert"))
        val values = OHJson.array(prior).toMutableList()
        val at = OHJson.integer(edit.raw("at")); val count = OHJson.integer(edit.raw("remove"))
        require(at <= values.size.toLong() && count <= values.size.toLong() - at)
        val start = at.toInt(); values.subList(start, start + count.toInt()).clear()
        values.addAll(start, OHJson.array(edit.raw("insert"))); return values
    }
    private fun libraryEdit(raw: ByteArray, prior: ByteArray): ByteArray {
        val edits = OHJson.Obj(raw); val library = OHJson.Obj(prior)
        val maps = setOf("resume", "watched", "watchLog", "watchContexts")
        val spans = setOf("items", "history", "continueWatching", "searchHistory", "cwBoard")
        require(edits.keys.all { it in maps || it in spans || it in setOf("aliases", "entries") })
        for (key in maps) edits[key]?.let { edit ->
            val value = mapEdit(edit, library[key] ?: OHJson.literal("{}"))
            if (key in setOf("watchLog", "watchContexts") && value.keys.isEmpty()) library.remove(key)
            else library.setValidated(key, value.encoded())
        }
        for (key in spans) edits[key]?.let { edit ->
            val values = spanEdit(edit, library[key] ?: OHJson.literal("[]"))
            if (key == "cwBoard" && values.isEmpty()) library.remove(key)
            else library.setValidated(key, OHJson.array(values))
        }
        if (edits["aliases"] != null || edits["entries"] != null) {
            val vault = OHJson.Obj(library["resumeVault"] ?: OHJson.literal("{}"))
            for (key in listOf("aliases", "entries")) edits[key]?.let { edit ->
                val value = mapEdit(edit, vault[key] ?: OHJson.literal("{}"))
                if (value.keys.isEmpty()) vault.remove(key) else vault.setValidated(key, value.encoded())
            }
            if (vault.keys.isEmpty()) library.remove("resumeVault") else library.setValidated("resumeVault", vault.encoded())
        }
        return library.encoded()
    }
    private fun watchEdit(raw: ByteArray, prior: ByteArray): ByteArray {
        val edits = OHJson.Obj(raw); val watch = OHJson.Obj(prior)
        require(edits.keys.all { it in setOf("log", "contexts", "identityLinks") })
        for (key in listOf("log", "contexts")) edits[key]?.let { watch.setValidated(key, mapEdit(it, watch.raw(key)).encoded()) }
        edits["identityLinks"]?.let { edit ->
            val values = spanEdit(edit, watch["identityLinks"] ?: OHJson.literal("[]"))
            if (values.isEmpty()) watch.remove("identityLinks") else watch.setValidated("identityLinks", OHJson.array(values))
        }
        return watch.encoded()
    }
    /** Host reducers cannot edit source/native state through disposable presentation JSON. */
    fun localState(raw: ByteArray): OHState {
        val proposed = OHJson.Obj(raw); val shown = OHJson.Obj(presentation())
        ROOT.forEach { k ->
            val x = proposed[k]; val y = shown[k]
            require(if (x == null || y == null) x == null && y == null else OHJson.equal(x, y)) { "Host policy changed native state" }
        }
        require(proposed.keys.all { it in ROOT || it in HOST || it in RETAINED }) { "Unexpected host projection field" }
        RETAINED.forEach { k -> proposed[k]?.let { require(root[k] != null && OHJson.equal(it, root.raw(k))) { "Raw local archive changed through presentation" } } }
        val overlay = OHJson.Obj(raw); (ROOT + RETAINED).forEach(overlay::remove)
        return localOverlay(overlay.encoded())
    }
    fun localOverlay(raw: ByteArray): OHState {
        val proposed = OHJson.Obj(raw); require(proposed.keys.all { it in HOST })
        val result = root.copy()
        // Known host omission semantics; unknown omitted fields are never inferred clears.
        HOST.forEach { k -> proposed[k]?.let { result.set(k, it) } ?: result.remove(k) }
        return OHState(result, native, fence)
    }
    fun retained(fields: Map<String, ByteArray>): OHState {
        require(fields.keys.all { it in RETAINED })
        val result = root.copy(); fields.forEach { (key, value) -> result.set(key, value) }
        return OHState(result, native, fence)
    }
    companion object {
        const val KEYED_FORMAT = "keyed_rows/1"
        val ROOT = setOf("roster", "libraries", "accountLibraryArchives", "projectedAccountSlots", "nativeSync", "activeProfileId")
        val NATIVE = setOf("websiteAddonReceipts", "accountSlots", "legacyProfileEditReceipts", "legacyImport", "schemaVersion", "scope", "ownerProfileId", "profiles", "addons", "libraries", "watches")
        private val HOST = setOf("hostProfilePreferences", "hostProfileSyncPending", "nativeHostPreferenceState", "websiteProfileEditPending", "websiteProfileEditCertificates", "websiteAddonEditPending")
        val RETAINED = setOf("hostDocument", "legacyImportMaterial", "excludedCredentialPaths", "legacyWebsiteBootstrap")
        /** Native serde may omit unknown siblings; it may not change known data or source proof. */
        fun requireColdNativeConservation(original: ByteArray, candidate: ByteArray) {
            val before = OHJson.Obj(original); val after = OHJson.Obj(candidate)
            val known = NATIVE + "ownerHistory"
            known.forEach { key ->
                val x = before[key]; val y = after[key]
                require(if (x == null || y == null) x == null && y == null else OHJson.equal(x, y)) {
                    "Cold native normalization changed admitted state"
                }
            }
            // An unexpectedly returned unknown field is not permission to overwrite raw data.
            (after.keys - known).forEach { key ->
                require(before[key] != null && OHJson.equal(before.raw(key), after.raw(key)))
            }
        }
        fun sameGeneration(a: ByteArray, b: ByteArray): Boolean {
            val x = OHJson.Obj(a); val y = OHJson.Obj(b)
            listOf("profileId", "verifiedStreamingUid", "binding").forEach { x.remove(it); y.remove(it) }
            return OHJson.equal(x.encoded(), y.encoded())
        }
    }
}
