package com.vortx.android.player.subtitles

import androidx.media3.common.text.Cue
import androidx.media3.common.util.Consumer
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.SubtitleParser
import androidx.media3.extractor.text.subrip.SubripParser
import androidx.media3.extractor.text.webvtt.WebvttParser
import androidx.media3.extractor.text.ssa.SsaParser
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Collections
import java.util.Locale

/** Strict bounded admission in front of the pinned Media3 subtitle parsers. */
@UnstableApi
internal object Media3AddonSubtitleParser {
    enum class Format { SRT, VTT, ASS }
    class Parsed internal constructor(
        val presentation: SubtitleCuePresentation,
        canonicalSrt: ByteArray,
        alignmentSrt: ByteArray?,
    ) {
        private val ownedCanonicalSrt = canonicalSrt.copyOf()
        private val ownedAlignmentSrt = alignmentSrt?.copyOf()
        fun canonicalSrtBytes(): ByteArray = ownedCanonicalSrt.copyOf()
        fun alignmentSrtBytes(): ByteArray? = ownedAlignmentSrt?.copyOf()
    }
    private data class Timing(val start: Long, val end: Long, val textBytes: Int)
    private data class Emitted(val cue: Cue, val start: Long, val end: Long)

    fun parse(raw: ByteArray, format: Format, permitsUse: () -> Boolean, isCancelled: () -> Boolean): Parsed? {
        if (raw.isEmpty() || raw.size > SubtitleReferencePresentationCore.maximumSrtBytes || !live(permitsUse, isCancelled)) return null
        val text = decode(raw) ?: return null
        if (!live(permitsUse, isCancelled)) return null
        val normalized = text.toByteArray(Charsets.UTF_8)
        if (normalized.size > SubtitleReferencePresentationCore.maximumSrtBytes) return null
        val timings = when (format) {
            Format.SRT -> preflightSrt(text, permitsUse, isCancelled)
            Format.VTT -> preflightVtt(text, permitsUse, isCancelled)
            Format.ASS -> preflightAss(text, permitsUse, isCancelled)
        } ?: return null
        val emittedBudget = boundedEmissionBudget(timings) ?: return null
        val emitted = ArrayList<Emitted>(timings.size)
        var emittedTextBytes = 0L
        val consumer = Consumer<CuesWithTiming> { group ->
            if (!live(permitsUse, isCancelled) || emitted.size + group.cues.size > emittedBudget) throw Refused()
            val start = group.startTimeUs / 1000L
            val end = (group.startTimeUs + group.durationUs) / 1000L
            if (group.startTimeUs < 0 || group.durationUs <= 0 || group.startTimeUs % 1000L != 0L || group.durationUs % 1000L != 0L) throw Refused()
            for (cue in group.cues) {
                val textCue = cue.text ?: throw Refused()
                if (cue.bitmap != null || textCue.isEmpty() || !SubtitleReferencePresentationCore.validText(textCue.toString())) throw Refused()
                emittedTextBytes += textCue.toString().toByteArray(Charsets.UTF_8).size
                if (emittedTextBytes > MAX_SEGMENT_TEXT_BYTES) throw Refused()
                emitted.add(Emitted(cue, start, end))
            }
        }
        try {
            when (format) {
                Format.SRT -> SubripParser().parse(normalized, 0, normalized.size, SubtitleParser.OutputOptions.allCues(), consumer)
                Format.VTT -> WebvttParser().parse(normalized, 0, normalized.size, SubtitleParser.OutputOptions.allCues(), consumer)
                Format.ASS -> SsaParser().parse(normalized, 0, normalized.size, SubtitleParser.OutputOptions.allCues(), consumer)
            }
        } catch (_: RuntimeException) { return null }
        catch (_: LinkageError) { return null }
        if (!live(permitsUse, isCancelled) || emitted.isEmpty() || emitted.size > emittedBudget) return null
        if (format == Format.SRT && (emitted.size != timings.size || emitted.indices.any { index ->
                emitted[index].start != timings[index].start || emitted[index].end != timings[index].end
            })) return null
        if (emitted.any { it.start < 0 || it.start >= it.end || it.end > SubtitleReferencePresentationCore.maximumEndMs }) return null
        val ordered = emitted.sortedWith(compareBy<Emitted> { it.start }.thenBy { it.end })
        val source = ordered.map { SubtitleReferencePresentationCore.SourceCue(it.start, it.end, it.cue.text.toString()) }
        val index = SubtitleReferencePresentationCore.IntervalIndex(source)
        val cues = Collections.unmodifiableList(ordered.map { it.cue })
        val canonical = canonicalSrt(ordered, permitsUse, isCancelled) ?: return null
        val alignment = if (format == Format.SRT && raw.size <= Media3OwnedSubtitleSrtEnvelope.maximumBytes &&
            Media3OwnedSubtitleSrtEnvelope.inspect(raw) != null && Media3OwnedSubtitlePresentation.prepareSrt(raw) != null) raw.copyOf() else null
        return Parsed(object : SubtitleCuePresentation {
            override fun lookup(mediaMs: Long): List<Cue> {
                val active = index.lookup(mediaMs)
                return if (active.isEmpty()) emptyList() else Collections.unmodifiableList(active.map { cues[it] })
            }
            override fun boundaryIdentity(mediaMs: Long): Int = index.boundaryAt(mediaMs)
        }, canonical, alignment)
    }

