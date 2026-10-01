package com.vortx.android.usenet

import java.io.OutputStream

/// A pure yEnc decoder for one NNTP segment body. yEnc is the encoding NNTP binaries are distributed in:
/// each line begins with `=ybegin`, `=ypart`, or `=yend`; payload bytes are offset by 42 (mod 256) and
/// encoded as `=` + two hex digits when the offset byte would collide with `=` (0x3D), CR, LF, or the dot
/// (`=0x2E`). Critical-trace bytes (`=yend size=` etc.) are not decoded; only the payload between `=ypart`
/// and `=yend` contributes. The decoded size is validated against `=yend size=` when present.
///
/// No Android dependency; runs in JVM unit tests.
internal object YencDecoder {

    class DecodeException(message: String) : Exception(message)

    /** Authoritative yEnc range for one decoded NNTP article. ybegin's size is the whole title size. */
    data class DecodedPart(
        val totalBytes: Long,
        val begin: Long,
        val endInclusive: Long,
        val decodedBytes: Long,
    )

    /**
     * Incremental yEnc decoder for one NNTP article. It writes directly to the caller's private segment
     * file and checks the decoded limit before each byte write, so an attacker-controlled article never
     * becomes a String/boxed-byte/ByteArray representation of an entire media segment.
     */
    class StreamingDecoder(
        private val output: OutputStream,
        private val decodedLimit: Long,
    ) {
        var inPart = false
            private set
        private var wholeFileBytes = -1L
        private var partBegin = -1L
        private var partEnd = -1L
        private var declaredDecodedBytes = -1L
        private var sawBegin = false
        private var sawEnd = false
        private var decodedBytes = 0L

        fun consumeLine(rawLine: String) {
            consumeLine(rawLine.toByteArray(Charsets.ISO_8859_1), rawLine.length)
        }

        /** Production path: consumes one bounded NNTP wire line without allocating a String. */
        fun consumeLine(line: ByteArray, length: Int, offset: Int = 0) {
            if (startsWith(line, length, offset, "=ybegin")) {
                if (sawBegin) throw DecodeException("duplicate yEnc begin")
                wholeFileBytes = requiredPositiveHeaderLong(line, length, offset, "size")
                sawBegin = true
                inPart = true
                return
            }
            if (startsWith(line, length, offset, "=ypart")) {
                if (!sawBegin || partBegin >= 0) throw DecodeException("invalid yEnc part header")
                partBegin = requiredPositiveHeaderLong(line, length, offset, "begin")
                partEnd = requiredPositiveHeaderLong(line, length, offset, "end")
                if (partEnd < partBegin) throw DecodeException("invalid yEnc part range")
                inPart = true
                return
            }
            if (startsWith(line, length, offset, "=yend")) {
                if (!sawBegin || sawEnd) throw DecodeException("invalid yEnc end")
                inPart = false
                declaredDecodedBytes = requiredPositiveHeaderLong(line, length, offset, "size", allowZero = true)
                sawEnd = true
                return
            }
            if (!inPart) return
            // A body line that begins with "=ybegin"/"=ypart"/"=yend" after the part started is a
            // continuation payload that happens to start with '=' (a decoded '=' output is "="). Only
            // treat the ACTUAL start-of-part headers as control.
            decodeLine(line, length, offset)
        }

        fun finish(): DecodedPart {
            if (!sawBegin || !sawEnd || wholeFileBytes <= 0 || declaredDecodedBytes < 0) {
                throw DecodeException("incomplete yEnc metadata")
            }
            if (declaredDecodedBytes != decodedBytes) {
                throw DecodeException(
                    "yEnc size mismatch: declared=$declaredDecodedBytes decoded=$decodedBytes",
                )
            }
            val begin = if (partBegin >= 0) partBegin else 1L
            val end = if (partEnd >= 0) partEnd else wholeFileBytes
            if (begin !in 1..wholeFileBytes || end !in begin..wholeFileBytes || end - begin + 1 != decodedBytes) {
                throw DecodeException("yEnc part coverage does not match decoded bytes")
            }
            return DecodedPart(wholeFileBytes, begin, end, decodedBytes)
        }

        private fun decodeLine(line: ByteArray, length: Int, offset: Int) {
            var index = offset
            while (index < length) {
                val char = line[index]
                val decoded = if (char == '='.code.toByte() && index + 1 < length) {
                    index += 2
                    ((line[index - 1].toInt() and 0xff) - 64 - 42) and 0xFF
                } else {
                    index += 1
                    ((char.toInt() and 0xff) - 42) and 0xFF
                }
                if (decodedBytes == decodedLimit) throw DecodeException("yEnc decoded size exceeds limit")
                output.write(decoded)
                decodedBytes += 1
            }
        }
    }

    /** Pure-JVM test seam; production NNTP uses [StreamingDecoder] directly. */
    fun decodeTextTo(segment: String, output: OutputStream, decodedLimit: Long): Long {
        val decoder = StreamingDecoder(output, decodedLimit)
        segment.lineSequence().forEach(decoder::consumeLine)
        return decoder.finish().decodedBytes
    }

    private fun startsWith(line: ByteArray, length: Int, offset: Int, token: String): Boolean =
        length - offset >= token.length && token.indices.all { line[offset + it] == token[it].code.toByte() }

    private fun requiredPositiveHeaderLong(
        line: ByteArray,
        length: Int,
        offset: Int,
        key: String,
        allowZero: Boolean = false,
    ): Long {
        val marker = "$key=".toByteArray()
        var start = offset
        while (start + marker.size <= length && !marker.indices.all { line[start + it] == marker[it] }) start++
        if (start + marker.size > length) throw DecodeException("yEnc $key is missing")
        var value = 0L
        var found = false
        for (index in start + marker.size until length) {
            val byte = line[index].toInt() and 0xff
            if (byte !in '0'.code..'9'.code) break
            found = true
            if (value > (Long.MAX_VALUE - (byte - '0'.code)) / 10) throw DecodeException("yEnc $key overflow")
            value = value * 10 + (byte - '0'.code)
        }
        if (!found || (!allowZero && value <= 0)) throw DecodeException("yEnc $key is invalid")
        return value
    }
}
