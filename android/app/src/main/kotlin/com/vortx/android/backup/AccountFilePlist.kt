package com.vortx.android.backup

import java.io.StringReader
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.text.Normalizer
import java.time.Instant
import java.util.Base64
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.helpers.DefaultHandler

/** Full, interpretation-only plist admission for account files. Never filters or serializes
 * defaults. Caller retains the ORIGINAL settings slice. Ordinary SettingsBackup remains unchanged.
 * Limits apply during traversal (including repeated references), before expansion/allocation. */
internal object AccountFilePlist {
    const val MAX_BYTES = 5 * 1024 * 1024
    private const val MAX_NODES = 100_000
    private const val MAX_EXPANDED_BYTES = 16 * 1024 * 1024
    private const val MAX_DEPTH = 64
    data class PlistDate(val secondsSince2001: Double)

    fun decode(bytes: ByteArray): Map<String, Any> {
        require(bytes.size <= MAX_BYTES) { "Account plist exceeds limit" }
        val value = if (bytes.size >= 8 && bytes.copyOfRange(0, 8).contentEquals("bplist00".toByteArray()))
            Binary(bytes).root() else xml(bytes)
        require(value is Map<*, *> && value.keys.all { it is String }) { "Account plist must be a dictionary" }
        @Suppress("UNCHECKED_CAST") return value as Map<String, Any>
    }

    private class Budget {
        private var nodes = 0
        private var expanded = 0L
        fun node(depth: Int) { require(depth <= MAX_DEPTH && ++nodes <= MAX_NODES) { "Account plist structure exceeds limit" } }
        fun elements(count: Int) { require(count >= 0 && count <= MAX_NODES - nodes) { "Account plist structure exceeds limit" } }
        fun bytes(count: Int) {
            require(count >= 0); expanded += count
            require(expanded <= MAX_EXPANDED_BYTES) { "Account plist expansion exceeds limit" }
        }
    }
    private fun unique(keys: MutableSet<String>, key: String) {
        require(keys.add(Normalizer.normalize(key, Normalizer.Form.NFC))) { "Duplicate account plist key" }
    }
    private fun text(bytes: ByteArray, charset: java.nio.charset.Charset): String = charset.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()

    private class Binary(private val bytes: ByteArray) {
        private val budget = Budget()
        private val visiting = hashSetOf<Int>()
        private var offsets = 0
        private var offsetWidth = 0
        private var referenceWidth = 0
        private var objects = 0
        private var bodyEnd = 0
        private fun span(at: Int, count: Int, end: Int = bodyEnd) {
            require(at >= 8 && count >= 0 && at.toLong() + count <= end.toLong()) { "Malformed account plist span" }
        }
        private fun unsigned(at: Int, width: Int, end: Int = bodyEnd): Long {
            require(width in 1..8); span(at, width, end)
            var result = 0L
            repeat(width) { result = (result shl 8) or (bytes[at + it].toLong() and 255) }
            require(result >= 0) { "Account plist index overflow" }; return result
        }
        private fun index(at: Int, width: Int, end: Int = bodyEnd): Int {
            val value = unsigned(at, width, end); require(value <= Int.MAX_VALUE); return value.toInt()
        }
        fun root(): Any {
            require(bytes.size >= 40)
            val trailer = bytes.size - 32
            offsetWidth = bytes[trailer + 6].toInt() and 255
            referenceWidth = bytes[trailer + 7].toInt() and 255
            require(offsetWidth in 1..8 && referenceWidth in 1..8)
            objects = index(trailer + 8, 8, bytes.size)
            val top = index(trailer + 16, 8, bytes.size)
            offsets = index(trailer + 24, 8, bytes.size); bodyEnd = offsets
            require(objects in 1..MAX_NODES && top in 0 until objects && offsets >= 8)
            require(offsets.toLong() + objects.toLong() * offsetWidth <= trailer.toLong())
            return objectAt(top, 0)
        }
        private fun objectAt(id: Int, depth: Int): Any {
            budget.node(depth)
            require(id in 0 until objects && visiting.add(id)) { "Cyclic or invalid account plist reference" }
            try {
                val position = index(offsets + id * offsetWidth, offsetWidth, bytes.size - 32)
                span(position, 1)
                val marker = bytes[position].toInt() and 255
                val kind = marker ushr 4; val nibble = marker and 15
                fun count(): Pair<Int, Int> {
                    if (nibble < 15) return nibble to position + 1
                    span(position + 1, 1)
                    val sizeMarker = bytes[position + 1].toInt() and 255
                    require((sizeMarker ushr 4) == 1 && (sizeMarker and 15) <= 3)
                    val width = 1 shl (sizeMarker and 15)
                    return index(position + 2, width) to position + 2 + width
                }
                return when (kind) {
                    0 -> when (marker) { 8 -> false; 9 -> true; else -> error("Unsupported account plist primitive") }
                    1 -> {
                        require(nibble <= 4); val width = 1 shl nibble; span(position + 1, width)
                        val raw = bytes.copyOfRange(position + 1, position + 1 + width)
                        // CoreFoundation's narrow integers are unsigned; 8/16-byte values are signed.
                        if (width < 8) BigInteger(1, raw) else BigInteger(raw)
                    }
                    2, 3 -> {
                        val width = 1 shl nibble
                        require(if (kind == 3) marker == 0x33 else width == 4 || width == 8)
                        span(position + 1, width)
                        val buffer = ByteBuffer.wrap(bytes, position + 1, width)
                        val number = if (width == 4) buffer.float.toDouble() else buffer.double
                        if (kind == 3) { require(number.isFinite()); PlistDate(number) } else number
                    }
                    4, 5, 6 -> {
                        val (length, start) = count()
                        val byteCount = length.toLong() * if (kind == 6) 2 else 1
                        require(byteCount <= MAX_BYTES); span(start, byteCount.toInt()); budget.bytes(byteCount.toInt())
                        val raw = bytes.copyOfRange(start, start + byteCount.toInt())
                        when (kind) { 4 -> raw; 5 -> text(raw, Charsets.US_ASCII); else -> text(raw, Charsets.UTF_16BE) }
                    }
                    10, 13 -> {
                        val (length, start) = count(); val references = length.toLong() * if (kind == 13) 2 else 1
                        require(references <= MAX_NODES); budget.elements(references.toInt())
                        val byteCount = references * referenceWidth; require(byteCount <= MAX_BYTES); span(start, byteCount.toInt())
                        if (kind == 10) List(length) { objectAt(index(start + it * referenceWidth, referenceWidth), depth + 1) }
                        else {
                            val result = linkedMapOf<String, Any>(); val names = hashSetOf<String>()
                            repeat(length) { i ->
                                val key = objectAt(index(start + i * referenceWidth, referenceWidth), depth + 1)
                                require(key is String) { "Non-string account plist key" }; unique(names, key)
                                result[key] = objectAt(index(start + (length + i) * referenceWidth, referenceWidth), depth + 1)
                            }; result
                        }
                    }
                    else -> error("Unsupported account plist object")
                }
            } finally { visiting.remove(id) }
        }
    }