    private fun decode(bytes: ByteArray): String? = try {
        val charset = when {
            bytes.size >= 3 && bytes[0] == 0xef.toByte() && bytes[1] == 0xbb.toByte() && bytes[2] == 0xbf.toByte() -> Charsets.UTF_8
            bytes.size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte() -> Charsets.UTF_16LE
            bytes.size >= 2 && bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte() -> Charsets.UTF_16BE
            bytes.size > 3 && bytes[1] == 0.toByte() -> Charsets.UTF_16LE
            bytes.size > 3 && bytes[0] == 0.toByte() -> Charsets.UTF_16BE
            else -> Charsets.UTF_8
        }
        val decoded = charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString().removePrefix("\uFEFF")
        if (decoded.contains('\u0000')) null else decoded
    } catch (_: Exception) {
        val taggedUtf16 = bytes.size >= 2 && ((bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte()) ||
            (bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte()))
        if (taggedUtf16) null else runCatching { Charsets.ISO_8859_1.newDecoder().decode(ByteBuffer.wrap(bytes)).toString() }
            .getOrNull()?.takeUnless { it.contains('\u0000') }
    }

    private fun preflightVtt(text: String, permitsUse: () -> Boolean, isCancelled: () -> Boolean): List<Timing>? {
        if (!boundedSourceLines(text, permitsUse, isCancelled)) return null
        val lines = text.removePrefix("\uFEFF").lines()
        if (!boundedLineLengths(lines, permitsUse, isCancelled)) return null
        if (lines.firstOrNull()?.removeSuffix("\r")?.startsWith("WEBVTT") != true) return null
        val out = ArrayList<Timing>()
        var totalTextBytes = 0L
        var styleBytes = 0
        var styleLines = 0
        var styleRules = 0
        var i = 1
        // Media3 consumes header metadata up to the first empty line before reading cues.
        // These lines already passed the source, line-length and normalized-byte caps.
        while (i < lines.size && lines[i].isNotEmpty()) {
            if ((i and 0xff) == 0 && !live(permitsUse, isCancelled)) return null
            i++
        }
        if (i == lines.size) return null
        i++
        while (i < lines.size) {
            if ((i and 0xff) == 0 && !live(permitsUse, isCancelled)) return null
            if (!liveTextLine(lines[i])) return null
            val rawLine = lines[i]
            val line = rawLine.trim()
            i++
            if (rawLine.isEmpty()) continue
            if (rawLine.startsWith("NOTE") || rawLine == "STYLE") {
                val isStyle = rawLine == "STYLE"
                while (i < lines.size && lines[i].isNotEmpty()) {
                    if ((i and 0xff) == 0 && !live(permitsUse, isCancelled)) return null
                    if (isStyle) {
                        styleBytes += lines[i].toByteArray(Charsets.UTF_8).size
                        styleLines++
                        styleRules += lines[i].count { it == '{' }
                        if (styleBytes > MAX_VTT_STYLE_BYTES || styleLines > MAX_STYLE_LINES ||
                            styleRules > MAX_STYLE_RULES) return null
                    }
                    i++
                }
                continue
            }
            val timingLine = if (line.contains("-->")) line else lines.getOrNull(i++)?.trim().orEmpty()
            val match = VTT_LINE.matchEntire(timingLine) ?: return null
            val halves = match.groupValues[1] to match.groupValues[2]
            val start = parseVttTime(halves.first.trim()) ?: return null
            val end = parseVttTime(halves.second.trim().substringBefore(' ')) ?: return null
            if (start >= end) return null
            if (out.lastOrNull()?.start?.let { start < it } == true) return null
            var chars = 0
            while (i < lines.size && lines[i].isNotEmpty()) {
                if ((i and 0xff) == 0 && !live(permitsUse, isCancelled)) return null
                chars += lines[i].toByteArray(Charsets.UTF_8).size + 1
                if (chars > SubtitleReferencePresentationCore.maximumTextBytes) return null
                i++
            }
            if (chars == 0) return null
            totalTextBytes += chars
            if (totalTextBytes > SubtitleReferencePresentationCore.maximumSrtBytes) return null
            out.add(Timing(start, end, chars))
            if (out.size > SubtitleReferencePresentationCore.maximumCues) return null
        }
        return out.takeIf { it.isNotEmpty() }
    }

