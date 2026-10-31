package com.vortx.android.player.subtitles

import com.vortx.android.engine.VortxJniBindings
import com.vortx.android.engine.VortxNativeRuntime
import java.io.ByteArrayOutputStream
import java.math.BigDecimal
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/**
 * Transport for the additive pure native query. Call only from the bounded subtitle worker.
 * An ephemeral empty runtime confers no player, track, account or saved-profile authority.
 */
internal object SubtitleReferenceQuery {
    const val scoringWindowStartMs = 0L
    const val scoringWindowEndMs = 900_000L
    const val referenceWindowEndMs = 1_080_000L

    data class Timing(val startMs: Long, val endMs: Long)
    data class RetimedCue(val startMs: Long, val endMs: Long, val text: String)
    data class Correction(val offsetMs: Long, val driftPpm: Int, val confidence: Int, val matched: Int, val total: Int)

    class Aligned internal constructor(
        val originalJob: String,
        srt: ByteArray,
        cues: List<RetimedCue>,
        val correction: Correction,
    ) {
        private val ownedSrt = srt.copyOf()
        val srt: ByteArray get() = ownedSrt.copyOf()
        val cues: List<RetimedCue> = java.util.Collections.unmodifiableList(ArrayList(cues))
        val offsetMs: Long get() = correction.offsetMs
        val driftPpm: Int get() = correction.driftPpm
        val confidence: Int get() = correction.confidence
    }

    /**
     * Send the COMPLETE external 0...900-second scoring window. The reference's 0...1080-second
     * envelope preserves the original prefix denominator and the native offset/drift search margin.
     * Keep every equal-start occurrence and every complete returned cue; never reparse or crop them.
     */
    fun align(
        externalSRT: ByteArray,
        reference: List<Timing>,
        originalJob: String,
        resolve: (String) -> String = ::resolveWithEphemeralRuntime,
    ): Aligned? = try {
        alignChecked(externalSRT, reference, originalJob, resolve)
    } catch (_: Exception) {
        null
    } catch (_: LinkageError) {
        // A missing/older ABI is unsupported, never proof that this additive query exists.
        null
    }

