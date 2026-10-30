package com.vortx.android.xperience

import com.vortx.android.engine.OHJson
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.text.Normalizer

/** Pure edit/read model for the existing Apple `xperience.import.<uuid>` profile register.
 * Register authority, account budget and durable writes remain in the native/store layer. */
internal object XperienceImportNamespace {
    private const val PREFIX = "xperience.import."
    private const val MAX_LABEL_BYTES = 256
    private const val MAX_CLOCK = 9_007_199_254_740_991L
    private const val MAX_REGISTER_BYTES = OHJson.MAX
    private const val MAX_INDEX_WORKSPACE_BYTES = 192L * 1024 * 1024
    private const val MAX_REPLACE_INDEX_BYTES = 64L * 1024 * 1024
    private const val MAX_READ_ALL_RETAINED_BYTES = 160L * 1024 * 1024
    private const val MAX_READ_ALL_FIELDS = 50_000
    private const val MAX_REGISTER_CANONICAL_WORKSPACE_BYTES = XperienceCollections.MAX_REGISTER_CANONICAL_WORKSPACE_BYTES
    private const val MAX_READ_ALL_PEAK_BYTES = MAX_READ_ALL_RETAINED_BYTES +
        MAX_REGISTER_CANONICAL_WORKSPACE_BYTES + MAX_REGISTER_BYTES
    private const val MAX_INDEX_SCAN_BYTES = OHJson.MAX.toLong() * 129L
    private const val COLLECTION_PROJECTION_RESERVATION = 64L * 1024 * 1024
    private const val COLLECTION_PROJECTION_BASE = 1024L * 1024
    private const val COLLECTION_PROJECTION_MULTIPLIER = 64L
    private const val MAX_VALUE_BYTES = OHJson.MAX
    private val HEX64 = Regex("[0-9a-f]{64}")
    private val OWNED_VALUE_KEYS = setOf("schemaVersion", "importID", "label", "fingerprint", "collections", "bindings")

    data class Binding(val manifestID: String, val transportFingerprint: String)
    internal data class Payload(val label: String, val document: XperienceCollections.Document, val bindings: Map<String, Binding>)

    internal class RetainedBudget(
        private val limit: Long = XperienceImportNamespace.MAX_READ_ALL_RETAINED_BYTES,
        private val registerLimit: Long = limit,
    ) {
        init {
            require(limit in 0..XperienceImportNamespace.MAX_READ_ALL_RETAINED_BYTES)
            require(registerLimit in 0..limit)
        }
        private var reserved = 0L
        private var registerBytes = 0L
        private var callerInputBytes = 0L
        fun reserve(bytes: Long) {
            if (bytes < 0 || bytes > limit - reserved) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            reserved += bytes
        }
        fun reserveRegister(bytes: Long) {
            if (bytes < 0 || bytes > registerLimit - registerBytes) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            reserve(bytes)
            registerBytes += bytes
        }
        fun releaseRegister(bytes: Long) {
            if (bytes < 0 || bytes > registerBytes || bytes > reserved) XperienceImportNamespace.invalid()
            registerBytes -= bytes
            reserved -= bytes
        }
        fun setCallerInputBytes(bytes: Long) {
            if (bytes < 0 || bytes > XperienceImportNamespace.MAX_REGISTER_BYTES) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            callerInputBytes = bytes
        }
        fun checkCanonicalPass() {
            if (reserved > limit || reserved + XperienceImportNamespace.MAX_REGISTER_CANONICAL_WORKSPACE_BYTES + callerInputBytes > XperienceImportNamespace.MAX_READ_ALL_PEAK_BYTES) {
                XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            }
        }
    }

