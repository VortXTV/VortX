package com.vortx.android.backup

import java.util.Date

/**
 * A minimal, fail-closed `bplist00` (Apple binary property list) codec.
 *
 * WHY THIS EXISTS: Apple's [SettingsBackup] envelope carries its payload as a binary plist, because that
 * format natively round-trips every `UserDefaults` value type (Bool, Int, Double, String, Data, Date,
 * arrays, dictionaries) that raw JSON cannot. See `app/SourcesShared/SettingsBackup.swift:93-96`. The
 * `doc.settings` blob is therefore NOT JSON, and Android cannot read or write the account's roster
 * without speaking this format. The JVM has no plist support, so this is the port of that dependency.
 *
 * FAIL-CLOSED IS THE WHOLE SAFETY MODEL. Every entry point returns null rather than throwing or guessing:
 *   - [decode] returns null on a malformed or unsupported plist.
 *   - [encode] returns null when the graph holds a type this codec cannot represent exactly.
 * A null tells the caller "I could not round-trip this", and [SettingsBackup.settingsBlobFor] then leaves
 * the account's existing blob untouched. That matters because Apple's `SettingsBackup.restore` writes
 * every key of the blob straight into `UserDefaults`
 * (`app/SourcesShared/SettingsBackup.swift:147-153`): a blob we built from a partial read would silently
 * drop the Apple keys we failed to parse, wiping settings on every Apple device on the account. Losing
 * one push is recoverable; corrupting the account's settings is not.
 *
 * TYPE MAPPING (plist to Kotlin, exact and lossless in both directions):
 *   bool -> Boolean | int -> Long | real -> Double | string -> String
 *   data -> ByteArray | date -> java.util.Date | array -> List<Any> | dict -> Map<String, Any>
 *
 * The `null` / `fill` plist markers and `set` / `uid` objects are deliberately unsupported: `UserDefaults`
 * cannot hold them, so meeting one means we misparsed and must fail rather than invent a value.
 *
 * FORMAT REFERENCE (CoreFoundation CFBinaryPList.c): an 8-byte "bplist00" header, a packed object table,
 * an offset table with one entry per object, and a fixed 32-byte trailer holding the offset/ref integer
 * widths, the object count, the root object's index, and where the offset table starts.
 */
internal object BinaryPlist {

    private val HEADER = "bplist00".toByteArray(Charsets.US_ASCII)
    private const val TRAILER_SIZE = 32

    /** Seconds between the Unix epoch and the plist epoch (2001-01-01 00:00:00 UTC). */
    private const val PLIST_EPOCH_OFFSET_SECONDS = 978_307_200L

    // ---------------------------------------------------------------- decode

    /**
     * Parse a binary plist into the Kotlin type map documented above, or null when the bytes are not a
     * plist we can represent exactly. Never throws: a corrupt blob is an expected input (it arrives over
     * the network), not a programming error.
     */
    fun decode(bytes: ByteArray): Any? = runCatching { Reader(bytes).parseRoot() }.getOrNull()

    private class Reader(private val buf: ByteArray) {
        private var offsetIntSize = 0
        private var objectRefSize = 0
        private var numObjects = 0
        private var topObject = 0
        private var offsetTableOffset = 0
        /** Guards against a maliciously or accidentally cyclic ref graph (a plist tree cannot be cyclic). */
        private val visiting = HashSet<Int>()

        fun parseRoot(): Any? {
            if (buf.size < HEADER.size + TRAILER_SIZE) return null
            for (i in HEADER.indices) if (buf[i] != HEADER[i]) return null

            val t = buf.size - TRAILER_SIZE
            offsetIntSize = buf[t + 6].toInt() and 0xFF
            objectRefSize = buf[t + 7].toInt() and 0xFF
            numObjects = readBE(t + 8, 8).toInt()
            topObject = readBE(t + 16, 8).toInt()
            offsetTableOffset = readBE(t + 24, 8).toInt()

            if (offsetIntSize !in 1..8 || objectRefSize !in 1..8) return null
            if (numObjects <= 0 || topObject !in 0 until numObjects) return null
            if (offsetTableOffset < HEADER.size) return null
            if (offsetTableOffset.toLong() + numObjects.toLong() * offsetIntSize > t.toLong()) return null

            return parseObject(topObject)
        }