    private fun xml(bytes: ByteArray): Any {
        val charset = when {
            bytes.size >= 2 && (bytes[0].toInt() and 255) == 0xff && (bytes[1].toInt() and 255) == 0xfe -> Charsets.UTF_16
            bytes.size >= 2 && (bytes[0].toInt() and 255) == 0xfe && (bytes[1].toInt() and 255) == 0xff -> Charsets.UTF_16
            bytes.size >= 2 && bytes[0] == 0.toByte() && bytes[1] == '<'.code.toByte() -> Charsets.UTF_16BE
            bytes.size >= 2 && bytes[0] == '<'.code.toByte() && bytes[1] == 0.toByte() -> Charsets.UTF_16LE
            else -> Charsets.UTF_8
        }
        var source = text(bytes, charset).removePrefix("\uFEFF")
        // Accept the standard Apple declaration without ever resolving its external DTD.
        // No internal subset, custom DTD or entity declaration enters the XML parser.
        val appleDTD = Regex("<!DOCTYPE\\s+plist\\s+PUBLIC\\s+([\"'])-//Apple//DTD PLIST 1\\.0//EN\\1\\s+([\"'])https?://www\\.apple\\.com/DTDs/PropertyList-1\\.0\\.dtd\\2\\s*>")
        var cursor = 0; var copied = 0; var declarations = 0; var seenElement = false
        val withoutDTD = StringBuilder()
        while (true) {
            val start = source.indexOf('<', cursor); if (start < 0) break
            val endToken = when {
                source.startsWith("<!--", start) -> "-->"
                source.startsWith("<![CDATA[", start) -> "]]>"
                source.startsWith("<?", start) -> "?>"
                else -> null
            }
            if (endToken != null) {
                val end = source.indexOf(endToken, start + 2); require(end >= 0)
                cursor = end + endToken.length; continue
            }
            if (source.startsWith("<!DOCTYPE", start, ignoreCase = true)) {
                val declaration = appleDTD.find(source, start)
                require(!seenElement && declaration != null && declaration.range.first == start && ++declarations == 1) { "Unsupported account plist declaration" }
                withoutDTD.append(source, copied, start)
                cursor = declaration.range.last + 1; copied = cursor
            } else {
                require(!source.startsWith("<!ENTITY", start, ignoreCase = true)) { "Unsupported account plist declaration" }
                seenElement = true; cursor = start + 1
            }
        }
        source = withoutDTD.append(source, copied, source.length).toString()
        val handler = XMLHandler()
        val reader = SAXParserFactory.newInstance().apply { isNamespaceAware = false; isValidating = false }.newSAXParser().xmlReader
        // Android/JVM SAX implementations differ on optional feature names. Security does not
        // depend on them: no DTD/entity declaration reaches this reader, and resolution throws.
        for (feature in listOf("http://xml.org/sax/features/external-general-entities", "http://xml.org/sax/features/external-parameter-entities")) {
            try { reader.setFeature(feature, false) }
            catch (_: org.xml.sax.SAXNotRecognizedException) { /* Structural declaration guard remains mandatory. */ }
            catch (_: org.xml.sax.SAXNotSupportedException) { /* Structural declaration guard remains mandatory. */ }
        }
        reader.entityResolver = org.xml.sax.EntityResolver { _, _ -> throw SAXException("External account plist entity refused") }
        reader.contentHandler = handler; reader.errorHandler = handler
        reader.parse(InputSource(StringReader(source)))
        return requireNotNull(handler.result) { "Missing account plist root" }
    }