    /** Immutable evidence created only after complete register admission and namespace binding. */
    internal class ValidatedRegister private constructor(
        private val rawBytes: ByteArray,
        private val canonicalBytes: ByteArray,
        internal val valueStart: Int,
        internal val valueEnd: Int,
        internal val namespace: UUID,
    ) {
        fun rawCopy(): ByteArray = rawBytes.copyOf()
        private fun rawEquals(candidate: ByteArray): Boolean = rawBytes.contentEquals(candidate)
        private fun semanticEquals(candidate: ByteArray): Boolean = runCatching {
            XperienceCollections.canonicalRegisterData(candidate).contentEquals(canonicalBytes)
        }.getOrDefault(false)

        fun matches(candidate: ByteArray?): Boolean {
            if (candidate == null || candidate.size > MAX_REGISTER_BYTES) return false
            // The candidate is copied before either comparison, pinning bytes against concurrent
            // caller mutation. A byte-equal shortcut is safe only against this admitted snapshot.
            val stable = candidate.copyOf()
            return if (rawEquals(stable)) true else semanticEquals(stable)
        }

        internal fun index(maximumWorkspace: Long = XperienceImportNamespace.MAX_INDEX_WORKSPACE_BYTES): SliceIndex = SliceIndex(rawBytes, maximumWorkspace)

        companion object {
            /** Capture a full valid register and bind it to the requested Xperience namespace. */
            internal fun capture(raw: ByteArray, namespace: UUID, retainedBudget: RetainedBudget? = null): RegisterCapture {
                if (raw.isEmpty() || raw.size > XperienceImportNamespace.MAX_REGISTER_BYTES) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
                retainedBudget?.reserveRegister(raw.size.toLong())
                val stable = raw.copyOf()
                retainedBudget?.checkCanonicalPass()
                val canonical = XperienceCollections.canonicalRegisterData(stable)
                // Charge the actual canonical expansion before the validated baseline retains it.
                retainedBudget?.reserveRegister(canonical.size.toLong())
                val index = SliceIndex(stable, XperienceImportNamespace.MAX_INDEX_WORKSPACE_BYTES, retainedBudget)
                val registerFields = index.rootObjectFields()
                if (registerFields.keys != setOf("clock", "actor", "value")) XperienceImportNamespace.invalid()
                val clock = index.long(registerFields.getValue("clock"), 20) ?: XperienceImportNamespace.invalid()
                if (clock !in 0..XperienceImportNamespace.MAX_CLOCK) XperienceImportNamespace.invalid()
                val actor = index.text(registerFields.getValue("actor"), 256) ?: XperienceImportNamespace.invalid()
                if (XperienceImportNamespace.canonicalUUID(actor) == null) XperienceImportNamespace.invalid()
                val valueSlice = registerFields.getValue("value")
                if (index.isNull(valueSlice)) {
                    retainedBudget?.releaseRegister(stable.size.toLong() + canonical.size)
                    return RegisterCapture(null, index, registerFields, emptyMap(), null, valueIsNull = true)
                }
                val valueFields = index.objectFields(Slice(valueSlice.start, valueSlice.end))
                val version = index.long(valueFields["schemaVersion"], 20) ?: XperienceImportNamespace.invalid()
                if (version != 1L) XperienceImportNamespace.reject(XperienceCollections.Failure.UNSUPPORTED_SAVED_FORMAT)
                if (index.text(valueFields["importID"], 512) != namespace.toString().lowercase()) XperienceImportNamespace.invalid()
                val payload = XperienceImportNamespace.decodePayload(index, valueFields)
                val baseline = ValidatedRegister(stable, canonical, valueSlice.start, valueSlice.end, namespace)
                return RegisterCapture(baseline, index, registerFields, valueFields, payload, valueIsNull = false)
            }
        }
    }

    /** Result of capture lets read reuse its bounded indexes rather than reparsing the wrapper. */
    internal data class RegisterCapture(
        val baseline: ValidatedRegister?,
        val index: SliceIndex,
        val registerFields: Map<String, Member>,
        val valueFields: Map<String, Member>,
        val payload: Payload?,
        val valueIsNull: Boolean,
    )

    internal data class Slice(val start: Int, val end: Int)
    internal data class Member(val keyStart: Int, val keyEnd: Int, val start: Int, val end: Int)

