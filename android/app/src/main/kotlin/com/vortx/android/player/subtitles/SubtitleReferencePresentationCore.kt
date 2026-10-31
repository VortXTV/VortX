package com.vortx.android.player.subtitles

import java.util.Collections
import java.util.Locale

/** Pure, bounded preparation shared by the Android renderer and local JVM tests. */
internal object SubtitleReferencePresentationCore {
    const val maximumCues = 12_000
    const val maximumTextBytes = 16_384
    const val maximumSrtBytes = 8 * 1024 * 1024
    const val maximumEndMs = 91_000_000L

    data class Style(
        val bold: Boolean = false,
        val italic: Boolean = false,
        val underline: Boolean = false,
        val foregroundRgb: Int? = null,
    )

    data class Run(val text: String, val style: Style)
    data class SourceCue(val startMs: Long, val endMs: Long, val text: String)
    data class ParsedCue(val source: SourceCue, val runs: List<Run>)
    class Parsed internal constructor(val cues: List<ParsedCue>, val index: IntervalIndex)

    /** All cues are accepted before any platform text or renderer state is constructed. */
    fun prepare(srtBytes: Int, source: List<SourceCue>): Parsed? {
        if (srtBytes !in 1..maximumSrtBytes || source.size !in 1..maximumCues) return null
        val parsed = ArrayList<ParsedCue>(source.size)
        var previousStart = -1L
        for (cue in source) {
            if (cue.startMs < 0 || cue.startMs < previousStart || cue.startMs >= cue.endMs ||
                cue.endMs > maximumEndMs || cue.text.isEmpty() || !validText(cue.text)) return null
            val runs = parseRuns(cue.text) ?: return null
            parsed.add(ParsedCue(cue, runs))
            previousStart = cue.startMs
        }
        return Parsed(immutable(parsed), IntervalIndex(source))
    }

    /**
     * A finite SRT subset, never HTML parsing. Decode entities only after recognizing authored
     * markup, so escaped tags stay literal. Unsupported tags, attributes or ASS effects reject the
     * complete representation. Whitespace, equal-style transitions and authored line breaks survive.
     */
    fun parseRuns(text: String): List<Run>? {
        if (!validText(text) || text.contains("{\\")) return null
        val result = ArrayList<Run>()
        var style = Style()
        val stack = ArrayList<Pair<String, Style>>()
        val buffer = StringBuilder()
        var cursor = 0
        fun flush() {
            if (buffer.isNotEmpty()) {
                result.add(Run(buffer.toString(), style))
                buffer.setLength(0)
            }
        }
        while (cursor < text.length) {
            when (text[cursor]) {
                '<' -> {
                    val end = text.indexOf('>', cursor + 1)
                    if (end == -1) return null
                    val raw = text.substring(cursor + 1, end).trim()
                    val lower = raw.lowercase(Locale.ROOT)
                    when {
                        lower == "br" || lower == "br/" -> buffer.append('\n')
                        lower.startsWith('/') -> {
                            val tag = lower.substring(1)
                            val prior = stack.lastOrNull() ?: return null
                            if (prior.first != tag) return null
                            flush()
                            style = prior.second
                            stack.removeAt(stack.lastIndex)
                        }
                        else -> {
                            val tag: String
                            val next: Style
                            when (lower) {
                                "b" -> { tag = "b"; next = style.copy(bold = true) }
                                "i" -> { tag = "i"; next = style.copy(italic = true) }
                                "u" -> { tag = "u"; next = style.copy(underline = true) }
                                else -> {
                                    val rgb = fontColour(raw) ?: return null
                                    tag = "font"
                                    next = style.copy(foregroundRgb = rgb)
                                }
                            }
                            flush()
                            stack.add(tag to style)
                            style = next
                        }
                    }
                    cursor = end + 1
                }
                '&' -> {
                    var end = cursor + 1
                    // Stop at lexical delimiters; repeated literal ampersands stay linear work.
                    while (end < text.length && text[end] != ';' && text[end] != '&' &&
                        text[end] != '<' && !text[end].isWhitespace()) end++
                    if (end < text.length && text[end] == ';') {
                        val decoded = entity(text.substring(cursor + 1, end)) ?: return null
                        buffer.append(decoded)
                        cursor = end + 1
                    } else {
                        buffer.append('&')
                        cursor++
                    }
                }
                else -> buffer.append(text[cursor++])
            }
        }
        if (stack.isNotEmpty()) return null
        flush()
        return immutable(result)
    }

    private fun fontColour(raw: String): Int? {
        if (raw.length <= 4 || !raw.regionMatches(0, "font", 0, 4, ignoreCase = true) ||
            !raw[4].isWhitespace()) return null
        var value = raw.substring(4).trim()
        if (!value.startsWith("color", ignoreCase = true)) return null
        value = value.substring(5).trim()
        if (!value.startsWith('=')) return null
        value = value.substring(1).trim()
        if (value.length != 9 || (value[0] != '\'' && value[0] != '"') || value.last() != value[0] ||
            value[1] != '#') return null
        val digits = value.substring(2, 8)
        if (digits.any { asciiDigit(it, 16) < 0 }) return null
        return digits.toIntOrNull(16)
    }

