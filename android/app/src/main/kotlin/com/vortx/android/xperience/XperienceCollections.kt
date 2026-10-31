package com.vortx.android.xperience

import com.vortx.android.engine.OHJson
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.math.BigDecimal
import java.math.RoundingMode
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale

/** Pure bounded reader/projector for the existing Apple Xperience collection-array format.
 * Raw value slices remain the source of truth; DTOs never rebuild imported unknown JSON. */
internal object XperienceCollections {
    const val MAX_BYTES = 512 * 1024
    const val MAX_DEPTH = 32
    const val MAX_NODES = 50_000
    const val MAX_COLLECTIONS = 100
    const val MAX_FOLDERS = 1_000
    const val MAX_SOURCES = 5_000
    internal const val MAX_REGISTER_CANONICAL_WORKSPACE_BYTES = 256L * 1024 * 1024

    enum class Failure {
        TOO_LARGE, INVALID_JSON, DUPLICATE_MEMBER, UNPRESERVABLE_NUMBER, INVALID_SCHEMA,
        DUPLICATE_COLLECTION, DUPLICATE_FOLDER, DUPLICATE_SOURCE, EMPTY_IMPORT,
        STALE_REGISTER, INVALID_NAMESPACE, UNSAFE_HOST_VALUE, UNSUPPORTED_SAVED_FORMAT,
    }

    class Rejected(val reason: Failure) : IllegalArgumentException(reason.name)
    enum class NoticeKind { UNSUPPORTED_VIEW_MODE, UNSUPPORTED_TILE_SHAPE, UNSUPPORTED_PROVIDER,
        MODERN_AND_LEGACY_SOURCES_DIFFER, ANIMATED_ARTWORK_RETAINED }
    data class Notice(val kind: NoticeKind, val collectionIndex: Int, val folderIndex: Int?, val sourceIndex: Int?)

    class Source internal constructor(
        raw: ByteArray, val provider: String, val addonId: String?, val type: String?,
        val catalogId: String?, val genre: String?, internal val semanticDigest: String,
    ) {
        private val sourceRaw = raw.copyOf()
        fun raw(): ByteArray = sourceRaw.copyOf()
        val isAddon: Boolean get() = provider.lowercase(Locale.ROOT) == "addon"
    }
    class Folder internal constructor(
        raw: ByteArray, val id: String, val title: String, val coverImageUrl: String?,
        val heroBackdropUrl: String?, val titleLogoUrl: String?, val tileShape: String,
        val hideTitle: Boolean, val sources: List<Source>,
    ) {
        private val folderRaw = raw.copyOf()
        fun raw(): ByteArray = folderRaw.copyOf()
    }
    class Collection internal constructor(
        raw: ByteArray, val id: String, val title: String, val backdropImageUrl: String?,
        val pinToTop: Boolean, val showAllTab: Boolean, val viewMode: String, val folders: List<Folder>,
    ) {
        private val collectionRaw = raw.copyOf()
        fun raw(): ByteArray = collectionRaw.copyOf()
    }
    class Document internal constructor(raw: ByteArray, val collections: List<Collection>, val notices: List<Notice>, fingerprint: String) {
        private val documentRaw = raw.copyOf()
        fun raw(): ByteArray = documentRaw.copyOf()
        val fingerprint: String = fingerprint
    }

    fun parse(bytes: ByteArray): Document = project(bytes)

