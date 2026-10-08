package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.math.BigDecimal
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest

/** Shared overlay-only v1 framing. Never use ordinary JSON serialization as this digest's input.
 * Raw JSON must pass [parse] BEFORE Android's org.json can round an unsafe original number. */
internal object NativeProfileOverlayWitness {
    private const val LIMIT = 16_777_216
    private val domain = "vortx.profile-overlay/1\u0000".toByteArray(Charsets.US_ASCII)

    fun digest(value: JSONObject): String = digestBytes(encode(value))
    internal fun digestRaw(bytes: ByteArray): String = digestBytes(encode(parse(bytes)))
    private fun digestBytes(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }

    /** Strict, duplicate-rejecting JSON reader retaining original numbers as BigDecimal. It is
     * intentionally independent of the platform/JVM org.json parser's differing numeric behavior.
     * Non-overlay numbers can remain larger; the witness encoder checks its own exact scope. */
    fun parseDocument(bytes: ByteArray): JSONObject = parse(bytes) as? JSONObject ?: error("Account document must be an object")
    /** Actual decrypted native-account ingress. Preflight scoped overlay values while numeric
     * lexemes are still exact; later platform JSONObject copies cannot bless rounded overflow. */
    fun parseAccountDocument(bytes: ByteArray): JSONObject = parseDocument(bytes).also { document ->
        fun member(parent: JSONObject?, key: String): JSONObject? = if (parent == null || !parent.has(key)) null
            else parent.optJSONObject(key) ?: error("Malformed account overlay branch")
        val profiles = member(member(document, "vortx"), "byProfile")
        val removed = member(member(member(document, "webProgress"), "removed"), "byProfile")
        val ids = profiles?.keys()?.asSequence().orEmpty().toSet() + removed?.keys()?.asSequence().orEmpty().toSet()
        ids.forEach { digest(exactOverlay(profiles, removed, it)) }
    }
    /** Borrow the original parsed nodes for immediate validation only. Do NOT call the ordinary
     * source-copy helper: Android JSONObject(String) would round its BigDecimal values first. */
    internal fun exactOverlay(profiles: JSONObject?, removed: JSONObject?, id: String): JSONObject {
        fun member(parent: JSONObject?): Any? {
            if (parent == null) return null
            val matches = parent.keys().asSequence().filter { it.equals(id, true) }.toList()
            require(matches.isEmpty() || matches == listOf(id)) { "Ambiguous overlay identity" }
            return if (parent.has(id)) parent.get(id) else null
        }
        return JSONObject().also { slice ->
            member(profiles)?.let { bucket ->
                require(bucket is JSONObject) { "Malformed account profile overlay" }
                slice.put("vortx", JSONObject().put("byProfile", JSONObject().put(id, bucket)))
            }
            member(removed)?.let { removals ->
                require(removals is JSONArray) { "Malformed account profile removals" }
                slice.put("webProgress", JSONObject().put("removed", JSONObject().put("byProfile", JSONObject().put(id, removals))))
            }
        }
    }
    internal fun parse(bytes: ByteArray): Any {
        require(bytes.size <= LIMIT) { "Overlay JSON exceeds limit" }
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        return Parser(text).read()
    }