    private fun alignChecked(
        externalSRT: ByteArray,
        reference: List<Timing>,
        originalJob: String,
        resolve: (String) -> String,
    ): Aligned? {
        if (externalSRT.isEmpty() || externalSRT.size > MIB || reference.size !in 8..1024) return null
        if (originalJob.length != 36 || !UUID.fromString(originalJob).toString().equals(originalJob, ignoreCase = true)) return null
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(externalSRT)).toString()
        if ('\u0000' in text) return null
        val referenceRows = JSONArray()
        var previousStart = -1L
        for (cue in reference) {
            if (cue.startMs < 0 || cue.startMs >= cue.endMs || cue.endMs > referenceWindowEndMs || cue.startMs < previousStart) return null
            referenceRows.put(JSONObject().put("startMs", cue.startMs).put("endMs", cue.endMs))
            previousStart = cue.startMs
        }
        val payload = JSONObject().put("version", 1).put("originalJob", originalJob)
            .put("external", JSONObject().put("kind", "srt").put("text", text)).put("referenceCues", referenceRows)
            .put("windowStartMs", scoringWindowStartMs).put("windowEndMs", scoringWindowEndMs).put("allowDrift", true).toString()
        if (utf8Size(payload, 8 * MIB) == null) return null
        val query = JSONObject().put("kind", "subtitle_reference").put("payload", payload).toString()
        if (utf8Size(query, 16 * MIB) == null) return null
        val raw = resolve(query)
        if (utf8Size(raw, 16 * MIB) == null) return null
        val reply = JsonReply(raw).document() ?: return null
        if (reply.opt("kind") != "subtitle_reference") return null
        val result = reply.opt("result") as? JSONObject ?: return null
        if (integer(result, "version") != 1L || result.opt("status") != "aligned" || result.opt("originalJob") != originalJob) return null
        val correctionRow = result.opt("correction") as? JSONObject ?: return null
        val offset = integer(correctionRow, "offsetMs") ?: return null
        val drift = integer(correctionRow, "driftPpm") ?: return null
        val confidence = integer(correctionRow, "confidence") ?: return null
        val matched = integer(correctionRow, "matched") ?: return null
        val total = integer(correctionRow, "total") ?: return null
        val residual = integer(result, "medianResidualMs") ?: return null
        val work = integer(result, "workUsed") ?: return null
        if (offset !in -120_000L..120_000L || drift !in -50_000L..50_000L || confidence !in 700L..1000L ||
            matched < 8 || total !in 8L..1024L || total < matched || confidence != matched * 1000 / total ||
            residual !in 0L..150L || work !in 1L..40_000_000L) return null
        val rows = result.opt("cues") as? JSONArray ?: return null
        if (rows.length() !in 1..12_000) return null
        val cues = ArrayList<RetimedCue>(rows.length())
        val srt = ByteArrayOutputStream()
        previousStart = -1L
        for (index in 0 until rows.length()) {
            val row = rows.opt(index) as? JSONObject ?: return null
            val start = integer(row, "startMs") ?: return null
            val end = integer(row, "endMs") ?: return null
            val cueText = row.opt("text") as? String ?: return null
            if (start < 0 || start >= end || end > 91_000_000L || start < previousStart ||
                cueText.isEmpty() || utf8Size(cueText, 16_384) == null) return null
            val block = "${index + 1}\n${timestamp(start)} --> ${timestamp(end)}\n$cueText\n\n".toByteArray(Charsets.UTF_8)
            if (block.size > 8 * MIB - srt.size()) return null
            srt.write(block)
            cues.add(RetimedCue(start, end, cueText))
            previousStart = start
        }
        return Aligned(originalJob, srt.toByteArray(), cues,
            Correction(offset, drift.toInt(), confidence.toInt(), matched.toInt(), total.toInt()))
    }

    /** Renderer input is the exact owned native result, not an ordinary permissive SRT parse. */
    fun payload(file: Aligned, language: String): String? = try {
        if (utf8Size(language, 255) == null) null else {
            val cues = JSONArray()
            file.cues.forEach { cues.put(JSONObject().put("startMs", it.startMs).put("endMs", it.endMs).put("text", it.text)) }
            JSONObject().put("version", 1).put("language", language).put("cues", cues).toString()
                .takeIf { utf8Size(it, 9 * MIB) != null }
        }
    } catch (_: Exception) {
        null
    }

    private fun resolveWithEphemeralRuntime(query: String): String =
        VortxNativeRuntime.create(VortxJniBindings, "subtitle-reference-query", "Subtitle query").use { it.resolve(query) }

    // JSONObject.getLong coerces strings and truncates fractions. Validate a numeric, exact integer
    // before narrowing; BigDecimal also prevents JVM/Android overflow or floating-point saturation.
    private fun integer(row: JSONObject, name: String): Long? {
        val number = row.opt(name) as? Number ?: return null
        return try { BigDecimal(number.toString()).longValueExact() } catch (_: NumberFormatException) {
            null
        } catch (_: ArithmeticException) {
            null
        }
    }

    private fun timestamp(ms: Long): String = "${(ms / 3_600_000).toString().padStart(2, '0')}:" +
        "${(ms / 60_000 % 60).toString().padStart(2, '0')}:${(ms / 1000 % 60).toString().padStart(2, '0')}," +
        (ms % 1000).toString().padStart(3, '0')

    /** Count without allocating an oversized encoded copy; reject NUL and unpaired UTF-16. */
    private fun utf8Size(value: String, maximum: Int): Int? {
        if (value.length > maximum) return null
        var size = 0
        var index = 0
        while (index < value.length) {
            val c = value[index++]
            size += when {
                c == '\u0000' -> return null
                c.code < 0x80 -> 1
                c.code < 0x800 -> 2
                c.isHighSurrogate() -> {
                    if (index == value.length || !value[index++].isLowSurrogate()) return null
                    4
                }
                c.isLowSurrogate() -> return null
                else -> 3
            }
            if (size > maximum) return null
        }
        return size
    }

    /** Strict JSON grammar with lossless numbers; Android's JSONTokener otherwise rounds decimals. */
    private class JsonReply(private val text: String) {
        private var index = 0
        fun document(): JSONObject? {
            val result = value(0)
            whitespace()
            if (index != text.length) invalid()
            return result as? JSONObject
        }
        private fun invalid(): Nothing = throw IllegalArgumentException("Invalid subtitle reference reply")
        private fun whitespace() { while (index < text.length && text[index] in " \t\r\n") index++ }
        private fun consume(c: Char): Boolean = (index < text.length && text[index] == c).also { if (it) index++ }
        private fun value(depth: Int): Any {
            // The known reply has five levels. Bound unknown extra nesting before JSONTokener recurses.
            if (depth > 64) invalid()
            whitespace()
            if (index == text.length) invalid()
            return when (text[index]) {
                '{' -> {
                    index++; whitespace()
                    val objectValue = JSONObject()
                    if (!consume('}')) {
                        while (true) {
                            whitespace()
                            val key = string()
                            whitespace()
                            if (!consume(':')) invalid()
                            objectValue.put(key, value(depth + 1))
                            whitespace()
                            if (consume('}')) break
                            if (!consume(',')) invalid()
                        }
                    }
                    objectValue
                }
                '[' -> {
                    index++; whitespace()
                    val arrayValue = JSONArray()
                    if (!consume(']')) {
                        while (true) {
                            arrayValue.put(value(depth + 1))
                            whitespace()
                            if (consume(']')) break
                            if (!consume(',')) invalid()
                        }
                    }
                    arrayValue
                }
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", JSONObject.NULL)
                else -> number()
            }
        }
        private fun literal(token: String, value: Any): Any {
            if (!text.startsWith(token, index)) invalid()
            index += token.length
            return value
        }
        private fun string(): String {
            val start = index
            if (!consume('"')) invalid()
            while (index < text.length) {
                val c = text[index++]
                if (c == '"') return JSONTokener(text.substring(start, index)).nextValue() as String
                if (c.code < 0x20) invalid()
                if (c == '\\') {
                    if (index == text.length) invalid()
                    when (text[index++]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> Unit
                        'u' -> {
                            val first = hex()
                            if (first in 0xd800..0xdbff) {
                                if (!consume('\\') || !consume('u') || hex() !in 0xdc00..0xdfff) invalid()
                            } else if (first in 0xdc00..0xdfff) invalid()
                        }
                        else -> invalid()
                    }
                }
            }
            invalid()
        }
        private fun hex(): Int {
            if (text.length - index < 4) invalid()
            var value = 0
            repeat(4) { value = value * 16 + (text[index++].digitToIntOrNull(16) ?: invalid()) }
            return value
        }
        private fun number(): BigDecimal {
            val start = index
            consume('-')
            if (!consume('0')) {
                if (index == text.length || text[index] !in '1'..'9') invalid()
                while (index < text.length && text[index] in '0'..'9') index++
            }
            if (consume('.') && !digits()) invalid()
            if (consume('e') || consume('E')) { if (!consume('+')) consume('-'); if (!digits()) invalid() }
            // Preserve the source number before Android can round a fractional value into an integer.
            return BigDecimal(text.substring(start, index))
        }
        private fun digits(): Boolean {
            val start = index
            while (index < text.length && text[index] in '0'..'9') index++
            return index > start
        }
    }

    private const val MIB = 1024 * 1024
}