    /** Source-range index: keys/ranges only, no recursive child ByteArray maps or AST. */
    internal class SliceIndex(
        private val raw: ByteArray,
        private val maximumWorkspace: Long = XperienceImportNamespace.MAX_INDEX_WORKSPACE_BYTES,
        private val retainedBudget: RetainedBudget? = null,
    ) {
        private var reserved = 0L
        private var work = 0L
        private var cursor = 0
        private fun reserve(bytes: Long) {
            if (bytes < 0 || bytes > maximumWorkspace - reserved) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            retainedBudget?.reserve(bytes)
            reserved += bytes
        }
        private fun reserveLocal(bytes: Long) {
            if (bytes < 0 || bytes > maximumWorkspace - reserved) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            reserved += bytes
        }

        fun rootObjectFields(): LinkedHashMap<String, Member> {
            var start = 0
            var end = raw.size
            while (start < end && raw[start].toInt() in WS) start++
            while (end > start && raw[end - 1].toInt() in WS) end--
            val fields = objectFields(Slice(start, end))
            charge(raw.size)
            return fields
        }

        fun objectFields(value: Slice): LinkedHashMap<String, Member> {
            if (value.start < 0 || value.end > raw.size || value.start >= value.end || raw[value.start].toInt().toChar() != '{') XperienceImportNamespace.invalid()
            reserve(512)
            val fields = LinkedHashMap<String, Member>()
            val normalized = HashSet<String>()
            cursor = value.start + 1
            whitespace(value.end)
            if (take('}', value.end)) {
                if (cursor != value.end) XperienceImportNamespace.invalid()
                return fields
            }
            while (true) {
                whitespace(value.end)
                val keyStart = cursor
                val keyEnd = scanString(cursor, value.end).also { cursor = it }
                val keySize = (keyEnd - keyStart).toLong()
                reserve(256L + 8L * keySize)
                val key = decode(keyStart, keyEnd, 8L * keySize + 64L)
                if (!normalized.add(Normalizer.normalize(key, Normalizer.Form.NFC))) XperienceImportNamespace.reject(XperienceCollections.Failure.DUPLICATE_MEMBER)
                whitespace(value.end); expect(':', value.end); whitespace(value.end)
                val start = cursor
                val end = skipValue(value.end, 0)
                fields[key] = Member(keyStart, keyEnd, start, end)
                whitespace(value.end)
                if (take('}', value.end)) break
                expect(',', value.end)
            }
            if (cursor != value.end) XperienceImportNamespace.invalid()
            charge(value.end - value.start)
            return fields
        }

        fun text(member: Member?, maxTokenBytes: Int = MAX_REGISTER_BYTES): String? {
            if (member == null || raw.getOrNull(member.start)?.toInt()?.toChar() != '"') return null
            val size = member.end - member.start
            if (size > maxTokenBytes) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            reserve(8L * size + 64L)
            return runCatching { OHJson.text(raw.copyOfRange(member.start, member.end)) }.getOrNull()
        }

        fun long(member: Member?, maxTokenBytes: Int = 20): Long? {
            if (member == null) return null
            val size = member.end - member.start
            if (size > maxTokenBytes) return null
            reserve(8L * size + 64L)
            return runCatching { OHJson.integer(raw.copyOfRange(member.start, member.end)) }.getOrNull()
        }

        fun isNull(member: Member): Boolean = member.end - member.start == 4 &&
            raw[member.start] == 'n'.code.toByte() && raw[member.start + 1] == 'u'.code.toByte() &&
            raw[member.start + 2] == 'l'.code.toByte() && raw[member.start + 3] == 'l'.code.toByte()

        fun collectionBytes(member: Member): ByteArray {
            val size = member.end - member.start
            if (size <= 0 || size > XperienceCollections.MAX_BYTES) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            reserveLocal(XperienceImportNamespace.COLLECTION_PROJECTION_RESERVATION + size)
            retainedBudget?.reserve(XperienceImportNamespace.COLLECTION_PROJECTION_BASE + XperienceImportNamespace.COLLECTION_PROJECTION_MULTIPLIER * size)
            return raw.copyOfRange(member.start, member.end)
        }

        fun writeRange(member: Member, out: BoundedSink) {
            out.write(raw, member.start, member.end - member.start)
        }

        fun writeKey(member: Member, out: BoundedSink) {
            out.write(raw, member.keyStart, member.keyEnd - member.keyStart)
        }

        private fun skipValue(limit: Int, depth: Int): Int {
            val start = cursor
            valueSyntax(limit, depth)
            charge(cursor - start)
            return cursor
        }

        private fun valueSyntax(limit: Int, depth: Int) {
            whitespace(limit)
            if (depth > 128 || cursor >= limit) XperienceImportNamespace.invalid()
            when (raw[cursor].toInt().toChar()) {
                '"' -> cursor = scanString(cursor, limit)
                '{' -> {
                    cursor++; whitespace(limit)
                    if (take('}', limit)) return
                    while (true) {
                        whitespace(limit); cursor = scanString(cursor, limit); whitespace(limit); expect(':', limit)
                        valueSyntax(limit, depth + 1); whitespace(limit)
                        if (take('}', limit)) return
                        expect(',', limit)
                    }
                }
                '[' -> {
                    cursor++; whitespace(limit)
                    if (take(']', limit)) return
                    while (true) {
                        valueSyntax(limit, depth + 1); whitespace(limit)
                        if (take(']', limit)) return
                        expect(',', limit)
                    }
                }
                't' -> literal("true", limit)
                'f' -> literal("false", limit)
                'n' -> literal("null", limit)
                else -> number(limit)
            }
        }

        private fun literal(value: String, limit: Int) {
            for (c in value) if (cursor >= limit || raw[cursor++].toInt().toChar() != c) XperienceImportNamespace.invalid()
        }

        private fun number(limit: Int) {
            val start = cursor
            if (cursor < limit && raw[cursor].toInt() == '-'.code) cursor++
            if (cursor >= limit) XperienceImportNamespace.invalid()
            if (raw[cursor].toInt() == '0'.code) { cursor++; if (cursor < limit && digit(raw[cursor])) XperienceImportNamespace.invalid() }
            else { if (raw[cursor].toInt().toChar() !in '1'..'9') XperienceImportNamespace.invalid(); cursor++; while (cursor < limit && digit(raw[cursor])) cursor++ }
            if (cursor < limit && raw[cursor].toInt() == '.'.code) { cursor++; if (cursor >= limit || !digit(raw[cursor])) XperienceImportNamespace.invalid(); while (cursor < limit && digit(raw[cursor])) cursor++ }
            if (cursor < limit && raw[cursor].toInt().toChar() in charArrayOf('e', 'E')) { cursor++; if (cursor < limit && raw[cursor].toInt().toChar() in charArrayOf('+', '-')) cursor++; if (cursor >= limit || !digit(raw[cursor])) XperienceImportNamespace.invalid(); while (cursor < limit && digit(raw[cursor])) cursor++ }
            if (cursor == start) XperienceImportNamespace.invalid()
        }

        private fun whitespace(limit: Int) { while (cursor < limit && raw[cursor].toInt() in WS) cursor++ }
        private fun take(char: Char, limit: Int): Boolean { whitespace(limit); if (cursor < limit && raw[cursor].toInt() == char.code) { cursor++; return true }; return false }
        private fun expect(char: Char, limit: Int) { if (!take(char, limit)) XperienceImportNamespace.invalid() }

        private fun scanString(start: Int, limit: Int): Int {
            var at = start
            if (at >= limit || raw[at++].toInt() != '"'.code) XperienceImportNamespace.invalid()
            while (at < limit) {
                val b = raw[at++].toInt() and 0xff
                when (b) {
                    '"'.code -> return at
                    '\\'.code -> {
                        if (at >= limit) XperienceImportNamespace.invalid()
                        val e = raw[at++].toInt().toChar()
                        if (e == 'u') repeat(4) { if (at >= limit) XperienceImportNamespace.invalid(); val h = raw[at++].toInt().toChar().lowercaseChar(); if (h !in '0'..'9' && h !in 'a'..'f') XperienceImportNamespace.invalid() }
                        else if (e !in charArrayOf('"', '\\', '/', 'b', 'f', 'n', 'r', 't')) XperienceImportNamespace.invalid()
                    }
                    in 0..0x1f -> XperienceImportNamespace.invalid()
                }
            }
            XperienceImportNamespace.invalid()
        }

        private fun charge(bytes: Int) {
            work += bytes.toLong()
            if (work > XperienceImportNamespace.MAX_INDEX_SCAN_BYTES) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
        }

        private fun decode(start: Int, end: Int, charge: Long): String {
            reserve(charge)
            return runCatching { OHJson.text(raw.copyOfRange(start, end)) }.getOrElse { XperienceImportNamespace.invalid() }
        }

        private fun digit(byte: Byte): Boolean = byte.toInt() in '0'.code..'9'.code
        private fun invalid(): Nothing = XperienceImportNamespace.reject(XperienceCollections.Failure.INVALID_NAMESPACE)

        companion object { private val WS = intArrayOf(9, 10, 13, 32) }
    }