    private class XMLHandler : DefaultHandler() {
        private class Frame(val tag: String) {
            val text = StringBuilder(); val children = arrayListOf<Pair<String, Any>>()
        }
        private val budget = Budget()
        private val stack = arrayListOf<Frame>()
        var result: Any? = null; private set
        override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
            budget.node(stack.size)
            require(qName in setOf("plist", "dict", "array", "key", "string", "data", "integer", "real", "date", "true", "false"))
            if (stack.isEmpty()) require(qName == "plist" && result == null) else require(qName != "plist")
            require(if (qName == "plist") attributes.length == 0 || attributes.length == 1 && attributes.getValue("version") == "1.0" else attributes.length == 0)
            stack.add(Frame(qName))
        }
        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (stack.isEmpty()) { require(String(ch, start, length).isBlank()); return }
            budget.bytes(length * 2); stack.last().text.append(ch, start, length)
        }
        override fun endElement(uri: String?, localName: String?, qName: String) {
            val frame = stack.removeAt(stack.lastIndex); require(frame.tag == qName)
            val value: Any = when (qName) {
                "plist" -> { require(frame.text.isBlank() && frame.children.size == 1 && frame.children[0].first != "key"); frame.children[0].second }
                "dict" -> {
                    require(frame.text.isBlank() && frame.children.size % 2 == 0)
                    val result = linkedMapOf<String, Any>(); val names = hashSetOf<String>()
                    frame.children.chunked(2).forEach { pair ->
                        require(pair[0].first == "key" && pair[1].first != "key")
                        val key = pair[0].second as String; unique(names, key); result[key] = pair[1].second
                    }; result
                }
                "array" -> { require(frame.text.isBlank() && frame.children.none { it.first == "key" }); frame.children.map { it.second } }
                else -> {
                    require(frame.children.isEmpty())
                    val string = frame.text.toString()
                    when (qName) {
                        "key", "string" -> string
                        "true", "false" -> { require(string.isBlank()); qName == "true" }
                        "data" -> Base64.getDecoder().decode(string.filterNot { it in " \r\n\t" }).also { require(it.size <= MAX_BYTES) }
                        "integer" -> {
                            val scalar = string.trim(); require(scalar.length <= 128)
                            if (Regex("[+-]?0[xX][0-9a-fA-F]+").matches(scalar)) {
                                val unsigned = scalar.removePrefix("+").removePrefix("-").drop(2)
                                BigInteger(unsigned, 16).let { if (scalar.startsWith('-')) it.negate() else it }
                            } else { require(Regex("[+-]?[0-9]+").matches(scalar)); BigInteger(scalar) }
                        }
                        "real" -> when (val scalar = string.trim().lowercase()) {
                            "nan" -> Double.NaN; "+infinity", "infinity", "+inf", "inf" -> Double.POSITIVE_INFINITY
                            "-infinity", "-inf" -> Double.NEGATIVE_INFINITY
                            else -> scalar.toDouble()
                        }
                        "date" -> Instant.parse(string.trim()).let { PlistDate(it.epochSecond - 978_307_200.0 + it.nano / 1e9) }
                        else -> error("Unsupported account plist value")
                    }
                }
            }
            if (stack.isEmpty()) result = value else stack.last().children.add(qName to value)
        }
        override fun processingInstruction(target: String?, data: String?) { throw SAXException("Unsupported account plist instruction") }
        override fun skippedEntity(name: String?) { throw SAXException("Unresolved account plist entity") }
        override fun error(error: org.xml.sax.SAXParseException) { throw error }
        override fun fatalError(error: org.xml.sax.SAXParseException) { throw error }
    }
}