    private fun entity(name: String): String? = when (name) {
        "amp" -> "&"
        "lt" -> "<"
        "gt" -> ">"
        "quot" -> "\""
        "apos" -> "'"
        "nbsp" -> "\u00a0"
        else -> {
            if (!name.startsWith('#')) null else {
                val hex = name.length > 1 && (name[1] == 'x' || name[1] == 'X')
                val start = if (hex) 2 else 1
                val base = if (hex) 16 else 10
                var value = 0
                var valid = start < name.length
                for (i in start until name.length) {
                    val digit = asciiDigit(name[i], base)
                    if (digit < 0 || value > (0x10ffff - digit) / base) { valid = false; break }
                    value = value * base + digit
                }
                if (!valid || value == 0 || value in 0xd800..0xdfff) null
                else String(Character.toChars(value))
            }
        }
    }

    private fun asciiDigit(value: Char, base: Int): Int {
        val digit = when (value) {
            in '0'..'9' -> value.code - '0'.code
            in 'a'..'f' -> value.code - 'a'.code + 10
            in 'A'..'F' -> value.code - 'A'.code + 10
            else -> -1
        }
        return if (digit in 0 until base) digit else -1
    }

    /** UTF-8 byte count with no oversized encoded allocation; reject NUL and unpaired UTF-16. */
    fun validText(text: String): Boolean {
        if (text.length > maximumTextBytes) return false
        var bytes = 0
        var cursor = 0
        while (cursor < text.length) {
            val c = text[cursor++]
            bytes += when {
                c == '\u0000' -> return false
                c.code < 0x80 -> 1
                c.code < 0x800 -> 2
                c.isHighSurrogate() -> {
                    if (cursor == text.length || !text[cursor++].isLowSurrogate()) return false
                    4
                }
                c.isLowSurrogate() -> return false
                else -> 3
            }
            if (bytes > maximumTextBytes) return false
        }
        return true
    }

    /**
     * Immutable segment tree over the original sorted-start order. Max end bounds prune inactive
     * subtrees, including very old long-running cues mixed with many already-ended short cues.
     * Query work visits the matching leaves and their tree paths, not every cue on every tick.
     */
    class IntervalIndex internal constructor(source: List<SourceCue>) {
        private val starts = LongArray(source.size) { source[it].startMs }
        private val ends = LongArray(source.size) { source[it].endMs }
        private val maximumEnds = LongArray(maxOf(1, source.size * 4))
        private val boundaries = source.flatMap { listOf(it.startMs, it.endMs) }.distinct().sorted().toLongArray()

        init { if (source.isNotEmpty()) build(1, 0, source.size) }

        val boundaryCount: Int get() = boundaries.size

        /** Stable within this index. Half-open intervals apply the complete equal-time group. */
        fun boundaryAt(mediaMs: Long): Int {
            var low = 0
            var high = boundaries.size
            while (low < high) {
                val middle = low + (high - low) / 2
                if (boundaries[middle] <= mediaMs) low = middle + 1 else high = middle
            }
            return low - 1
        }

        fun lookup(mediaMs: Long): List<Int> {
            if (starts.isEmpty() || mediaMs < starts[0] || maximumEnds[1] <= mediaMs) return emptyList()
            val result = ArrayList<Int>()
            visit(1, 0, starts.size, mediaMs, result)
            return immutable(result)
        }

        private fun build(node: Int, low: Int, high: Int): Long {
            val value = if (high - low == 1) ends[low] else {
                val middle = low + (high - low) / 2
                maxOf(build(node * 2, low, middle), build(node * 2 + 1, middle, high))
            }
            maximumEnds[node] = value
            return value
        }

        private fun visit(node: Int, low: Int, high: Int, at: Long, result: MutableList<Int>) {
            if (starts[low] > at || maximumEnds[node] <= at) return
            if (high - low == 1) { result.add(low); return }
            val middle = low + (high - low) / 2
            visit(node * 2, low, middle, at, result)
            visit(node * 2 + 1, middle, high, at, result)
        }
    }

    /** Caller samples the real media clock; this tracker never advances using wall-clock time. */
    class BoundaryClock {
        private var owner: Any? = null
        private var boundary: Int? = null

        fun changed(nextOwner: Any, nextBoundary: Int): Boolean {
            val changed = owner !== nextOwner || boundary != nextBoundary
            owner = nextOwner
            boundary = nextBoundary
            return changed
        }

        fun reset() { owner = null; boundary = null }
    }

    private fun <T> immutable(values: Collection<T>): List<T> =
        Collections.unmodifiableList(ArrayList(values))
}