    class Edit internal constructor(
        val namespace: UUID,
        val field: String,
        private val expected: ValidatedRegister?,
        value: ByteArray,
    ) {
        private val valueBytes = copyBoundedValue(value)
        init {
            if (field != XperienceImportNamespace.field(namespace) || (expected != null && expected.namespace != namespace)) XperienceImportNamespace.invalid()
        }
        fun expectedRegister(): ByteArray? = expected?.rawCopy()
        fun value(): ByteArray = valueBytes.copyOf()

        /** Semantic raw-register CAS; identical bytes shortcut only follows validated capture. */
        fun baselineMatches(current: ByteArray?): Boolean = when {
            current == null && expected == null -> true
            current == null || expected == null -> false
            else -> expected.matches(current)
        }
    }

    class Saved internal constructor(
        val namespace: UUID,
        val field: String,
        val label: String,
        val document: XperienceCollections.Document,
        val bindings: Map<String, Binding>,
        internal val baseline: ValidatedRegister,
        internal val valueStart: Int,
        internal val valueEnd: Int,
    ) {
        init { if (baseline.namespace != namespace || field != XperienceImportNamespace.field(namespace)) XperienceImportNamespace.invalid() }
        fun register(): ByteArray = baseline.rawCopy()
        fun replacement(document: XperienceCollections.Document, label: String, bindings: Map<String, Binding>): Edit =
            replace(this, document, label, bindings)
    }