        private fun offsetOf(index: Int): Int =
            readBE(offsetTableOffset + index * offsetIntSize, offsetIntSize).toInt()

        /** Big-endian unsigned read of [size] bytes. 8-byte reads are returned as-is (signed Long). */
        private fun readBE(at: Int, size: Int): Long {
            if (at < 0 || at + size > buf.size) throw IndexOutOfBoundsException("plist read past end")
            var v = 0L
            for (i in 0 until size) v = (v shl 8) or (buf[at + i].toLong() and 0xFF)
            return v
        }

        private fun parseObject(index: Int): Any {
            if (index !in 0 until numObjects) throw IllegalStateException("objref out of range")
            if (!visiting.add(index)) throw IllegalStateException("cyclic plist")
            try {
                return parseAt(offsetOf(index))
            } finally {
                visiting.remove(index)
            }
        }

        private fun parseAt(pos: Int): Any {
            val marker = buf[pos].toInt() and 0xFF
            val type = marker and 0xF0
            val nibble = marker and 0x0F
            return when (type) {
                0x00 -> when (marker) {
                    0x08 -> false
                    0x09 -> true
                    // 0x00 null and 0x0F fill cannot come out of UserDefaults; refuse to guess.
                    else -> throw IllegalStateException("unsupported primitive marker $marker")
                }
                // Ints are 1 << nibble bytes. 1/2/4-byte ints are UNSIGNED; 8-byte is signed two's
                // complement. CoreFoundation emits 16-byte ONLY for values >= 2^63, which do not fit a
                // signed Long: accepting the low half would wrap them negative, and a republish would then
                // rewrite that foreign key with the wrong value. Anything a Long cannot hold exactly
                // fails closed instead (decode returns null, the account's blob stays untouched).
                0x10 -> when (val len = 1 shl nibble) {
                    1, 2, 4 -> readBE(pos + 1, len)
                    8 -> readBE(pos + 1, 8)
                    16 -> {
                        val hi = readBE(pos + 1, 8)
                        val lo = readBE(pos + 9, 8)
                        if (hi != 0L || lo < 0) throw IllegalStateException("16-byte int exceeds Long")
                        lo
                    }
                    else -> throw IllegalStateException("bad int width $len")
                }
                0x20 -> when (val len = 1 shl nibble) {
                    4 -> Float.fromBits(readBE(pos + 1, 4).toInt()).toDouble()
                    8 -> Double.fromBits(readBE(pos + 1, 8))
                    else -> throw IllegalStateException("bad real width $len")
                }
                0x30 -> {
                    // Seconds since 2001-01-01 as a big-endian double.
                    val secs = Double.fromBits(readBE(pos + 1, 8))
                    Date(Math.round((secs + PLIST_EPOCH_OFFSET_SECONDS) * 1000.0))
                }
                0x40 -> {
                    val (count, start) = countAndStart(pos, nibble)
                    if (start + count > buf.size) throw IndexOutOfBoundsException("data past end")
                    buf.copyOfRange(start, start + count)
                }
                0x50 -> {
                    val (count, start) = countAndStart(pos, nibble)
                    if (start + count > buf.size) throw IndexOutOfBoundsException("ascii past end")
                    String(buf, start, count, Charsets.US_ASCII)
                }
                0x60 -> {
                    // The count is UTF-16 CODE UNITS, so the byte length is twice that.
                    val (count, start) = countAndStart(pos, nibble)
                    val byteLen = count * 2
                    if (start + byteLen > buf.size) throw IndexOutOfBoundsException("utf16 past end")
                    String(buf, start, byteLen, Charsets.UTF_16BE)
                }
                0xA0 -> {
                    val (count, start) = countAndStart(pos, nibble)
                    (0 until count).map { parseObject(readBE(start + it * objectRefSize, objectRefSize).toInt()) }
                }
                0xD0 -> {
                    val (count, start) = countAndStart(pos, nibble)
                    val valuesStart = start + count * objectRefSize
                    val out = LinkedHashMap<String, Any>(count)
                    for (i in 0 until count) {
                        val key = parseObject(readBE(start + i * objectRefSize, objectRefSize).toInt())
                        if (key !is String) throw IllegalStateException("non-string plist dict key")
                        out[key] = parseObject(readBE(valuesStart + i * objectRefSize, objectRefSize).toInt())
                    }
                    out
                }
                // 0x80 uid and 0xC0 set cannot come out of UserDefaults.
                else -> throw IllegalStateException("unsupported plist type 0x${type.toString(16)}")
            }
        }

