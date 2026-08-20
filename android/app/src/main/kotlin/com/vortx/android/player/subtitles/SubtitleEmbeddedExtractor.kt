package com.vortx.android.player.subtitles

import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteBuffer

/**
 * Extract EMBEDDED TEXT subtitle tracks from a container for the community-subtitle system. The Android port
 * of Apple `app/SourcesShared/SubtitleEmbeddedExtractor.swift`.
 *
 * WHY this exists even though the player already renders embedded subs during playback: this extractor is NOT
 * for local display. Both engines (libmpv, ExoPlayer) render the file's own tracks fine on their own. This
 * produces standalone SRT/VTT TEXT so we can UPLOAD an embedded subtitle to the pool
 * ([SubtitlePoolClient.upload], origin "embedded") so a viewer on a DIFFERENT rip that lacks it benefits.
 *
 * SCOPE, matched to Apple's `isTextSubtitle`: TEXT subtitle codecs ONLY -- SubRip/SRT, WebVTT, mov_text
 * (tx3g), ASS/SSA, raw TEXT. IMAGE subtitles (PGS/HDMV, DVD/VobSub, DVB) are SKIPPED here: they are bitmaps,
 * not text, and belong to the OCR contribution path ([SubtitleImageOcr]).
 *
 * DEMUX BACKEND (the honest Android divergence from Apple's FFmpeg): Apple demuxes with libav, already linked
 * via MPVKit-GPL. Android does not link FFmpeg from Kotlin, so this uses the platform [MediaExtractor]
 * (dependency-free, flavor-neutral, FOSS-safe -- no GPL/native add). MediaExtractor surfaces the common text
 * subtitle codecs the platform extractors expose; a container whose text track the platform does not demux
 * simply yields nothing here (fail-soft), exactly as Apple yields nothing for a codec its `isTextSubtitle`
 * rejects. The pure SRT/VTT assembly + ASS field parsing below is byte-for-byte Apple's and is unit-tested on
 * the JVM; only the thin [extractTextSubtitles] demux shell needs an Android runtime.
 *
 * FAIL-SOFT: returns `[]` on ANY error (open failure, no text tracks, read failure). Never throws. Call OFF
 * the main thread (blocking I/O).
 *
 * LOCAL FILES ONLY: [extractTextSubtitles] walks the ENTIRE container sequentially -- text cues are
 * interleaved through the whole file. On a local file (a finished download) that is a quick disk read; on a
 * network input it would make the platform RE-DOWNLOAD the whole file at full rate alongside the player. That
 * was the 0.3.9/0.3.10 Apple TV regression (a streamed remux accumulating frame drops), so callers pre-check
 * with [isLocalFileInput] and the extractor hard-refuses a non-file input. The 127.0.0.1 torrent loopback
 * counts as REMOTE.
 */
object SubtitleEmbeddedExtractor {

    /** One extracted text subtitle track. Mirrors Apple `ExtractedTrack`. */
    data class ExtractedTrack(
        /** ISO code from the track's language metadata, or "und". */
        val lang: String,
        /** "srt" | "vtt". */
        val format: String,
        /** The assembled subtitle text (SRT unless [format] is "vtt"). */
        val srt: String,
        /** Number of cues emitted (0-cue tracks are still returned so the caller can decide). */
        val cueCount: Int,
    )

    /** Shown-for duration when the container gives a cue no end time. Matches Apple's `+ 3000` ms fallback. */
    private const val DEFAULT_CUE_MS = 3_000L

    /** Guard the per-sample read buffer so a hostile/oversized sample cannot balloon memory. */
    private const val MAX_SAMPLE_BYTES = 1 shl 20 // 1 MiB, matches the pool text codec's practical ceiling

