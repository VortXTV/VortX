package com.vortx.android.player.subtitles

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Collections

/**
 * Strict admission framing for the optional owned ordinary-SRT path. Media3 remains the only
 * styled-text parser. This rejects input its permissive SubripParser could silently skip, allowing
 * the caller to retain the existing ordinary sidecar fallback instead of adopting a partial file.
 */
internal object Media3OwnedSubtitleSrtEnvelope {
    const val maximumBytes = 1024 * 1024
    data class Timing(val startMs: Long, val endMs: Long)

    // Same supported timestamp shape as pinned Media3 1.11.1, with our finite range checks below.
    private val time = "(?:(\\d+):)?(\\d+):(\\d+)(?:,(\\d{3}))?"
    private val timingLine = Regex("\\s*$time\\s*-->\\s*$time\\s*")

    /** Caller must supply bytes from a completed owned download, after transport EOF. */
    fun inspect(bytes: ByteArray): List<Timing>? {
        if (bytes.size !in 1..maximumBytes) return null
        val decoded = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) { return null }
        if ('\u0000' in decoded) return null
        val lines = Lines(decoded.removePrefix("\ufeff"))
        val result = ArrayList<Timing>()
        var previousStart = -1L
        while (true) {
            var indexLine = lines.next() ?: break
            while (indexLine.isEmpty()) indexLine = lines.next() ?: return complete(result)
            if (indexLine.toIntOrNull() == null || result.size == SubtitleReferencePresentationCore.maximumCues) return null
            val match = timingLine.matchEntire(lines.next() ?: return null) ?: return null
            val start = timestamp(match, 1) ?: return null
            val end = timestamp(match, 5) ?: return null
            if (start < previousStart || start >= end) return null
            // Keep source text bounded without interpreting or stripping any authored markup.
            val body = StringBuilder()
            var bodyLines = 0
            while (true) {
                val line = lines.next() ?: break
                if (line.isEmpty()) break
                if (bodyLines++ > 0) body.append('\n')
                if (line.length > SubtitleReferencePresentationCore.maximumTextBytes - body.length) return null
                body.append(line)
            }
            if (bodyLines == 0 || !SubtitleReferencePresentationCore.validText(body.toString())) return null
            result.add(Timing(start, end))
            previousStart = start
        }
        return complete(result)
    }

    private fun complete(values: ArrayList<Timing>): List<Timing>? =
        if (values.isEmpty()) null else Collections.unmodifiableList(values)

    private fun timestamp(match: MatchResult, first: Int): Long? {
        var result = 0L
        val scales = longArrayOf(3_600_000L, 60_000L, 1000L, 1L)
        for (part in scales.indices) {
            val text = match.groupValues[first + part]
            val value = if (text.isEmpty()) 0L else text.toLongOrNull() ?: return null
            val scale = scales[part]
            if (value > SubtitleReferencePresentationCore.maximumEndMs / scale) return null
            result += value * scale
            if (result > SubtitleReferencePresentationCore.maximumEndMs) return null
        }
        return result
    }

    /** Matches Media3 line boundaries: LF, CR, or CRLF; a final unterminated text line is valid. */
    private class Lines(private val text: String) {
        private var position = 0
        fun next(): String? {
            if (position == text.length) return null
            val start = position
            while (position < text.length && text[position] != '\n' && text[position] != '\r') position++
            val end = position
            if (position < text.length && text[position++] == '\r' &&
                position < text.length && text[position] == '\n') position++
            return text.substring(start, end)
        }
    }
}