    fun field(namespace: UUID): String = PREFIX + namespace.toString().lowercase()

    fun append(
        document: XperienceCollections.Document,
        label: String,
        namespace: UUID = UUID.randomUUID(),
        bindings: Map<String, Binding> = emptyMap(),
    ): Edit {
        val value = envelope(document, label, namespace, previousIndex = null, previousRange = null, bindings = bindings)
        return Edit(namespace, field(namespace), expected = null, value = value)
    }

    fun replace(saved: Saved, document: XperienceCollections.Document, label: String,
                bindings: Map<String, Binding>): Edit {
        val index = saved.baseline.index(MAX_REPLACE_INDEX_BYTES)
        val valueRange = Slice(saved.valueStart, saved.valueEnd)
        val previousFields = index.objectFields(valueRange)
        val value = envelope(document, label, saved.namespace, previousIndex = index,
            previousRange = previousFields, bindings = bindings)
        return Edit(saved.namespace, saved.field, saved.baseline, value)
    }

    fun read(field: String, register: ByteArray): Saved {
        val namespace = parseField(field) ?: XperienceImportNamespace.invalid()
        val capture = ValidatedRegister.capture(register, namespace)
        if (capture.valueIsNull) XperienceImportNamespace.invalid()
        return readCaptured(field, capture)
    }