    /** Strict bounded SRT framing for the ordinary 8 MiB file path; alignment keeps its 1 MiB proof. */
    private fun preflightSrt(text: String, permitsUse: () -> Boolean, isCancelled: () -> Boolean): List<Timing>? {
        if (!boundedSourceLines(text, permitsUse, isCancelled)) return null
        val lines = text.removePrefix("\uFEFF").lines()
        if (!boundedLineLengths(lines, permitsUse, isCancelled)) return null
        val result = ArrayList<Timing>()
        var i = 0
        var textBytes = 0L
        var priorStart = -1L
        while (i < lines.size) {
            if ((i and 0xff) == 0 && !live(permitsUse, isCancelled)) return null
            while (i < lines.size && lines[i].isBlank()) i++
            if (i == lines.size) break
            if (lines[i].length > 16 || lines[i].toLongOrNull() == null) return null
            i++
            if (i >= lines.size) return null
            val match = SRT_LINE.matchEntire(lines[i++]) ?: return null
            val start = parseSrtTime(match, 1) ?: return null
            val end = parseSrtTime(match, 5) ?: return null
            if (start < priorStart || start >= end) return null
            priorStart = start
            var bodyBytes = 0
            var bodyLines = 0
            while (i < lines.size && lines[i].isNotEmpty()) {
                if ((i and 0xff) == 0 && !live(permitsUse, isCancelled)) return null
                val size = lines[i].toByteArray(Charsets.UTF_8).size
                if (size > SubtitleReferencePresentationCore.maximumTextBytes || bodyBytes + size + 1 > SubtitleReferencePresentationCore.maximumTextBytes) return null
                bodyBytes += size + 1
                bodyLines++
                i++
            }
            if (bodyLines == 0) return null
            textBytes += bodyBytes
            if (textBytes > SubtitleReferencePresentationCore.maximumSrtBytes) return null
            result.add(Timing(start, end, bodyBytes))
            if (result.size > SubtitleReferencePresentationCore.maximumCues) return null
        }
        return result.takeIf { it.isNotEmpty() }
    }

    private fun parseSrtTime(match: MatchResult, first: Int): Long? {
        val hours = match.groupValues[first]
        val h = if (hours.isEmpty()) 0L else hours.toLongOrNull() ?: return null
        val m = match.groupValues[first + 1].toLongOrNull() ?: return null
        val s = match.groupValues[first + 2].toLongOrNull() ?: return null
        val ms = match.groupValues[first + 3].toLongOrNull() ?: return null
        if (h > SubtitleReferencePresentationCore.maximumEndMs / 3_600_000L || m > 59 || s > 59 || ms > 999) return null
        return h * 3_600_000L + m * 60_000L + s * 1000L + ms
    }