    /** Also used when projecting a stored namespace; every nested unknown value is rechecked. */
    fun project(raw: ByteArray): Document {
        val scanned = try { BoundedScanner(raw).scan() } catch (failure: Rejected) { throw failure }
        catch (_: Throwable) { reject(Failure.INVALID_JSON) }
        val parsed = try { parseRaw(raw) } catch (failure: Rejected) { throw failure }
        catch (_: Throwable) { reject(Failure.INVALID_JSON) }
        // Reparse and budget the entire value tree, not only known fields.
        validateTree(parsed, 0, scanned.nodes)
        val root = array(parsed) ?: reject(Failure.INVALID_SCHEMA)
        if (root.isEmpty()) reject(Failure.EMPTY_IMPORT)
        if (root.size > MAX_COLLECTIONS) reject(Failure.TOO_LARGE)

        val notices = mutableListOf<Notice>()
        val collections = mutableListOf<Collection>()
        val seenCollections = hashSetOf<String>()
        var folderCount = 0
        var sourceCount = 0
        root.forEachIndexed { ci, item ->
            val fields = objectValue(item) ?: reject(Failure.INVALID_SCHEMA)
            val id = identity(fields["id"])
            val title = title(fields["title"])
            if (!seenCollections.add(id)) reject(Failure.DUPLICATE_COLLECTION)
            val backdrop = optionalString(fields["backdropImageUrl"])
            val pin = boolean(fields["pinToTop"], false)
            val showAll = boolean(fields["showAllTab"], true)
            boolean(fields["focusGlowEnabled"], true, allowNull = true)
            val mode = optionalString(fields["viewMode"]) ?: "TABBED_GRID"
            if (mode.uppercase(Locale.ROOT) !in setOf("TABBED_GRID", "FOLLOW_LAYOUT", "ROWS")) {
                notices += Notice(NoticeKind.UNSUPPORTED_VIEW_MODE, ci, null, null)
            }
            val rawFolders = array(fields["folders"]) ?: reject(Failure.INVALID_SCHEMA)
            folderCount += rawFolders.size
            if (folderCount > MAX_FOLDERS) reject(Failure.TOO_LARGE)
            val seenFolders = hashSetOf<String>()
            val folders = rawFolders.mapIndexed { fi, rawFolder ->
                val f = objectValue(rawFolder) ?: reject(Failure.INVALID_SCHEMA)
                val folderID = identity(f["id"])
                val folderTitle = title(f["title"])
                if (!seenFolders.add(folderID)) reject(Failure.DUPLICATE_FOLDER)
                val cover = optionalString(f["coverImageUrl"])
                val hero = optionalString(f["heroBackdropUrl"])
                val logo = optionalString(f["titleLogoUrl"])
                optionalString(f["coverEmoji"])
                val gif = optionalString(f["focusGifUrl"])
                val video = optionalString(f["heroVideoUrl"])
                val focusVideo = optionalString(f["focusVideoUrl"])
                val focusWebm = optionalString(f["focusVideoWebmUrl"])
                boolean(f["focusGifEnabled"], true, allowNull = true)
                val shape = optionalString(f["tileShape"]) ?: "SQUARE"
                val hideTitle = boolean(f["hideTitle"], false)
                if (shape.uppercase(Locale.ROOT) !in setOf("POSTER", "LANDSCAPE", "WIDE", "SQUARE")) {
                    notices += Notice(NoticeKind.UNSUPPORTED_TILE_SHAPE, ci, fi, null)
                }
                if (listOf(gif, video, focusVideo, focusWebm).any { !it.isNullOrEmpty() }) {
                    notices += Notice(NoticeKind.ANIMATED_ARTWORK_RETAINED, ci, fi, null)
                }
                val modern = sourceArray(f["sources"], legacy = false)
                val legacy = sourceArray(f["catalogSources"], legacy = true)
                if (modern.isNotEmpty() && legacy.isNotEmpty() &&
                    modern.map(Source::semanticDigest) != legacy.map(Source::semanticDigest)) {
                    notices += Notice(NoticeKind.MODERN_AND_LEGACY_SOURCES_DIFFER, ci, fi, null)
                }
                val sources = if (modern.isEmpty()) legacy else modern
                sourceCount += modern.size + legacy.size
                if (sourceCount > MAX_SOURCES) reject(Failure.TOO_LARGE)
                sources.forEachIndexed { si, source ->
                    if (!source.isAddon) notices += Notice(NoticeKind.UNSUPPORTED_PROVIDER, ci, fi, si)
                }
                Folder(rawFolder, folderID, folderTitle, cover, hero, logo, shape, hideTitle, sources)
            }
            collections += Collection(item, id, title, backdrop, pin, showAll, mode, folders)
        }
        return Document(raw, collections, notices, digest(canonicalData(raw)))
    }

    /** Apple-style collection canonicalization candidate. Actual platform golden parity remains open. */
    fun canonicalData(raw: ByteArray): ByteArray {
        val scanned = try { BoundedScanner(raw).scan() } catch (failure: Rejected) { throw failure }
        catch (_: Throwable) { reject(Failure.INVALID_JSON) }
        val root = try { parseRaw(raw) } catch (_: Throwable) { reject(Failure.INVALID_JSON) }
        validateTree(root, 0, scanned.nodes)
        return canonical(root).also(::requireCanonicalWithinLimit)
    }

    /** Whole register CAS has the shared raw JSON envelope limit, not the collection cap. */
    internal fun canonicalRegisterData(raw: ByteArray): ByteArray {
        return RegisterCanonicalizer(raw).encode()
    }

    internal fun requireCanonicalWithinLimit(bytes: ByteArray, maximumBytes: Int = MAX_BYTES) {
        if (maximumBytes < 0 || bytes.size > maximumBytes) reject(Failure.TOO_LARGE)
    }

