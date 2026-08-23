package com.vortx.android.usenet

/// A pure yEnc decoder for one NNTP segment body. yEnc is the encoding NNTP binaries are distributed in:
/// each line begins with `=ybegin`, `=ypart`, or `=yend`; payload bytes are offset by 42 (mod 256) and
/// encoded as `=` + two hex digits when the offset byte would collide with `=` (0x3D), CR, LF, or the dot
/// (`=0x2E`). Critical-trace bytes (`=yend size=` etc.) are not decoded; only the payload between `=ypart`
/// and `=yend` contributes. The decoded size is validated against `=yend size=` when present.
///
/// No Android dependency; runs in JVM unit tests.
internal object YencDecoder {

    class DecodeException(message: String) : Exception(message)

    fun decode(segment: String): ByteArray {
        val lines = segment.split("\n")
        val body = arrayListOf<Byte>()
        var inPart = false
        var declaredDecodedBytes = -1L

        for (rawLine in lines) {
            val line = rawLine.trimEnd('\r')
            if (line.startsWith("=ybegin") || line.startsWith("=ypart")) {
                inPart = true
                continue
            }
            if (line.startsWith("=yend")) {
                inPart = false
                declaredDecodedBytes = parseSize(line) ?: declaredDecodedBytes
                continue
            }
            if (!inPart) continue
            // A body line that begins with "=ybegin"/"=ypart"/"=yend" after the part started is a
            // continuation payload that happens to start with '=' (a decoded '=' output is "="). Only
            // treat the ACTUAL start-of-part headers as control.
            decodeLine(line, body)
        }

        if (declaredDecodedBytes >= 0 && declaredDecodedBytes != body.size.toLong()) {
            throw DecodeException(
                "yEnc size mismatch: declared=$declaredDecodedBytes decoded=${body.size}",
            )
        }
        return body.toByteArray()
    }

    private fun decodeLine(line: String, out: MutableList<Byte>) {
        if (line.isEmpty()) return
        var index = 0
        while (index < line.length) {
            val char = line[index]
            if (char == '=' && index + 1 < line.length) {
                // yEnc escape (per spec): '=' followed by (encodedValue + 64) mod 256 for any encoded value
                // that would collide with NUL / LF / CR / '='. Undo BOTH shifts in one mask step.
                val escaped = line[index + 1]
                out.add(((escaped.code - 64 - 42) and 0xFF).toByte())
                index += 2
            } else {
                out.add(((char.code - 42) and 0xFF).toByte())
                index += 1
            }
        }
    }

    private fun parseSize(line: String): Long? {
        val marker = "size="
        val start = line.indexOf(marker)
        return if (start < 0) null else line.substring(start + marker.length).toLongOrNull()
    }
}