    private fun preflightAss(text: String, permitsUse: () -> Boolean, isCancelled: () -> Boolean): List<Timing>? {
        if (!boundedSourceLines(text, permitsUse, isCancelled)) return null
        val lines = text.lines()
        if (!boundedLineLengths(lines, permitsUse, isCancelled)) return null
        val out = ArrayList<Timing>()
        var totalTextBytes = 0L
        var headerBytes = 0
        var headerLines = 0
        var inEvents = false
        var fields: List<String>? = null
        for ((lineIndex, line) in lines.withIndex()) {
            if ((lineIndex and 0xff) == 0 && !live(permitsUse, isCancelled)) return null
            if (line.startsWith("[")) { inEvents = line.equals("[Events]", true); fields = null; continue }
            if (!inEvents) {
                headerBytes += line.toByteArray(Charsets.UTF_8).size
                headerLines++
                if (headerBytes > MAX_ASS_HEADER_BYTES || headerLines > MAX_ASS_HEADER_LINES) return null
                continue
            }
            if (!line.startsWith("Dialogue:", true)) {
                headerBytes += line.toByteArray(Charsets.UTF_8).size
                headerLines++
                if (headerBytes > MAX_ASS_HEADER_BYTES || headerLines > MAX_ASS_HEADER_LINES) return null
            }
            if (line.startsWith("Format:", true)) {
                if (line.length > 8192) return null
                fields = line.substringAfter(':').split(',').map { it.trim() }.takeIf { it.size <= 64 } ?: return null
                continue
            }
            if (!line.startsWith("Dialogue:", true)) continue
            val names = fields ?: return null
            val startIndex = names.indexOfFirst { it.equals("Start", true) }
            val endIndex = names.indexOfFirst { it.equals("End", true) }
            val textIndex = names.indexOfFirst { it.equals("Text", true) }
            if (startIndex < 0 || endIndex < 0 || textIndex < 0) return null
            if (line.length > 64 * 1024) return null
            val parts = line.substringAfter(':').split(',', limit = names.size)
            if (parts.size != names.size) return null
            val start = parseAssTime(parts[startIndex].trim()) ?: return null
            val end = parseAssTime(parts[endIndex].trim()) ?: return null
            val payload = parts[textIndex]
            if (start >= end || payload.isEmpty() || payload.toByteArray(Charsets.UTF_8).size > SubtitleReferencePresentationCore.maximumTextBytes) return null
            if (out.lastOrNull()?.start?.let { start < it } == true) return null
            totalTextBytes += payload.toByteArray(Charsets.UTF_8).size
            if (totalTextBytes > SubtitleReferencePresentationCore.maximumSrtBytes) return null
            out.add(Timing(start, end, payload.toByteArray(Charsets.UTF_8).size))
            if (out.size > SubtitleReferencePresentationCore.maximumCues) return null
        }
        return out.takeIf { it.isNotEmpty() }
    }

    private fun boundedEmissionBudget(cues: List<Timing>): Int? {
        if (cues.isEmpty() || cues.size > SubtitleReferencePresentationCore.maximumCues) return null
        data class Event(val time: Long, val countDelta: Int, val textDelta: Int)
        val events = ArrayList<Event>(cues.size * 2)
        for (cue in cues) {
            if (cue.start < 0 || cue.start >= cue.end || cue.end > SubtitleReferencePresentationCore.maximumEndMs) return null
            if (cue.textBytes <= 0 || cue.textBytes > SubtitleReferencePresentationCore.maximumSrtBytes) return null
            events.add(Event(cue.start, 1, cue.textBytes)); events.add(Event(cue.end, -1, -cue.textBytes))
        }
        events.sortBy { it.time }
        var active = 0
        var activeTextBytes = 0L
        var expanded = 0L
        var expandedTextBytes = 0L
        var i = 0
        while (i < events.size) {
            val time = events[i].time
            while (i < events.size && events[i].time == time) {
                active += events[i].countDelta
                activeTextBytes += events[i].textDelta
                i++
            }
            if (active > MAX_OVERLAP || active < 0 || activeTextBytes < 0) return null
            if (i < events.size && events[i].time > time) {
                expanded += active
                expandedTextBytes += activeTextBytes
                if (expanded > MAX_EMITTED_CUES || expandedTextBytes > MAX_SEGMENT_TEXT_BYTES) return null
            }
        }
        return expanded.coerceAtLeast(1).toInt()
    }