    internal fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }

    private fun sourceArray(raw: ByteArray?, legacy: Boolean): List<Source> {
        if (raw == null || isNull(raw)) return emptyList()
        val items = array(raw) ?: reject(Failure.INVALID_SCHEMA)
        if (items.size > MAX_SOURCES) reject(Failure.INVALID_SCHEMA)
        val seen = hashSetOf<String>()
        return items.map { item ->
            val value = objectValue(item) ?: reject(Failure.INVALID_SCHEMA)
            val provider = if (legacy) "addon" else optionalString(value["provider"]) ?: "addon"
            val addon = optionalString(value["addonId"])
            val type = optionalString(value["type"])
            val catalog = optionalString(value["catalogId"])
            val genre = optionalString(value["genre"])
            if (provider.lowercase(Locale.ROOT) == "addon") {
                identity(addon?.let(::quote)); identity(type?.let(::quote)); identity(catalog?.let(::quote))
            }
            val semantic = if (provider.lowercase(Locale.ROOT) == "addon") {
                OHJson.array(listOf(quote("addon"), addon?.let(::quote) ?: OHJson.literal("null"),
                    type?.let(::quote) ?: OHJson.literal("null"), catalog?.let(::quote) ?: OHJson.literal("null"),
                    genre?.let(::quote) ?: OHJson.literal("null")))
            } else item
            val semanticHash = digest(canonicalData(semantic))
            if (!seen.add(semanticHash)) reject(Failure.DUPLICATE_SOURCE)
            Source(item, provider, addon, type, catalog, genre, semanticHash)
        }
    }

    private fun validateTree(raw: ByteArray, depth: Int, countedNodes: Int) {
        if (raw.size > MAX_BYTES || depth > MAX_DEPTH || countedNodes > MAX_NODES) reject(Failure.TOO_LARGE)
        when (kind(raw)) {
            '{' -> objectValue(raw)?.values?.forEach { validateTree(it, depth + 1, countedNodes) }
            '[' -> array(raw)?.forEach { validateTree(it, depth + 1, countedNodes) }
            '"' -> string(raw)
            'n' -> if (!isNull(raw)) reject(Failure.INVALID_JSON)
            't' -> if (!raw.contentEquals(OHJson.literal("true"))) reject(Failure.INVALID_JSON)
            'f' -> if (!raw.contentEquals(OHJson.literal("false"))) reject(Failure.INVALID_JSON)
            else -> validateNumber(raw)
        }
    }

    private fun validateNumber(raw: ByteArray) {
        val text = try { OHJson.utf8(raw).trim() } catch (_: Throwable) { reject(Failure.INVALID_JSON) }
        portableSwiftNumber(text)
    }

    private fun normalizedNumber(input: String): String {
        val lower = input.lowercase(Locale.ROOT)
        val negative = lower.startsWith('-')
        val positive = if (negative) lower.substring(1) else lower
        val eAt = positive.indexOf('e')
        val mantissa = if (eAt < 0) positive else positive.substring(0, eAt)
        val exponent = if (eAt < 0) 0 else positive.substring(eAt + 1).toIntOrNull()
            ?: reject(Failure.UNPRESERVABLE_NUMBER)
        if (exponent !in -100_000..100_000) reject(Failure.UNPRESERVABLE_NUMBER)
        val dot = mantissa.indexOf('.')
        val fractional = if (dot < 0) 0 else mantissa.length - dot - 1
        val digits = mantissa.replace(".", "")
        if (digits.isEmpty() || digits.any { it !in '0'..'9' }) reject(Failure.INVALID_JSON)
        var power = exponent - fractional
        var first = 0
        while (first < digits.length && digits[first] == '0') first++
        if (first == digits.length) return "0"
        var end = digits.length
        while (first < end && digits[end - 1] == '0') { end--; power++ }
        return (if (negative) "-" else "") + digits.substring(first, end) + "e" + power
    }

    private fun canonical(raw: ByteArray): ByteArray = when (kind(raw)) {
        '{' -> {
            val objectValue = objectValue(raw) ?: reject(Failure.INVALID_JSON)
            val out = ByteArrayOutputStream()
            out.write('{'.code)
            objectValue.keys.sortedWith(Comparator { left, right -> compareUtf8(left, right) }).forEachIndexed { index, key ->
                if (index > 0) out.write(','.code)
                out.write(canonicalQuote(key))
                out.write(':'.code)
                out.write(canonical(objectValue.getValue(key)))
            }
            out.write('}'.code)
            out.toByteArray()
        }
        '[' -> OHJson.array((array(raw) ?: reject(Failure.INVALID_JSON)).map(::canonical))
        '"' -> canonicalQuote(string(raw) ?: reject(Failure.INVALID_JSON))
        't', 'f', 'n' -> trim(raw)
        else -> canonicalNumber(raw)
    }

    /** Swift Foundation's modern sortedKeys ordering compares UTF-8 bytes. */
    private fun compareUtf8(left: String, right: String): Int {
        val a = left.toByteArray(Charsets.UTF_8)
        val b = right.toByteArray(Charsets.UTF_8)
        val common = minOf(a.size, b.size)
        for (index in 0 until common) {
            val difference = (a[index].toInt() and 0xff) - (b[index].toInt() and 0xff)
            if (difference != 0) return difference
        }
        return a.size - b.size
    }

    /** UTF-8 lexicographic order preserves Unicode scalar order; compare without key-byte copies. */
    private fun compareUtf8Scalars(left: String, right: String): Int {
        var a = 0
        var b = 0
        while (a < left.length && b < right.length) {
            val leftPoint = left.codePointAt(a)
            val rightPoint = right.codePointAt(b)
            if (leftPoint != rightPoint) return leftPoint - rightPoint
            a += Character.charCount(leftPoint)
            b += Character.charCount(rightPoint)
        }
        return (left.length - a) - (right.length - b)
    }

    /** Short JSON control escapes used by Foundation JSONWriter's modern mode. */
    private fun canonicalQuote(value: String): ByteArray {
        val out = StringBuilder(value.length + 2).append('"')
        var index = 0
        while (index < value.length) {
            val current = value[index++]
            when (current) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\b' -> out.append("\\b")
                '\u000c' -> out.append("\\f")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> when {
                    current.code < 0x20 -> out.append("\\u").append(current.code.toString(16).padStart(4, '0'))
                    Character.isHighSurrogate(current) -> {
                        if (index >= value.length || !Character.isLowSurrogate(value[index])) reject(Failure.INVALID_JSON)
                        out.append(current).append(value[index++])
                    }
                    Character.isLowSurrogate(current) -> reject(Failure.INVALID_JSON)
                    else -> out.append(current)
                }
            }
        }
        return out.append('"').toString().toByteArray(Charsets.UTF_8)
    }

    private fun canonicalNumber(raw: ByteArray): ByteArray {
        return canonicalNumberText(OHJson.utf8(raw).trim())
    }

    private fun canonicalNumberText(text: String): ByteArray = OHJson.literal(portableSwiftNumber(text))

    /** Model VortxJSON's Int64 -> UInt64 -> Double decoding order, then enforce the unchanged
     * raw numeric-value guard. Integral decimal/exponent tokens can decode as integers too.
     * The modern Foundation Decimal slow path is a source reference, not this SDK's runtime proof. */
    private fun portableSwiftNumber(text: String): String {
        val before = normalizedNumber(text)
        val encoded = swiftFixedWidthInteger(before) ?: run {
            // Apple StrictParser maps a failed/non-finite SDK Double decode to INVALID_JSON.
            // Raw exponent bounds above still fail first as UNPRESERVABLE_NUMBER.
            val number = text.toDoubleOrNull() ?: reject(Failure.INVALID_JSON)
            if (!number.isFinite()) reject(Failure.INVALID_JSON)
            swiftShortestDouble(number)
        }
        if (before != normalizedNumber(encoded)) reject(Failure.UNPRESERVABLE_NUMBER)
        return encoded
    }

    /** Only a normalized integer whose complete spelling fits <=20 digits reaches BigInteger.
     * Never allocate a BigInteger/BigDecimal from an arbitrary raw number lexeme. */
    private fun swiftFixedWidthInteger(normalized: String): String? {
        if (normalized == "0") return "0" // Int64 also owns every spelling of negative zero.
        val exponentAt = normalized.lastIndexOf('e')
        val coefficient = normalized.substring(0, exponentAt)
        val power = normalized.substring(exponentAt + 1).toInt()
        if (power < 0) return null
        val negative = coefficient.startsWith('-')
        val digits = if (negative) coefficient.substring(1) else coefficient
        if (digits.length.toLong() + power > 20L) return null
        val decimal = coefficient + "0".repeat(power)
        decimal.toLongOrNull()?.let { return it.toString() }
        if (!negative && runCatching { BigInteger(decimal) <= UINT64_MAX }.getOrDefault(false)) return decimal
        return null
    }

    /** Portable shortest-roundtrip search from the exact finite binary64 value, independent of
     * JDK Double.toString versions. At most 17 precisions x3 adjacent decimal-grid candidates.
     * Choose minimum digits, then nearest exact value, then an even last digit (Swift's contract).
     * BigDecimal(Double) is exact and bounded by binary64, even for the smallest subnormal. */
    private fun swiftShortestDouble(number: Double): String {
        if (number == 0.0) return "0" // A nonzero lexeme that underflowed still fails the raw guard.
        val magnitude = kotlin.math.abs(number)
        val bits = magnitude.toRawBits()
        val exact = BigDecimal(magnitude)
        val base10Exponent = exact.precision() - exact.scale() - 1
        for (precision in 1..17) {
            val power = base10Exponent - precision + 1
            val center = exact.scaleByPowerOfTen(-power).setScale(0, RoundingMode.HALF_EVEN).toBigIntegerExact()
            var best: BigDecimal? = null
            var bestDistance: BigDecimal? = null
            for (offset in -1..1) {
                val coefficient = center.add(BigInteger.valueOf(offset.toLong()))
                if (coefficient.signum() <= 0) continue
                val candidate = BigDecimal(coefficient).scaleByPowerOfTen(power).stripTrailingZeros()
                if (candidate.precision() > precision || candidate.toDouble().toRawBits() != bits) continue
                val distance = exact.subtract(candidate).abs()
                val prior = best
                val closer = if (prior == null) true else {
                    val comparison = distance.compareTo(checkNotNull(bestDistance))
                    val even = !candidate.unscaledValue().testBit(0)
                    val priorEven = !prior.unscaledValue().testBit(0)
                    comparison < 0 || (comparison == 0 && (even && !priorEven || even == priorEven && candidate < prior))
                }
                if (closer) { best = candidate; bestDistance = distance }
            }
            best?.let { return formatSwiftDouble(number, it) }
        }
        // IEEE binary64 always has a <=17-significant-digit roundtrip. Never fall back to a
        // platform-dependent spelling if a future refactor violates that invariant.
        reject(Failure.UNPRESERVABLE_NUMBER)
    }

    /** Swift _Float64ToASCII/_finishFormatting policy, not a guessed positive decimal threshold.
     * The preceding fixed-width admission owns representable integral values before this route. */
    private fun formatSwiftDouble(number: Double, shortest: BigDecimal): String {
        val magnitudeBits = kotlin.math.abs(number).toRawBits()
        val exponentBits = ((magnitudeBits ushr 52) and 0x7ffL).toInt()
        val fractionBits = magnitudeBits and 0x000fffffffffffffL
        val binaryExponent = if (exponentBits == 0) 1 - 1075 else exponentBits - 1075
        val forceExponential = binaryExponent > 1 || binaryExponent == 1 && fractionBits != 0L
        val digits = shortest.unscaledValue().abs().toString()
        val exponent = digits.length - shortest.scale() - 1
        val sign = if (number < 0.0) "-" else ""
        if (exponent < -4 || forceExponential) {
            val mantissa = if (digits.length == 1) digits else digits.substring(0, 1) + "." + digits.substring(1)
            val exponentSign = if (exponent < 0) "-" else "+"
            return sign + mantissa + "e" + exponentSign + kotlin.math.abs(exponent).toString().padStart(2, '0')
        }
        return sign + shortest.toPlainString()
    }

    private fun objectValue(raw: ByteArray?): Map<String, ByteArray>? {
        if (raw == null || kind(raw) != '{') return null
        val value = OHJson.Obj(trim(raw))
        return value.keys.associateWith(value::raw)
    }
    private fun array(raw: ByteArray?): List<ByteArray>? {
        if (raw == null || kind(raw) != '[') return null
        return OHJson.array(trim(raw))
    }
    private fun string(raw: ByteArray?): String? = if (raw == null || kind(raw) != '"') null else OHJson.text(trim(raw))
    private fun optionalString(raw: ByteArray?): String? {
        if (raw == null || isNull(raw)) return null
        return string(raw) ?: reject(Failure.INVALID_SCHEMA)
    }
    private fun identity(raw: ByteArray?): String {
        val value = string(raw) ?: reject(Failure.INVALID_SCHEMA)
        if (value.trim().isEmpty() || value.toByteArray(Charsets.UTF_8).size > 1024 || hasControlOrFormat(value)) reject(Failure.INVALID_SCHEMA)
        return value
    }
    private fun title(raw: ByteArray?): String {
        val value = string(raw) ?: reject(Failure.INVALID_SCHEMA)
        if (value.trim().isEmpty()) reject(Failure.INVALID_SCHEMA)
        return value
    }
    private fun boolean(raw: ByteArray?, fallback: Boolean, allowNull: Boolean = false): Boolean {
        if (raw == null) return fallback
        if (isNull(raw) && allowNull) return fallback
        return when (OHJson.utf8(trim(raw))) { "true" -> true; "false" -> false; else -> reject(Failure.INVALID_SCHEMA) }
    }
    private fun hasControlOrFormat(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            val first = value[index]
            val codePoint = if (Character.isHighSurrogate(first)) {
                if (index + 1 >= value.length || !Character.isLowSurrogate(value[index + 1])) return true
                Character.toCodePoint(first, value[index + 1]).also { index += 2 }
            } else {
                if (Character.isLowSurrogate(first)) return true
                first.code.also { index++ }
            }
            val category = Character.getType(codePoint)
            if (category == Character.CONTROL.toInt() || category == Character.FORMAT.toInt()) return true
        }
        return false
    }

    private fun parseRaw(raw: ByteArray, maximumBytes: Int = MAX_BYTES): ByteArray {
        if (raw.isEmpty() || raw.size > maximumBytes) reject(Failure.TOO_LARGE)
        try { OHJson.utf8(raw) } catch (_: Throwable) { reject(Failure.INVALID_JSON) }
        try {
            when (kind(raw)) {
                '{' -> OHJson.Obj(trim(raw))
                '[' -> OHJson.array(trim(raw))
                else -> { OHJson.Obj().set("v", trim(raw)) }
            }
        } catch (error: IllegalArgumentException) {
            if (error.message?.contains("Duplicate JSON key") == true) reject(Failure.DUPLICATE_MEMBER)
            reject(Failure.INVALID_JSON)
        } catch (_: Throwable) { reject(Failure.INVALID_JSON) }
        return raw.copyOf()
    }

    private fun kind(bytes: ByteArray): Char = trim(bytes).firstOrNull()?.toInt()?.toChar() ?: '\u0000'
    private fun trim(bytes: ByteArray): ByteArray {
        var start = 0; var end = bytes.size
        while (start < end && bytes[start].toInt() in WS) start++
        while (end > start && bytes[end - 1].toInt() in WS) end--
        return bytes.copyOfRange(start, end)
    }
    private fun isNull(bytes: ByteArray?): Boolean = bytes != null && trim(bytes).contentEquals(OHJson.literal("null"))
    private fun quote(value: String): ByteArray = OHJson.quote(value)
    private fun reject(failure: Failure): Nothing = throw Rejected(failure)

    private class BoundedScanner(private val bytes: ByteArray) {
        var at = 0
        var nodes = 0
        fun scan(): BoundedScanner {
            if (bytes.isEmpty() || bytes.size > MAX_BYTES) reject(Failure.TOO_LARGE)
            try { OHJson.utf8(bytes) } catch (_: Throwable) { reject(Failure.INVALID_JSON) }
            value(0); whitespace()
            if (at != bytes.size) reject(Failure.INVALID_JSON)
            return this
        }
        private fun value(depth: Int) {
            whitespace(); nodes++
            if (nodes > MAX_NODES || depth > MAX_DEPTH) reject(Failure.TOO_LARGE)
            if (at >= bytes.size) reject(Failure.INVALID_JSON)
            when (bytes[at].toInt().toChar()) {
                '{' -> {
                    at++; whitespace()
                    if (take('}')) return
                    while (true) {
                        whitespace(); quotedString(); whitespace(); expect(':'); value(depth + 1); whitespace()
                        if (take('}')) return
                        expect(',')
                    }
                }
                '[' -> {
                    at++; whitespace()
                    if (take(']')) return
                    while (true) {
                        value(depth + 1); whitespace()
                        if (take(']')) return
                        expect(',')
                    }
                }
                '"' -> quotedString()
                't' -> literal("true")
                'f' -> literal("false")
                'n' -> literal("null")
                else -> {
                    val start = at
                    while (at < bytes.size && bytes[at].toInt() !in WS && bytes[at].toInt().toChar() !in charArrayOf(',', ']', '}')) at++
                    if (start == at) reject(Failure.INVALID_JSON)
                }
            }
        }
        private fun quotedString() {
            expect('"')
            while (at < bytes.size) {
                val ch = bytes[at++].toInt() and 0xff
                if (ch == '"'.code) return
                if (ch == '\\'.code) { if (at >= bytes.size) reject(Failure.INVALID_JSON); at++ }
                else if (ch < 0x20) reject(Failure.INVALID_JSON)
            }
            reject(Failure.INVALID_JSON)
        }
        private fun literal(value: String) {
            val expected = value.toByteArray(Charsets.US_ASCII)
            if (at + expected.size > bytes.size || !bytes.copyOfRange(at, at + expected.size).contentEquals(expected)) reject(Failure.INVALID_JSON)
            at += expected.size
        }
        private fun whitespace() { while (at < bytes.size && bytes[at].toInt() in WS) at++ }
        private fun take(char: Char): Boolean { whitespace(); if (at < bytes.size && bytes[at].toInt() == char.code) { at++; return true }; return false }
        private fun expect(char: Char) { if (!take(char)) reject(Failure.INVALID_JSON) }
    }

    /**
     * Canonicalizes a whole profile register without constructing recursive raw-ByteArray trees.
     * Arrays stream in source order. Each active object holds only its own key/range index while
     * values are emitted to one bounded sink. Object members are rescanned once to find value
     * ranges, so work can grow with nesting depth; scan bytes and all live index/temp allocations
     * are explicitly budgeted before a register is compared.
     */
    private class RegisterCanonicalizer(private val bytes: ByteArray) {
        private data class Member(val key: String, val start: Int, val end: Int)
        private class Budget(private val limit: Long) {
            private var live = 0L
            fun reserve(bytes: Long) {
                if (bytes < 0 || bytes > limit - live) throw Rejected(Failure.TOO_LARGE)
                live += bytes
            }
            fun release(bytes: Long) { live -= bytes; check(live >= 0) }
        }

        private val budget = Budget(MAX_WORKSPACE_BYTES)
        private val output = ByteArrayOutputStream()
        private var at = 0
        private var scanWork = 0L

        fun encode(): ByteArray {
            if (bytes.isEmpty() || bytes.size > OHJson.MAX) throw Rejected(Failure.TOO_LARGE)
            // ByteArrayOutputStream may briefly retain its old buffer during growth and the
            // final toByteArray copy. Reserve the fixed worst-case sink allowance up front.
            budget.reserve(MAX_OUTPUT_PEAK_BYTES)
            whitespace()
            writeValue(0)
            whitespace()
            if (at != bytes.size) throw Rejected(Failure.INVALID_JSON)
            val result = output.toByteArray()
            if (result.size > OHJson.MAX) throw Rejected(Failure.TOO_LARGE)
            return result
        }

        private fun writeValue(depth: Int) {
            whitespace()
            if (depth > REGISTER_MAX_DEPTH || at >= bytes.size) throw Rejected(Failure.INVALID_JSON)
            when (bytes[at].toInt().toChar()) {
                '{' -> writeObject(depth)
                '[' -> writeArray(depth)
                '"' -> writeStringValue()
                't' -> writeLiteral("true")
                'f' -> writeLiteral("false")
                'n' -> writeLiteral("null")
                else -> writeNumber()
            }
        }

        private fun writeObject(depth: Int) {
            at++
            whitespace()
            budget.reserve(OBJECT_OVERHEAD)
            val fields = ArrayList<Member>()
            val seen = HashSet<String>()
            var objectAllocation = OBJECT_OVERHEAD
            try {
                if (!take('}')) {
                    while (true) {
                        whitespace()
                        val keyStart = at
                        val keyEnd = scanStringEnd()
                        val tokenSize = (keyEnd - keyStart).toLong()
                        val fieldAllocation = FIELD_OVERHEAD + 8L * tokenSize
                        budget.reserve(fieldAllocation)
                        objectAllocation += fieldAllocation
                        val key = decodeString(keyStart, keyEnd)
                        val normalized = Normalizer.normalize(key, Normalizer.Form.NFC)
                        if (!seen.add(normalized)) throw Rejected(Failure.DUPLICATE_MEMBER)
                        whitespace(); expect(':'); whitespace()
                        val valueStart = at
                        val valueEnd = skipValue(depth + 1)
                        fields += Member(key, valueStart, valueEnd)
                        whitespace()
                        if (take('}')) break
                        expect(',')
                    }
                }

                // UTF-8 byte order is equivalent to scalar-value order for valid Unicode scalar
                // strings; this avoids allocating a second encoded key array for every member.
                fields.sortWith(Comparator { left, right -> XperienceCollections.compareUtf8Scalars(left.key, right.key) })
                val objectEnd = at
                writeByte('{'.code)
                fields.forEachIndexed { index, field ->
                    if (index > 0) writeByte(','.code)
                    writeQuoted(field.key)
                    writeByte(':'.code)
                    at = field.start
                    writeValue(depth + 1)
                    if (at != field.end) throw Rejected(Failure.INVALID_JSON)
                    at = objectEnd
                }
                writeByte('}'.code)
            } finally {
                budget.release(objectAllocation)
            }
        }

        private fun writeArray(depth: Int) {
            at++
            writeByte('['.code)
            whitespace()
            if (take(']')) { writeByte(']'.code); return }
            var index = 0
            while (true) {
                if (index++ > 0) writeByte(','.code)
                writeValue(depth + 1)
                whitespace()
                if (take(']')) break
                expect(',')
            }
            writeByte(']'.code)
        }

        /** Finds a member's raw span without copying child slices or allocating a subtree. */
        private fun skipValue(depth: Int): Int {
            val start = at
            skipValueSyntax(depth)
            scanWork += (at - start).toLong()
            if (scanWork > MAX_REGISTER_SCAN_WORK_BYTES) throw Rejected(Failure.TOO_LARGE)
            return at
        }

        private fun skipValueSyntax(depth: Int) {
            whitespace()
            if (depth > REGISTER_MAX_DEPTH || at >= bytes.size) throw Rejected(Failure.INVALID_JSON)
            when (bytes[at].toInt().toChar()) {
                '{' -> {
                    at++; whitespace()
                    if (take('}')) return
                    while (true) {
                        scanStringEnd(); whitespace(); expect(':'); skipValueSyntax(depth + 1); whitespace()
                        if (take('}')) return
                        expect(',')
                    }
                }
                '[' -> {
                    at++; whitespace()
                    if (take(']')) return
                    while (true) {
                        skipValueSyntax(depth + 1); whitespace()
                        if (take(']')) return
                        expect(',')
                    }
                }
                '"' -> scanStringEnd()
                't' -> scanLiteral("true")
                'f' -> scanLiteral("false")
                'n' -> scanLiteral("null")
                else -> scanNumberEnd()
            }
        }

        private fun writeStringValue() {
            val start = at
            val end = scanStringEnd()
            val tokenSize = (end - start).toLong()
            val temporary = STRING_TEMP_OVERHEAD + 8L * tokenSize
            budget.reserve(temporary)
            try { writeQuoted(decodeString(start, end)) }
            finally { budget.release(temporary) }
        }

        private fun writeQuoted(value: String) {
            val escaped = XperienceCollections.canonicalQuote(value)
            write(escaped)
        }

        private fun decodeString(start: Int, end: Int): String {
            // OHJson.text validates escapes, surrogate pairing and UTF-8. Charge its bounded
            // token copy/decoder workspace before making the range copy.
            val tokenSize = (end - start).toLong()
            val temporary = STRING_DECODE_OVERHEAD + 4L * tokenSize
            budget.reserve(temporary)
            try { return OHJson.text(bytes.copyOfRange(start, end)) }
            finally { budget.release(temporary) }
        }

        private fun writeNumber() {
            val start = at
            val end = scanNumberEnd()
            val tokenSize = (end - start).toLong()
            // normalizedNumber/Double parsing can transiently hold several UTF-16 copies of a
            // long token. Reserve before copying/decoding it; very large but otherwise valid
            // tokens fail closed when the shared workspace ceiling cannot cover that peak.
            // Exact binary64 BigDecimal scratch has a fixed worst case unrelated to raw length;
            // reserve it before the formatter, including short subnormal tokens such as 5e-324.
            val temporary = NUMBER_TEMP_OVERHEAD + 12L * tokenSize + XperienceCollections.NUMBER_FORMAT_WORKSPACE_BYTES
            budget.reserve(temporary)
            try {
                val text = OHJson.utf8(bytes.copyOfRange(start, end))
                write(XperienceCollections.canonicalNumberText(text))
            } finally { budget.release(temporary) }
        }

        private fun writeLiteral(value: String) {
            scanLiteral(value)
            write(literalBytes(value))
        }

        private fun scanLiteral(value: String) {
            val expected = literalBytes(value)
            if (at + expected.size > bytes.size) throw Rejected(Failure.INVALID_JSON)
            for (index in expected.indices) if (bytes[at + index] != expected[index]) throw Rejected(Failure.INVALID_JSON)
            at += expected.size
        }

        /** Returns the exclusive end after validating JSON string escape syntax. */
        private fun scanStringEnd(): Int {
            expect('"')
            while (at < bytes.size) {
                val next = bytes[at++].toInt() and 0xff
                when (next) {
                    '"'.code -> return at
                    '\\'.code -> {
                        if (at >= bytes.size) throw Rejected(Failure.INVALID_JSON)
                        when (bytes[at++].toInt().toChar()) {
                            '"', '\\', '/' , 'b', 'f', 'n', 'r', 't' -> Unit
                            'u' -> repeat(4) {
                                if (at >= bytes.size || (bytes[at++].toInt().toChar() !in '0'..'9' &&
                                    bytes[at - 1].toInt().toChar().lowercaseChar() !in 'a'..'f')) {
                                    throw Rejected(Failure.INVALID_JSON)
                                }
                            }
                            else -> throw Rejected(Failure.INVALID_JSON)
                        }
                    }
                    in 0x00..0x1f -> throw Rejected(Failure.INVALID_JSON)
                    else -> Unit
                }
            }
            throw Rejected(Failure.INVALID_JSON)
        }

        private fun scanNumberEnd(): Int {
            val start = at
            if (takeRaw('-')) Unit
            if (at >= bytes.size) throw Rejected(Failure.INVALID_JSON)
            when (bytes[at].toInt().toChar()) {
                '0' -> { at++; if (at < bytes.size && isDigit(bytes[at])) throw Rejected(Failure.INVALID_JSON) }
                in '1'..'9' -> { at++; while (at < bytes.size && isDigit(bytes[at])) at++ }
                else -> throw Rejected(Failure.INVALID_JSON)
            }
            if (takeRaw('.')) {
                if (at >= bytes.size || !isDigit(bytes[at])) throw Rejected(Failure.INVALID_JSON)
                while (at < bytes.size && isDigit(bytes[at])) at++
            }
            if (at < bytes.size && bytes[at].toInt().toChar() in charArrayOf('e', 'E')) {
                at++
                if (at < bytes.size && bytes[at].toInt().toChar() in charArrayOf('+', '-')) at++
                if (at >= bytes.size || !isDigit(bytes[at])) throw Rejected(Failure.INVALID_JSON)
                while (at < bytes.size && isDigit(bytes[at])) at++
            }
            if (start == at) throw Rejected(Failure.INVALID_JSON)
            return at
        }

        private fun whitespace() { while (at < bytes.size && bytes[at].toInt() in XperienceCollections.WS) at++ }
        private fun take(char: Char): Boolean { whitespace(); return takeRaw(char) }
        private fun takeRaw(char: Char): Boolean {
            if (at < bytes.size && bytes[at].toInt() == char.code) { at++; return true }
            return false
        }
        private fun expect(char: Char) { if (!take(char)) throw Rejected(Failure.INVALID_JSON) }
        private fun writeByte(value: Int) { ensureOutput(1); output.write(value) }
        private fun write(value: ByteArray) { ensureOutput(value.size); output.write(value) }
        private fun ensureOutput(additional: Int) {
            if (additional < 0 || output.size().toLong() + additional > OHJson.MAX) throw Rejected(Failure.TOO_LARGE)
        }
        private fun isDigit(value: Byte) = value.toInt() in '0'.code..'9'.code

        companion object {
            private const val REGISTER_MAX_DEPTH = 128
            // The validated expected register keeps raw and canonical forms (at most 64 MiB)
            // while a current register is canonicalized. A 256 MiB pass cap plus two bounded
            // 32 MiB candidate buffers and the retained expected form gives a 384 MiB source
            // reservation ceiling for semantic comparison.
            private const val MAX_WORKSPACE_BYTES = XperienceCollections.MAX_REGISTER_CANONICAL_WORKSPACE_BYTES
            private const val MAX_OUTPUT_PEAK_BYTES = 96L * 1024 * 1024
            private val MAX_REGISTER_SCAN_WORK_BYTES = OHJson.MAX.toLong() * (REGISTER_MAX_DEPTH + 1L)
            private const val OBJECT_OVERHEAD = 512L
            private const val FIELD_OVERHEAD = 256L
            private const val STRING_TEMP_OVERHEAD = 64L
            private const val STRING_DECODE_OVERHEAD = 64L
            private const val NUMBER_TEMP_OVERHEAD = 32L
            private val TRUE_BYTES = "true".toByteArray(Charsets.US_ASCII)
            private val FALSE_BYTES = "false".toByteArray(Charsets.US_ASCII)
            private val NULL_BYTES = "null".toByteArray(Charsets.US_ASCII)

            private fun literalBytes(value: String): ByteArray = when (value) {
                "true" -> TRUE_BYTES
                "false" -> FALSE_BYTES
                "null" -> NULL_BYTES
                else -> throw Rejected(Failure.INVALID_JSON)
            }
        }
    }

    private const val NUMBER_FORMAT_WORKSPACE_BYTES = 128L * 1024
    private val UINT64_MAX = BigInteger("18446744073709551615")
    private val WS = intArrayOf(9, 10, 13, 32)
}
