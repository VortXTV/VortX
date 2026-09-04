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
        private var declaredDecodedBytes = -1L
        private var decodedBytes = 0L

        fun consumeLine(rawLine: String) {
            consumeLine(rawLine.toByteArray(Charsets.ISO_8859_1), rawLine.length)
        }

        /** Production path: consumes one bounded NNTP wire line without allocating a String. */
        fun consumeLine(line: ByteArray, length: Int, offset: Int = 0) {
            if (startsWith(line, length, offset, "=ybegin") || startsWith(line, length, offset, "=ypart")) {
                inPart = true
                return
            }
            if (startsWith(line, length, offset, "=yend")) {
                inPart = false
                declaredDecodedBytes = parseSize(line, length, offset) ?: declaredDecodedBytes
                return
            }
            if (!inPart) return
            // A body line that begins with "=ybegin"/"=ypart"/"=yend" after the part started is a
            // continuation payload that happens to start with '=' (a decoded '=' output is "="). Only
            // treat the ACTUAL start-of-part headers as control.
            decodeLine(line, length, offset)
        }

        fun finish(): Long {
            if (declaredDecodedBytes >= 0 && declaredDecodedBytes != decodedBytes) {
                throw DecodeException(
                    "yEnc size mismatch: declared=$declaredDecodedBytes decoded=$decodedBytes",
                )
            }
            return decodedBytes
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
        return decoder.finish()
    }

    private fun startsWith(line: ByteArray, length: Int, offset: Int, token: String): Boolean =
        length - offset >= token.length && token.indices.all { line[offset + it] == token[it].code.toByte() }

    private fun parseSize(line: ByteArray, length: Int, offset: Int): Long? {
        val marker = "size=".toByteArray()
        var start = offset
        while (start + marker.size <= length && !marker.indices.all { line[start + it] == marker[it] }) start++
        if (start + marker.size > length) return null
        var value = 0L
        var found = false
        for (index in start + marker.size until length) {
            val byte = line[index].toInt() and 0xff
            if (byte !in '0'.code..'9'.code) break
            found = true
            value = value * 10 + (byte - '0'.code)
        }
        return value.takeIf { found }
    }
}