    private fun canonicalSrt(cues: List<Emitted>, permitsUse: () -> Boolean, isCancelled: () -> Boolean): ByteArray? {
        val out = ByteArrayOutputStream()
        for ((i, item) in cues.withIndex()) {
            if ((i and 0x3f) == 0 && !live(permitsUse, isCancelled)) return null
            val text = item.cue.text?.toString() ?: return null
            if (!SubtitleReferencePresentationCore.validText(text)) return null
            val plain = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            val block = "${i + 1}\n${format(item.start)} --> ${format(item.end)}\n$plain\n\n".toByteArray(Charsets.UTF_8)
            if (out.size() + block.size > SubtitleReferencePresentationCore.maximumSrtBytes) return null
            out.write(block)
        }
        return out.toByteArray().takeIf { it.isNotEmpty() }
    }

    private fun format(ms: Long): String = String.format(Locale.ROOT, "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    private fun parseVttTime(value: String): Long? {
        val match = VTT_TIMESTAMP.matchEntire(value) ?: return null
        val hours = match.groupValues[1]
        val h = if (hours.isEmpty()) 0L else hours.toLongOrNull() ?: return null
        val m = match.groupValues[2].toLongOrNull() ?: return null
        val s = match.groupValues[3].toLongOrNull() ?: return null
        val ms = match.groupValues[4].toLongOrNull() ?: return null
        if (h > SubtitleReferencePresentationCore.maximumEndMs / 3_600_000L || m > 59 || s > 59) return null
        return h * 3_600_000 + m * 60_000 + s * 1000 + ms
    }
    private fun parseAssTime(value: String): Long? {
        val match = ASS_TIMESTAMP.matchEntire(value) ?: return null
        val h = match.groupValues[1].toLongOrNull() ?: return null
        val m = match.groupValues[2].toLongOrNull() ?: return null
        val s = match.groupValues[3].toLongOrNull() ?: return null
        val cs = match.groupValues[4].toLongOrNull() ?: return null
        if (h > SubtitleReferencePresentationCore.maximumEndMs / 3_600_000L || m > 59 || s > 59 || cs > 99) return null
        return h * 3_600_000 + m * 60_000 + s * 1000 + cs * 10
    }
    private fun live(permitsUse: () -> Boolean, isCancelled: () -> Boolean): Boolean =
        runCatching { permitsUse() && !isCancelled() }.getOrDefault(false)
    private fun boundedSourceLines(text: String, permitsUse: () -> Boolean, isCancelled: () -> Boolean): Boolean {
        var lines = 1
        for (i in text.indices) {
            if ((i and 0xfff) == 0 && !live(permitsUse, isCancelled)) return false
            if (text[i] == '\n' || text[i] == '\r') {
                if (text[i] == '\r' && text.getOrNull(i + 1) == '\n') continue
                lines++
                if (lines > MAX_SOURCE_LINES) return false
            }
        }
        return live(permitsUse, isCancelled)
    }
    private fun boundedLineLengths(lines: List<String>, permitsUse: () -> Boolean, isCancelled: () -> Boolean): Boolean {
        for (i in lines.indices) {
            if ((i and 0xff) == 0 && !live(permitsUse, isCancelled)) return false
            if (lines[i].length > SubtitleReferencePresentationCore.maximumTextBytes) return false
        }
        return live(permitsUse, isCancelled)
    }
    private fun liveTextLine(value: String) = value.length <= 16_384
    private class Refused : RuntimeException()
    private val VTT_LINE = Regex("^(.+?)\\s+-->\\s+(.+?)(?:\\s+.*)?$")
    private val VTT_TIMESTAMP = Regex("^(?:([0-9]{2,}):)?([0-9]{2}):([0-9]{2})\\.([0-9]{3})$")
    private val ASS_TIMESTAMP = Regex("^([0-9]+):([0-9]{2}):([0-9]{2})\\.([0-9]{2})$")
    private val SRT_LINE = Regex("\\s*(?:(\\d+):)?(\\d+):(\\d+),(\\d{3})\\s+-->\\s*(?:(\\d+):)?(\\d+):(\\d+),(\\d{3})\\s*")
    private const val MAX_OVERLAP = 128
    private const val MAX_EMITTED_CUES = 65_536L
    private const val MAX_SEGMENT_TEXT_BYTES = 8L * 1024 * 1024
    private const val MAX_VTT_STYLE_BYTES = 64 * 1024
    private const val MAX_STYLE_LINES = 256
    private const val MAX_STYLE_RULES = 256
    private const val MAX_ASS_HEADER_BYTES = 256 * 1024
    private const val MAX_ASS_HEADER_LINES = 4096
    private const val MAX_SOURCE_LINES = 65_536
}