        /**
         * Resolve a marker's element count and the offset its body starts at. A nibble of 0xF means the
         * count did not fit, and an int object follows the marker inline carrying the real count.
         */
        private fun countAndStart(pos: Int, nibble: Int): Pair<Int, Int> {
            if (nibble != 0x0F) return nibble to (pos + 1)
            val intMarker = buf[pos + 1].toInt() and 0xFF
            if (intMarker and 0xF0 != 0x10) throw IllegalStateException("bad extended count marker")
            val len = 1 shl (intMarker and 0x0F)
            val count = readBE(pos + 2, len)
            if (count < 0 || count > Int.MAX_VALUE) throw IllegalStateException("extended count too large")
            return count.toInt() to (pos + 2 + len)
        }
    }

    // ---------------------------------------------------------------- encode

    /**
     * Serialize [root] to a binary plist, or null when the graph holds a type this codec cannot represent
     * exactly. The output is not byte-identical to CoreFoundation's (no object deduplication), but it is a
     * valid `bplist00` that CoreFoundation parses to an equal graph, which is the contract that matters:
     * Apple reads it back through `PropertyListSerialization.propertyList(from:)`.
     */
    fun encode(root: Any): ByteArray? = runCatching { Writer().serialize(root) }.getOrNull()

    /** A flattened object-table entry whose child object ids are already resolved. */
    private sealed interface Node {
        data class Leaf(val value: Any) : Node
        data class Arr(val items: List<Int>) : Node
        data class Dict(val keys: List<Int>, val values: List<Int>) : Node
    }

    private class Writer {
        private val nodes = ArrayList<Node?>()

        fun serialize(root: Any): ByteArray? {
            flatten(root)
            val objectRefSize = widthFor((nodes.size - 1).toLong().coerceAtLeast(0))

            val body = java.io.ByteArrayOutputStream()
            body.write(HEADER)
            val offsets = IntArray(nodes.size)
            for (i in nodes.indices) {
                offsets[i] = body.size()
                writeNode(body, nodes[i] ?: return null, objectRefSize)
            }

            val offsetTableOffset = body.size()
            val offsetIntSize = widthFor(offsetTableOffset.toLong())
            for (o in offsets) writeBE(body, o.toLong(), offsetIntSize)

            // Trailer: 5 unused + sortVersion + offsetIntSize + objectRefSize + 3 x uint64.
            repeat(5) { body.write(0) }
            body.write(0)                       // sortVersion
            body.write(offsetIntSize)
            body.write(objectRefSize)
            writeBE(body, nodes.size.toLong(), 8)
            writeBE(body, 0L, 8)                // root is always object 0
            writeBE(body, offsetTableOffset.toLong(), 8)
            return body.toByteArray()
        }

        /**
         * Depth-first flatten into the object table, reserving each container's slot BEFORE recursing so
         * the root lands at index 0 (where the trailer's topObject points). Dict keys are emitted in
         * sorted order purely for deterministic output; the format does not require it.
         */
        private fun flatten(o: Any): Int {
            val index = nodes.size
            nodes.add(null)
            nodes[index] = when (o) {
                is Boolean, is String, is ByteArray, is Date, is Double, is Float,
                is Long, is Int, is Short, is Byte -> Node.Leaf(o)
                is List<*> -> Node.Arr(o.map { flatten(it ?: unsupported("null in array")) })
                is Map<*, *> -> {
                    val entries = o.entries
                        .map { (k, v) -> (k as? String ?: unsupported("non-string dict key")) to (v ?: unsupported("null value")) }
                        .sortedBy { it.first }
                    // Keys first, then values: both ref blocks must exist before either is written out.
                    Node.Dict(entries.map { flatten(it.first) }, entries.map { flatten(it.second) })
                }
                else -> unsupported("type ${o.javaClass.name}")
            }
            return index
        }