    internal fun encode(value: Any?): ByteArray {
        val output = ByteArrayOutputStream()
        var nodes = 0
        fun bytes(bytes: ByteArray) {
            require(output.size().toLong() + bytes.size <= LIMIT) { "Overlay encoding exceeds limit" }
            output.write(bytes)
        }
        fun tag(tag: Char) = bytes(byteArrayOf(tag.code.toByte()))
        fun count(value: Int) = bytes(ByteBuffer.allocate(4).putInt(value).array())
        fun item(value: Any?, depth: Int) {
            require(depth <= 64 && ++nodes <= 100_000) { "Overlay structure exceeds limit" }
            when (value) {
                null, JSONObject.NULL -> tag('n')
                is Boolean -> tag(if (value) 't' else 'f')
                is String -> { val encoded = utf8(value); tag('s'); count(encoded.size); bytes(encoded) }
                is Number -> {
                    val number = exactBinary64(value.toString())
                    require(number.isFinite()) { "Nonfinite overlay number" }
                    tag('d'); bytes(ByteBuffer.allocate(8).putDouble(if (number == 0.0) 0.0 else number).array())
                }
                is JSONArray -> {
                    require(value.length() <= 100_000 - nodes) { "Overlay node limit exceeded" }
                    tag('a'); count(value.length())
                    for (index in 0 until value.length()) item(value.get(index), depth + 1)
                }
                is JSONObject -> {
                    require(value.length() <= (100_000 - nodes) / 2) { "Overlay node limit exceeded" }
                    val entries = value.keys().asSequence().map { it to utf8(it) }.toList().sortedWith { a, b ->
                        var result = 0
                        for (index in 0 until minOf(a.second.size, b.second.size)) {
                            result = (a.second[index].toInt() and 255).compareTo(b.second[index].toInt() and 255)
                            if (result != 0) break
                        }
                        if (result == 0) a.second.size.compareTo(b.second.size) else result
                    }
                    tag('o'); count(entries.size)
                    entries.forEach { (key, _) -> item(key, depth + 1); item(value.get(key), depth + 1) }
                }
                else -> error("Unsupported overlay JSON value")
            }
        }
        bytes(domain); item(value, 0)
        return output.toByteArray()
    }

    private fun utf8(value: String): ByteArray {
        var size = 0L; var index = 0
        while (index < value.length) {
            val char = value[index++]
            size += when {
                char.code < 128 -> 1
                char.code < 2048 -> 2
                char.isHighSurrogate() -> {
                    require(index < value.length && value[index++].isLowSurrogate()) { "Invalid Unicode scalar" }; 4
                }
                char.isLowSurrogate() -> error("Invalid Unicode scalar")
                else -> 3
            }
            require(size <= LIMIT) { "Overlay text exceeds limit" }
        }
        return value.toByteArray(Charsets.UTF_8)
    }