    private fun readCaptured(field: String, capture: RegisterCapture): Saved {
        val baseline = capture.baseline ?: XperienceImportNamespace.invalid()
        val payload = capture.payload ?: XperienceImportNamespace.invalid()
        val namespace = baseline.namespace
        val valueMember = capture.registerFields.getValue("value")
        return Saved(namespace, field, payload.label, payload.document, payload.bindings, baseline,
            valueMember.start, valueMember.end)
    }

    private fun decodePayload(index: SliceIndex, valueFields: Map<String, Member>): Payload {
        val label = index.text(valueFields["label"], 2_048)?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= MAX_LABEL_BYTES } ?: XperienceImportNamespace.invalid()
        val collections = valueFields["collections"] ?: XperienceImportNamespace.invalid()
        val document = XperienceCollections.project(index.collectionBytes(collections))
        val fingerprint = index.text(valueFields["fingerprint"], 512) ?: XperienceImportNamespace.invalid()
        if (fingerprint != document.fingerprint) XperienceImportNamespace.invalid()
        val sourceKeys = document.collections.flatMap { it.folders }.flatMap { it.sources }
            .filter { it.isAddon }.map { it.semanticDigest }.toSet()
        val bindingsMember = valueFields["bindings"] ?: XperienceImportNamespace.invalid()
        val rawBindings = index.objectFields(Slice(bindingsMember.start, bindingsMember.end))
        val bindings = linkedMapOf<String, Binding>()
        for ((key, mappingMember) in rawBindings) {
            if (key !in sourceKeys) XperienceImportNamespace.invalid()
            val mapping = index.objectFields(Slice(mappingMember.start, mappingMember.end))
            if (mapping.keys != setOf("manifestID", "transport")) XperienceImportNamespace.invalid()
            val manifestID = index.text(mapping["manifestID"], MAX_REGISTER_BYTES)?.takeIf { it.isNotEmpty() } ?: XperienceImportNamespace.invalid()
            val transportMember = mapping["transport"] ?: XperienceImportNamespace.invalid()
            val transport = index.objectFields(Slice(transportMember.start, transportMember.end))
            if (transport.keys != setOf("fingerprint")) XperienceImportNamespace.invalid()
            val fingerprintValue = index.text(transport["fingerprint"], 512)?.takeIf { HEX64.matches(it) } ?: XperienceImportNamespace.invalid()
            bindings[key] = Binding(manifestID, fingerprintValue)
        }
        return Payload(label, document, bindings)
    }

    /** Whole-profile read cap keeps the retained Saved snapshots bounded across the batch. */
    fun readAll(fields: Map<String, ByteArray?>, retainedBudget: RetainedBudget = RetainedBudget()): List<Saved> {
        val names = readNames(fields, retainedBudget)
        return names.mapNotNull { field ->
            val register = fields[field] ?: XperienceImportNamespace.invalid()
            val namespace = parseField(field) ?: XperienceImportNamespace.invalid()
            val capture = ValidatedRegister.capture(register, namespace, retainedBudget)
            if (capture.valueIsNull) null else readCaptured(field, capture)
        }
    }

    /** Per-field presentation status, never extra write authority or an absent-register witness. */
    sealed interface Observation {
        val field: String
        data class Supported(val saved: Saved) : Observation { override val field: String get() = saved.field }
        data class Tombstone(override val field: String) : Observation
        data class ReadOnly(override val field: String, val reason: XperienceCollections.Failure) : Observation
    }

    /** Same WHOLE-family preflight and original raw capture as readAll. Unsupported siblings
     * remain occupied/read-only without hiding valid Saved rows; resource denial stays global. */
    fun readIsolated(fields: Map<String, ByteArray?>, retainedBudget: RetainedBudget = RetainedBudget()): List<Observation> {
        val names = readNames(fields, retainedBudget)
        // Additional result/status objects and references are charged under the existing limit.
        retainedBudget.reserve(128L * names.size)
        return names.map { field ->
            try {
                val register = fields[field] ?: XperienceImportNamespace.invalid()
                val namespace = parseField(field) ?: XperienceImportNamespace.invalid()
                val capture = ValidatedRegister.capture(register, namespace, retainedBudget)
                if (capture.valueIsNull) Observation.Tombstone(field)
                else Observation.Supported(readCaptured(field, capture))
            } catch (rejected: XperienceCollections.Rejected) {
                if (rejected.reason == XperienceCollections.Failure.TOO_LARGE) throw rejected
                Observation.ReadOnly(field, rejected.reason)
            }
        }
    }

    /** Shared original preflight. callerInputBytes remains the COMPLETE family during every
     * canonical pass; neither isolated presentation nor a caller can reset it to one record. */
    private fun readNames(fields: Map<String, ByteArray?>, retainedBudget: RetainedBudget): List<String> {
        val names = ArrayList<String>()
        for (field in fields.keys) {
            if (!field.startsWith(PREFIX)) continue
            if (names.size >= MAX_READ_ALL_FIELDS) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
            names += field
        }
        names.sort()
        var totalBytes = 0L
        for (field in names) {
            val bytes = fields[field] ?: XperienceImportNamespace.invalid()
            totalBytes += bytes.size
            if (totalBytes > MAX_REGISTER_BYTES) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
        }
        retainedBudget.setCallerInputBytes(totalBytes)
        retainedBudget.reserve(24L * names.size)
        return names
    }

    private fun envelope(document: XperienceCollections.Document, label: String, namespace: UUID,
                         previousIndex: SliceIndex?, previousRange: Map<String, Member>?,
                         bindings: Map<String, Binding>): ByteArray {
        if (label.trim().isEmpty() || label.toByteArray(Charsets.UTF_8).size > MAX_LABEL_BYTES) XperienceImportNamespace.invalid()
        val checked = projectDocument(document)
        val allowedBindings = checked.collections.flatMap { it.folders }.flatMap { it.sources }
            .filter { it.isAddon }.map { it.semanticDigest }.toSet()
        if (bindings.keys.any { it !in allowedBindings }) XperienceImportNamespace.invalid()
        val out = BoundedSink(MAX_VALUE_BYTES)
        out.byte('{'.code)
        var comma = false
        if (previousRange != null && previousIndex != null) {
            for ((key, member) in previousRange) {
                if (key in OWNED_VALUE_KEYS) continue
                if (comma) out.byte(','.code)
                previousIndex.writeKey(member, out)
                out.byte(':'.code)
                previousIndex.writeRange(member, out)
                comma = true
            }
        }
        fun field(key: String, value: (BoundedSink) -> Unit) {
            if (comma) out.byte(','.code)
            out.quoted(key); out.byte(':'.code); value(out); comma = true
        }
        field("schemaVersion") { it.ascii("1") }
        field("importID") { it.quoted(namespace.toString().lowercase()) }
        field("label") { it.quoted(label) }
        field("fingerprint") { it.quoted(checked.fingerprint) }
        field("collections") { it.write(checked.raw()) }
        field("bindings") { sink -> writeBindings(sink, bindings) }
        out.byte('}'.code)
        return out.result()
    }

    private fun writeBindings(out: BoundedSink, bindings: Map<String, Binding>) {
        out.byte('{'.code)
        val keys = bindings.keys.sorted()
        keys.forEachIndexed { index, key ->
            val binding = bindings.getValue(key)
            if (binding.manifestID.isEmpty() || !HEX64.matches(binding.transportFingerprint)) XperienceImportNamespace.invalid()
            if (index > 0) out.byte(','.code)
            out.quoted(key); out.byte(':'.code); out.byte('{'.code)
            out.quoted("manifestID"); out.byte(':'.code); out.quoted(binding.manifestID); out.byte(','.code)
            out.quoted("transport"); out.byte(':'.code); out.byte('{'.code)
            out.quoted("fingerprint"); out.byte(':'.code); out.quoted(binding.transportFingerprint)
            out.byte('}'.code); out.byte('}'.code)
        }
        out.byte('}'.code)
    }

    private fun projectDocument(document: XperienceCollections.Document): XperienceCollections.Document {
        val raw = document.raw()
        if (raw.isEmpty() || raw.size > XperienceCollections.MAX_BYTES) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
        val estimate = COLLECTION_PROJECTION_BASE + COLLECTION_PROJECTION_MULTIPLIER * raw.size
        if (estimate > COLLECTION_PROJECTION_RESERVATION) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
        return XperienceCollections.project(raw)
    }

    /** Bounded streaming writer; quoted strings never allocate an intermediate encoded array. */
    internal class BoundedSink(private val maximum: Int) {
        private val bytes = ByteArrayOutputStream()
        fun byte(value: Int) { ensure(1); bytes.write(value) }
        fun ascii(value: String) {
            ensure(value.length)
            for (c in value) { if (c.code > 0x7f) XperienceImportNamespace.invalid(); bytes.write(c.code) }
        }
        fun write(value: ByteArray) { write(value, 0, value.size) }
        fun write(value: ByteArray, start: Int, length: Int) { ensure(length); bytes.write(value, start, length) }
        fun quoted(value: String) {
            byte('"'.code)
            var at = 0
            while (at < value.length) {
                val first = value[at]
                val point = when {
                    Character.isHighSurrogate(first) && at + 1 < value.length && Character.isLowSurrogate(value[at + 1]) -> Character.toCodePoint(first, value[at + 1]).also { at += 2 }
                    Character.isSurrogate(first) -> XperienceImportNamespace.invalid()
                    else -> first.code.also { at++ }
                }
                when (point) {
                    '"'.code -> ascii("\\\"")
                    '\\'.code -> ascii("\\\\")
                    8 -> ascii("\\b")
                    12 -> ascii("\\f")
                    10 -> ascii("\\n")
                    13 -> ascii("\\r")
                    9 -> ascii("\\t")
                    in 0..0x1f -> ascii("\\u" + point.toString(16).padStart(4, '0'))
                    in 0..0x7f -> byte(point)
                    in 0x80..0x7ff -> { byte(0xc0 or (point shr 6)); byte(0x80 or (point and 0x3f)) }
                    in 0x800..0xffff -> { byte(0xe0 or (point shr 12)); byte(0x80 or ((point shr 6) and 0x3f)); byte(0x80 or (point and 0x3f)) }
                    else -> { byte(0xf0 or (point shr 18)); byte(0x80 or ((point shr 12) and 0x3f)); byte(0x80 or ((point shr 6) and 0x3f)); byte(0x80 or (point and 0x3f)) }
                }
            }
            byte('"'.code)
        }
        fun result(): ByteArray = bytes.toByteArray()
        private fun ensure(additional: Int) { if (additional < 0 || bytes.size().toLong() + additional > maximum) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE) }
    }

    private fun parseField(field: String): UUID? {
        if (!field.startsWith(PREFIX)) return null
        return canonicalUUID(field.removePrefix(PREFIX))
    }
    private fun canonicalUUID(value: String): UUID? = runCatching { UUID.fromString(value).takeIf { it.toString() == value } }.getOrNull()
    private fun copyBoundedValue(value: ByteArray): ByteArray {
        if (value.isEmpty() || value.size > MAX_VALUE_BYTES) XperienceImportNamespace.reject(XperienceCollections.Failure.TOO_LARGE)
        return value.copyOf()
    }
    private fun invalid(): Nothing = throw XperienceCollections.Rejected(XperienceCollections.Failure.INVALID_NAMESPACE)
    private fun reject(failure: XperienceCollections.Failure): Nothing = throw XperienceCollections.Rejected(failure)
}