        private fun unsupported(what: String): Nothing = throw IllegalArgumentException("plist cannot encode $what")

        private fun writeNode(out: java.io.ByteArrayOutputStream, node: Node, refSize: Int) {
            when (node) {
                is Node.Leaf -> writeLeaf(out, node.value)
                is Node.Arr -> {
                    writeMarkerAndCount(out, 0xA0, node.items.size)
                    for (r in node.items) writeBE(out, r.toLong(), refSize)
                }
                is Node.Dict -> {
                    writeMarkerAndCount(out, 0xD0, node.keys.size)
                    for (r in node.keys) writeBE(out, r.toLong(), refSize)
                    for (r in node.values) writeBE(out, r.toLong(), refSize)
                }
            }
        }

        private fun writeLeaf(out: java.io.ByteArrayOutputStream, v: Any) {
            when (v) {
                is Boolean -> out.write(if (v) 0x09 else 0x08)
                is Long -> writeInt(out, v)
                is Int -> writeInt(out, v.toLong())
                is Short -> writeInt(out, v.toLong())
                is Byte -> writeInt(out, v.toLong())
                is Double -> { out.write(0x23); writeBE(out, v.toRawBits(), 8) }
                is Float -> { out.write(0x23); writeBE(out, v.toDouble().toRawBits(), 8) }
                is Date -> {
                    out.write(0x33)
                    val secs = v.time / 1000.0 - PLIST_EPOCH_OFFSET_SECONDS
                    writeBE(out, secs.toRawBits(), 8)
                }
                is ByteArray -> { writeMarkerAndCount(out, 0x40, v.size); out.write(v) }
                is String -> writeString(out, v)
                else -> unsupported("leaf ${v.javaClass.name}")
            }
        }

        /**
         * ASCII when every character fits in 7 bits, else UTF-16BE. The count in the marker is the number
         * of UTF-16 CODE UNITS, which is exactly Kotlin's String.length, so a surrogate pair (an emoji
         * avatar, for instance) counts as 2 and the byte length is twice the count.
         */
        private fun writeString(out: java.io.ByteArrayOutputStream, s: String) {
            val ascii = s.all { it.code < 0x80 }
            if (ascii) {
                writeMarkerAndCount(out, 0x50, s.length)
                out.write(s.toByteArray(Charsets.US_ASCII))
            } else {
                writeMarkerAndCount(out, 0x60, s.length)
                out.write(s.toByteArray(Charsets.UTF_16BE))
            }
        }

        /**
         * Match CoreFoundation's integer widths: 1/2/4-byte ints are unsigned, so a value that fits
         * unsigned uses the narrow form, and anything negative or above 32 bits takes the signed 8-byte
         * form. Writing a negative value narrow would read back as a huge positive.
         */
        private fun writeInt(out: java.io.ByteArrayOutputStream, v: Long) {
            when {
                v in 0..0xFF -> { out.write(0x10); writeBE(out, v, 1) }
                v in 0..0xFFFF -> { out.write(0x11); writeBE(out, v, 2) }
                v in 0..0xFFFFFFFFL -> { out.write(0x12); writeBE(out, v, 4) }
                else -> { out.write(0x13); writeBE(out, v, 8) }
            }
        }

        private fun writeMarkerAndCount(out: java.io.ByteArrayOutputStream, type: Int, count: Int) {
            if (count < 0x0F) {
                out.write(type or count)
            } else {
                out.write(type or 0x0F)
                writeInt(out, count.toLong())
            }
        }

        private fun writeBE(out: java.io.ByteArrayOutputStream, v: Long, size: Int) {
            for (i in size - 1 downTo 0) out.write(((v ushr (i * 8)) and 0xFF).toInt())
        }

        /** The narrowest byte width that holds [max] as an unsigned value (plist widths are 1/2/4/8). */
        private fun widthFor(max: Long): Int = when {
            max <= 0xFF -> 1
            max <= 0xFFFF -> 2
            max <= 0xFFFFFFFFL -> 4
            else -> 8
        }
    }
}