    /**
     * TEXT subtitle MIME types the platform demuxes and this extractor understands, mapped to how a sample's
     * bytes are turned into cue text ([decodeSampleText]). The set mirrors Apple's `isTextSubtitle` codec list;
     * IMAGE codecs (PGS/VobSub/DVB) are deliberately absent.
     */
    private val TEXT_MIME_TYPES = setOf(
        "application/x-subrip", // SubRip / SRT
        "text/vtt",             // WebVTT
        "application/x-media3-cues", // Media3 normalized cue container (WebVTT/TTML/SubRip parsed upstream)
        "application/ttml+xml", // TTML (timed text)
        "application/x-quicktime-tx3g", // mov_text (tx3g)
        "application/mp4vtt",   // fMP4 WebVTT
        "text/x-ssa",           // ASS / SSA
    )

    /**
     * True only for an input already fully on this device: an absolute file path or a `file://` URL. Everything
     * else (http/https debrid or CDN links, `content://`, and the 127.0.0.1 torrent loopback) is remote.
     * Byte-for-byte Apple's `isLocalFileInput`.
     */
    fun isLocalFileInput(input: String): Boolean {
        if (input.startsWith("/")) return true
        return input.startsWith("file://", ignoreCase = true)
    }

    /**
     * Extract every TEXT subtitle track from [input]. [preferVTT] picks the WebVTT container for the output
     * text (default false = SRT). Blocking; call off the main thread. Returns `[]` on any error or a non-file
     * input.
     */
    fun extractTextSubtitles(input: String, preferVTT: Boolean = false): List<ExtractedTrack> {
        if (!isLocalFileInput(input)) return emptyList() // never demux a network input (see the type doc)
        val path = if (input.startsWith("file://", ignoreCase = true)) {
            runCatching { java.net.URI(input).path }.getOrNull() ?: return emptyList()
        } else {
            input
        }
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            val builders = selectTextTracks(extractor)
            if (builders.isEmpty()) return emptyList()
            drainSamples(extractor, builders)
            builders.entries
                .sortedBy { it.key }
                .map { it.value.finish(preferVTT) }
        } catch (_: Throwable) {
            emptyList()
        } finally {
            runCatching { extractor.release() }
        }
    }

    /** Select every text subtitle track and build a per-track cue accumulator keyed by track index. */
    private fun selectTextTracks(extractor: MediaExtractor): Map<Int, CueBuilder> {
        val builders = linkedMapOf<Int, CueBuilder>()
        for (i in 0 until extractor.trackCount) {
            val format = runCatching { extractor.getTrackFormat(i) }.getOrNull() ?: continue
            val mime = format.getString(MediaFormat.KEY_MIME)?.lowercase() ?: continue
            if (mime !in TEXT_MIME_TYPES) continue
            runCatching { extractor.selectTrack(i) }.getOrNull() ?: continue
            builders[i] = CueBuilder(lang = languageTag(format), mime = mime, assPreTextCommas = assPreTextCommas(format))
        }
        return builders
    }

    /** Read every selected track's samples in file order, appending each to its builder. */
    private fun drainSamples(extractor: MediaExtractor, builders: Map<Int, CueBuilder>) {
        val buffer = ByteBuffer.allocate(MAX_SAMPLE_BYTES)
        while (true) {
            val index = extractor.sampleTrackIndex
            if (index < 0) break
            val builder = builders[index]
            if (builder != null) {
                buffer.clear()
                val read = runCatching { extractor.readSampleData(buffer, 0) }.getOrDefault(-1)
                if (read > 0) {
                    val bytes = ByteArray(read)
                    buffer.position(0)
                    buffer.get(bytes, 0, read)
                    val startMs = maxOf(0L, extractor.sampleTime / 1_000L)
                    val text = decodeSampleText(bytes, builder.mime, builder.assPreTextCommas)
                    if (text.isNotEmpty()) {
                        builder.add(startMs = startMs, endMs = startMs + DEFAULT_CUE_MS, text = text)
                    }
                }
            }
            if (!extractor.advance()) break
        }
    }

    // MARK: - Sample decode

    /**
     * Turn one raw subtitle sample into cue text. tx3g carries a 2-byte big-endian length prefix; ASS/SSA rows
     * are split by the declared pre-Text comma count; everything else is UTF-8 cue text. Fail-soft: an
     * undecodable sample yields "".
     */
    internal fun decodeSampleText(bytes: ByteArray, mime: String, assPreTextCommas: Int): String {
        if (bytes.isEmpty()) return ""
        return when (mime) {
            "application/x-quicktime-tx3g" -> movTextBody(bytes)
            "text/x-ssa" -> plainTextFromAss(String(bytes, Charsets.UTF_8), assPreTextCommas)
            else -> String(bytes, Charsets.UTF_8).trim()
        }
    }

    /**
     * The text of a tx3g sample: a 2-byte big-endian length followed by that many UTF-8 bytes. Trailing style
     * boxes are ignored. Empty when the sample is too short or the length overruns. Mirrors Apple
     * `SubtitleRenditionPolicy.movTextBody`.
     */
    internal fun movTextBody(bytes: ByteArray): String {
        if (bytes.size < 2) return ""
        val length = ((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)
        if (length <= 0 || 2 + length > bytes.size) return ""
        return String(bytes, 2, length, Charsets.UTF_8).trim()
    }

    /**
     * Extract the visible text from an ASS/SSA event row: split on the declared pre-Text comma count (commas
     * INSIDE the Text are preserved), then strip `{...}` override tags and convert `\N`/`\n` to newlines.
     * Byte-for-byte Apple `SubtitleEmbeddedExtractor.plainTextFromASS`.
     */
    internal fun plainTextFromAss(ass: String, preTextCommas: Int): String {
        val declared = maxOf(1, preTextCommas)
        val rowCommas = ass.count { it == ',' }
        val splits = when {
            rowCommas >= declared -> declared
            rowCommas >= STANDARD_ASS_PRE_TEXT_COMMAS -> STANDARD_ASS_PRE_TEXT_COMMAS
            else -> declared
        }
        val parts = ass.split(",", limit = splits + 1)
        val textField = if (parts.size > splits) parts[splits] else ass
        val noTags = textField.replace(Regex("\\{[^}]*\\}"), "")
        return noTags
            .replace("\\N", "\n")
            .replace("\\n", "\n")
            .trim()
    }

    /** The standard v4+ event row has 8 commas before the Text field. Apple `standardASSPreTextCommas`. */
    private const val STANDARD_ASS_PRE_TEXT_COMMAS = 8

    /**
     * How many commas precede the Text field in this track's decoded event rows, read from the `[Events]`
     * `Format:` line of the SSA/ASS header carried in the format's codec-private data ("csd-0"). Falls back to
     * the standard 8 when the header is absent or nonconforming. Mirrors Apple `assPreTextCommas`.
     */
    private fun assPreTextCommas(format: MediaFormat): Int {
        val csd = runCatching { format.getByteBuffer("csd-0") }.getOrNull() ?: return STANDARD_ASS_PRE_TEXT_COMMAS
        val bytes = ByteArray(csd.remaining())
        runCatching { csd.duplicate().get(bytes) }.getOrNull() ?: return STANDARD_ASS_PRE_TEXT_COMMAS
        val header = String(bytes, Charsets.UTF_8).replace(" ", "")
        return preTextCommaCount(header)
    }

    /**
     * Parse [header] (a full ASS/SSA script head) for the `[Events]` section's `Format:` line and derive the
     * pre-Text comma count of a demuxed event row. Pure + fail-soft: any shape surprise returns the standard 8.
     * Byte-for-byte Apple `SubtitleEmbeddedExtractor.preTextCommaCount`.
     */
    internal fun preTextCommaCount(header: String): Int {
        var inEvents = false
        for (rawLine in header.split("\n")) {
            val line = rawLine.trim() // tolerate \r\n headers
            if (line.startsWith("[")) {
                inEvents = line.lowercase().startsWith("[events]")
                continue
            }
            if (!inEvents || !line.lowercase().startsWith("format:")) continue
            val fields = line.substring("format:".length)
                .split(",")
                .map { it.trim().lowercase() }
            // Only trust a well-formed Events format: Start/End present (they are what ReadOrder replaces in
            // demuxed rows) and Text declared LAST (the only field that may itself contain commas).
            if (fields.size >= 3 && fields.last() == "text" &&
                fields.contains("start") && fields.contains("end")
            ) {
                return fields.size - 2
            }
            return STANDARD_ASS_PRE_TEXT_COMMAS
        }
        return STANDARD_ASS_PRE_TEXT_COMMAS
    }

    // MARK: - Metadata

    /** The lowercased ISO language code from a track's language metadata, or "und". */
    private fun languageTag(format: MediaFormat): String {
        val raw = runCatching { format.getString(MediaFormat.KEY_LANGUAGE) }.getOrNull()
            ?.trim()?.lowercase() ?: return "und"
        return if (raw.isEmpty() || raw == "und") "und" else raw
    }

    // MARK: - Cue assembly (pure, JVM-testable)

    /**
     * Accumulates cues for one subtitle track and serializes to SRT or WebVTT. Public within the module so the
     * serialization is unit-tested directly. The [mime] and [assPreTextCommas] ride along so [drainSamples] can
     * decode each sample without re-reading the track format.
     */
    internal class CueBuilder(
        val lang: String,
        val mime: String,
        val assPreTextCommas: Int,
    ) {
        private val cues = mutableListOf<Cue>()

        fun add(startMs: Long, endMs: Long, text: String) {
            cues.add(Cue(startMs = maxOf(0L, startMs), endMs = maxOf(startMs, endMs), text = text))
        }

        /** Serialize accumulated cues to an SRT (or VTT) string, sorted by start time. Mirrors Apple `finish`. */
        fun finish(preferVTT: Boolean): ExtractedTrack {
            val ordered = cues.sortedBy { it.startMs }
            val format = if (preferVTT) "vtt" else "srt"
            val body = if (preferVTT) serializeVtt(ordered) else serializeSrt(ordered)
            return ExtractedTrack(lang = lang, format = format, srt = body, cueCount = ordered.size)
        }
    }

    /** One cue on the extracted timeline, in milliseconds. */
    internal data class Cue(val startMs: Long, val endMs: Long, val text: String)

    /** Serialize cues to an SRT document. Pure; the byte-for-byte twin of Apple's `serializeSRT`. */
    internal fun serializeSrt(ordered: List<Cue>): String {
        val out = StringBuilder()
        for ((i, cue) in ordered.withIndex()) {
            out.append(i + 1).append("\n")
            out.append(srtTime(cue.startMs)).append(" --> ").append(srtTime(cue.endMs)).append("\n")
            out.append(cue.text).append("\n\n")
        }
        return out.toString()
    }

    /** Serialize cues to a WebVTT document. Pure; the byte-for-byte twin of Apple's `serializeVTT`. */
    internal fun serializeVtt(ordered: List<Cue>): String {
        val out = StringBuilder("WEBVTT\n\n")
        for (cue in ordered) {
            out.append(vttTime(cue.startMs)).append(" --> ").append(vttTime(cue.endMs)).append("\n")
            out.append(cue.text).append("\n\n")
        }
        return out.toString()
    }

    /** SRT timestamp `HH:MM:SS,mmm`. */
    internal fun srtTime(ms: Long): String {
        val (h, m, s, milli) = hms(ms)
        return "%02d:%02d:%02d,%03d".format(h, m, s, milli)
    }

    /** WebVTT timestamp `HH:MM:SS.mmm`. */
    internal fun vttTime(ms: Long): String {
        val (h, m, s, milli) = hms(ms)
        return "%02d:%02d:%02d.%03d".format(h, m, s, milli)
    }

    private data class Hms(val h: Int, val m: Int, val s: Int, val ms: Int)

    private fun hms(ms: Long): Hms {
        val clamped = maxOf(0L, ms)
        val milli = (clamped % 1000).toInt()
        val totalSecs = clamped / 1000
        return Hms((totalSecs / 3600).toInt(), ((totalSecs % 3600) / 60).toInt(), (totalSecs % 60).toInt(), milli)
    }
}