    /** Compare original decimal magnitude without BigDecimal's artificial 32-bit exponent cap.
     * Conversion itself uses the platform's correctly-rounded IEEE754 parser (ties to even). */
    private fun exactBinary64(token: String): Double {
        require(Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?").matches(token)) { "Invalid JSON number" }
        val unsigned = token.removePrefix("-")
        val parts = unsigned.split('e', 'E', limit = 2)
        val mantissa = parts[0]; val digits = mantissa.replace(".", "")
        val first = digits.indexOfFirst { it != '0' }
        if (first < 0) return 0.0
        val exponentText = parts.getOrNull(1).orEmpty()
        val exponentDigits = exponentText.removePrefix("-").removePrefix("+").trimStart('0')
        val negativeExponent = exponentText.startsWith('-')
        val exponent = if (exponentDigits.length > 10) {
            require(negativeExponent) { "Unsafe overlay number" }; return 0.0
        } else (exponentDigits.toLongOrNull() ?: 0L) * if (negativeExponent) -1L else 1L
        val order = exponent + (mantissa.indexOf('.').takeIf { it >= 0 } ?: mantissa.length) - first - 1L
        require(order <= 15) { "Unsafe overlay number" }
        if (order == 15L) {
            val significant = digits.substring(first)
            val integer = significant.take(16).padEnd(16, '0')
            require(integer < "9007199254740991" || integer == "9007199254740991" && significant.drop(16).all { it == '0' }) {
                "Unsafe overlay number"
            }
        }
        return if (order < -324) 0.0 else token.toDouble()
    }

    private class ExactNumber(private val token: String) : Number() {
        override fun toByte() = toDouble().toInt().toByte()
        override fun toShort() = toDouble().toInt().toShort()
        override fun toInt() = toDouble().toInt()
        override fun toLong() = toDouble().toLong()
        override fun toFloat() = token.toFloat()
        override fun toDouble() = token.toDouble()
        override fun toString() = token
    }

    private class Parser(private val text: String) {
        private var position = 0
        private var nodes = 0
        fun read(): Any {
            val value = value(0); whitespace()
            require(position == text.length) { "Trailing overlay JSON" }
            return value
        }
        private fun whitespace() { while (position < text.length && text[position] in " \t\r\n") position++ }
        private fun take(expected: Char) {
            whitespace(); require(position < text.length && text[position++] == expected) { "Malformed overlay JSON" }
        }
        private fun value(depth: Int): Any {
            require(depth <= 64 && ++nodes <= 100_000) { "Overlay JSON structure exceeds limit" }
            whitespace(); require(position < text.length) { "Missing overlay JSON value" }
            return when (text[position]) {
                '{' -> {
                    position++; whitespace(); val result = JSONObject(); val names = hashSetOf<String>()
                    if (position < text.length && text[position] == '}') { position++; result }
                    else {
                        while (true) {
                            require(++nodes <= 100_000 && depth + 1 <= 64)
                            whitespace(); val key = string(); require(names.add(key)) { "Duplicate overlay JSON key" }
                            take(':'); result.put(key, value(depth + 1)); whitespace()
                            if (position < text.length && text[position] == '}') { position++; break }
                            take(',')
                        }; result
                    }
                }
                '[' -> {
                    position++; whitespace(); val result = JSONArray()
                    if (position < text.length && text[position] == ']') { position++; result }
                    else {
                        while (true) {
                            result.put(value(depth + 1)); whitespace()
                            if (position < text.length && text[position] == ']') { position++; break }
                            take(',')
                        }; result
                    }
                }
                '"' -> string()
                't' -> keyword("true", true)
                'f' -> keyword("false", false)
                'n' -> keyword("null", JSONObject.NULL)
                '-', in '0'..'9' -> number()
                else -> error("Invalid overlay JSON token")
            }
        }
        private fun keyword(word: String, result: Any): Any {
            require(text.startsWith(word, position)) { "Invalid overlay JSON token" }; position += word.length; return result
        }
        private fun number(): Number {
            val start = position
            if (text[position] == '-') position++
            require(position < text.length)
            if (text[position] == '0') position++ else {
                require(text[position] in '1'..'9')
                while (position < text.length && text[position] in '0'..'9') position++
            }
            if (position < text.length && text[position] == '.') {
                position++; val first = position
                while (position < text.length && text[position] in '0'..'9') position++
                require(position > first)
            }
            if (position < text.length && text[position] in "eE") {
                position++; if (position < text.length && text[position] in "+-") position++
                val first = position
                while (position < text.length && text[position] in '0'..'9') position++
                require(position > first)
            }
            val token = text.substring(start, position)
            return runCatching { BigDecimal(token) }.getOrElse { ExactNumber(token) }
        }
        private fun string(): String {
            require(position < text.length && text[position++] == '"') { "Expected JSON string" }
            val result = StringBuilder()
            while (position < text.length) {
                val char = text[position++]
                if (char == '"') return result.toString().also { utf8(it) }
                require(char >= ' ') { "Unescaped JSON control character" }
                if (char != '\\') result.append(char) else {
                    require(position < text.length)
                    when (val escape = text[position++]) {
                        '"', '\\', '/' -> result.append(escape)
                        'b' -> result.append('\b')
                        'f' -> result.append('\u000c')
                        'n' -> result.append('\n')
                        'r' -> result.append('\r')
                        't' -> result.append('\t')
                        'u' -> {
                            require(position + 4 <= text.length)
                            val hex = text.substring(position, position + 4)
                            require(hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' })
                            result.append(hex.toInt(16).toChar()); position += 4
                        }
                        else -> error("Invalid JSON escape")
                    }
                }
            }
            error("Unterminated JSON string")
        }
    }
}
