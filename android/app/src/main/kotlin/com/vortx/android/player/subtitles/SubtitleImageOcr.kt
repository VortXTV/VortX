package com.vortx.android.player.subtitles

/**
 * Turn IMAGE subtitle bitmaps (HDMV PGS, DVD/VobSub) into text CUES for the community-subtitle pool. The
 * Android counterpart of Apple `app/Sources/Player/VortXPGSSubtitleOCR.swift` + `PGSOCRPolicy.swift`.
 *
 * WHY only the contribution half: both Android engines already RENDER image subtitles on screen (libmpv draws
 * PGS/VobSub bitmaps natively). What is missing versus Apple is the CONTRIBUTION path -- recognising those
 * bitmaps to UTF-8 text so we can UPLOAD them to the pool ([SubtitlePoolClient.upload], origin "embedded") for
 * a viewer on a rip that has no text subtitle in that language.
 *
 * FOSS-FLAVOR SAFETY (the load-bearing constraint, stated honestly):
 *   - The `full` flavor is the GPL/sideload product and MUST stay free of proprietary Google Play services, so
 *     ML Kit Text Recognition (the obvious on-device OCR) CANNOT be linked into `full`.
 *   - A FOSS OCR engine (Tesseract via tesseract4android) is Apache-2.0 but drags a native `.so` per ABI plus
 *     a multi-megabyte trained-data asset into BOTH flavors, for a best-effort BACKGROUND contribution that
 *     never affects what the viewer sees. That bloat is not justified for this path today.
 * So this file ships the flavor-neutral PLUMBING + a clean recognizer FLAG rather than bundling an engine:
 *   1. A pure bounds/timing POLICY that mirrors Apple `PGSOCRPolicy` byte-for-byte (rect edges, pixel caps,
 *      per-item byte caps, cue timing with the FFmpeg open-end sentinel), JVM-unit-tested.
 *   2. A pure palette-to-grayscale bitmap conversion that mirrors Apple `VortXPGSSubtitleOCR.image(from:)`, so
 *      any recognizer receives the exact same pre-processed image the Apple Vision path does.
 *   3. A pluggable [recognizerProvider] hook, ABSENT by default. A `play`-flavor source set (or any future
 *      build cleared to ship an engine) can install an ML Kit / Tesseract recognizer WITHOUT touching `full`.
 *      With no provider wired, [recognizeItem] is a fail-soft no-op and no bitmap is ever contributed.
 *
 * WHY no live bitmap feed is wired yet (the second honest divergence): Apple gets PGS bitmaps from FFmpeg's
 * subtitle decoder INSIDE its MKV->fMP4 remux producer. Android does not decode PGS/VobSub bitmaps from Kotlin
 * (that lives in the native mpv/FFmpeg engine, a separate lane); the platform [android.media.MediaExtractor]
 * surfaces the image-subtitle SAMPLES but not decoded bitmaps. So the SOURCE that would fill [ImageBitmap] is
 * engine/JNI work owned elsewhere. This module is the complete, tested consumer of such bitmaps once a feed
 * and a recognizer exist, so wiring either is additive and touches no display path.
 *
 * Bounded, fail-soft, deterministic: nothing here throws, and the policy caps mean a hostile bitmap cannot
 * balloon memory (the same caps Apple enforces before Vision ever runs).
 */
object SubtitleImageOcr {

    // MARK: - Policy bounds (byte-for-byte Apple PGSOCRPolicy)

    /** Ignore a rectangle whose shorter edge is under this; too small to carry a legible glyph. */
    const val MIN_RECT_EDGE = 8

    /** Reject a bitmap edge past this (a malformed dimension). Apple `maximumBitmapEdge`. */
    const val MAX_BITMAP_EDGE = 8_192

    /** Reject a bitmap larger than this many pixels. Apple `maximumBitmapPixels` (16 Mi). */
    const val MAX_BITMAP_PIXELS = 16 shl 20

    /** At most this many bitmaps recognised for one cue/item. Apple `maximumBitmapsPerItem`. */
    const val MAX_BITMAPS_PER_ITEM = 64

    /** At most this many bytes of bitmap indices recognised for one item. Apple `maximumBitmapBytesPerItem`. */
    const val MAX_BITMAP_BYTES_PER_ITEM = 8 shl 20

    /** A 256-entry BGRA palette is exactly this many bytes. */
    const val PALETTE_BYTES = 256 * 4

    /** True when the rectangle count is a usable, in-bounds cue. Apple `acceptsPacketRectangleCount`. */
    fun acceptsRectangleCount(count: Int): Boolean = count in 1..MAX_BITMAPS_PER_ITEM

    /**
     * Whether another bitmap of [nextBytes] index bytes may join an item that already holds [existingCount]
     * bitmaps / [existingBytes] index bytes, without breaching the per-item caps. Overflow-safe. Byte-for-byte
     * Apple `canAppendBitmap`.
     */
    fun canAppendBitmap(existingCount: Int, existingBytes: Int, nextBytes: Int): Boolean {
        if (existingCount < 0 || existingCount >= MAX_BITMAPS_PER_ITEM) return false
        if (existingBytes < 0 || existingBytes > MAX_BITMAP_BYTES_PER_ITEM) return false
        if (nextBytes <= 0) return false
        val total = existingBytes.toLong() + nextBytes.toLong()
        return total <= MAX_BITMAP_BYTES_PER_ITEM
    }

    /** The FFmpeg PGS decoder's "open until the next display event" sentinel. Apple compares against UInt32.max. */
    const val OPEN_END_SENTINEL_MS = 0xFFFF_FFFFL

    /**
     * Resolve a cue's (startSeconds, durationSeconds) from a packet's container time plus the subtitle's own
     * display offsets in ms, or null when the timing is not finite/positive. Byte-for-byte Apple
     * `PGSOCRPolicy.cueTiming`: an open-end sentinel (or an end <= start) falls back to the container packet
     * duration.
     */
    fun cueTiming(
        packetStartSeconds: Double,
        packetDurationSeconds: Double,
        displayStartMs: Long,
        displayEndMs: Long,
    ): Pair<Double, Double>? {
        if (!packetStartSeconds.isFinite() || packetStartSeconds < 0) return null
        val start = packetStartSeconds + displayStartMs / 1_000.0
        if (!start.isFinite()) return null
        val duration = if (displayEndMs != OPEN_END_SENTINEL_MS && displayEndMs > displayStartMs) {
            (displayEndMs - displayStartMs) / 1_000.0
        } else {
            packetDurationSeconds
        }
        if (!duration.isFinite()) return null
        return start to duration
    }

    // MARK: - Bitmap value + pre-processing

    /**
     * One palettized image-subtitle bitmap: 8-bit palette [indices] (row-major, [width]x[height]) plus a
     * 256-entry BGRA [paletteBGRA]. The exact shape Apple's `PGSOCRBitmap` carries out of the FFmpeg decoder.
     */
    class ImageBitmap(
        val width: Int,
        val height: Int,
        val indices: ByteArray,
        val paletteBGRA: ByteArray,
    ) {
        /** In-bounds, self-consistent, and within the per-bitmap caps. */
        fun isValid(): Boolean {
            if (width < MIN_RECT_EDGE || height < MIN_RECT_EDGE) return false
            if (width > MAX_BITMAP_EDGE || height > MAX_BITMAP_EDGE) return false
            val pixels = width.toLong() * height.toLong()
            if (pixels <= 0 || pixels > MAX_BITMAP_PIXELS) return false
            if (indices.size.toLong() != pixels) return false
            return paletteBGRA.size == PALETTE_BYTES
        }
    }

    /** A recognizer-ready 8-bit grayscale image (dark text on a light field), one byte per pixel. */
    class GrayImage(val width: Int, val height: Int, val pixels: ByteArray)

    /**
     * Composite a palettized [bitmap] over white and produce an 8-bit grayscale image, or null when the bitmap
     * is out of bounds. Byte-for-byte Apple `VortXPGSSubtitleOCR.image(from:)`: BGRA palette, Rec.601 luminance,
     * alpha composite over white, then the same inversion Apple hands Vision so glyphs read dark on light.
     */
    fun toGrayscale(bitmap: ImageBitmap): GrayImage? {
        if (!bitmap.isValid()) return null
        val pixelCount = bitmap.width * bitmap.height
        val out = ByteArray(pixelCount)
        val palette = bitmap.paletteBGRA
        val indices = bitmap.indices
        for (offset in 0 until pixelCount) {
            val paletteOffset = (indices[offset].toInt() and 0xFF) * 4
            val blue = (palette[paletteOffset].toInt() and 0xFF).toDouble()
            val green = (palette[paletteOffset + 1].toInt() and 0xFF).toDouble()
            val red = (palette[paletteOffset + 2].toInt() and 0xFF).toDouble()
            val alpha = (palette[paletteOffset + 3].toInt() and 0xFF) / 255.0
            val luminance = 0.299 * red + 0.587 * green + 0.114 * blue
            val composited = luminance * alpha + 255.0 * (1.0 - alpha)
            val value = 255.0 - composited * alpha
            out[offset] = value.coerceIn(0.0, 255.0).toInt().toByte()
        }
        return GrayImage(bitmap.width, bitmap.height, out)
    }

    // MARK: - Recognizer hook (flavor-neutral; absent by default = FOSS-safe)

    /**
     * A pluggable text recognizer. A `play`-flavor (or otherwise engine-cleared) source set installs one over
     * [recognizerProvider]; the `full` FOSS flavor leaves it null so no proprietary/heavy OCR engine is linked.
     * Returns the recognised text for one grayscale image, or null when it recognises nothing.
     */
    fun interface Recognizer {
        suspend fun recognize(image: GrayImage): String?
    }

    /**
     * The installed recognizer, or null (the default) when this build ships no OCR engine. Set once at app
     * start by a flavor-specific initializer; read live so a later install is honoured. Volatile: it may be
     * read from the background contribution coroutine while being set on the main thread.
     */
    @Volatile
    var recognizerProvider: Recognizer? = null

    /** Whether this build can OCR image subtitles at all. False on `full` unless a recognizer is installed. */
    val isAvailable: Boolean get() = recognizerProvider != null

    /**
     * Recognise one cue's bitmaps into a single newline-joined string, or null when OCR is unavailable, the
     * bitmaps are out of policy, or nothing was recognised. Fail-soft: any recognizer error drops that bitmap
     * rather than throwing. Mirrors Apple `VortXPGSSubtitleOCR.recognise` (per-bitmap recognise, join lines).
     */
    suspend fun recognizeItem(bitmaps: List<ImageBitmap>): String? {
        val recognizer = recognizerProvider ?: return null
        if (!acceptsRectangleCount(bitmaps.size)) return null
        var count = 0
        var bytes = 0
        val lines = mutableListOf<String>()
        for (bitmap in bitmaps) {
            if (!canAppendBitmap(count, bytes, bitmap.indices.size)) break
            val gray = toGrayscale(bitmap) ?: continue
            count += 1
            bytes += bitmap.indices.size
            val text = runCatching { recognizer.recognize(gray) }.getOrNull()
                ?.trim()
                ?.takeIf { it.isNotEmpty() } ?: continue
            lines.add(text)
        }
        return lines.takeIf { it.isNotEmpty() }?.joinToString("\n")
    }

    // MARK: - Cue -> SRT for pool upload

    /** One recognised image-subtitle cue on the extracted timeline, in milliseconds. */
    data class RecognizedCue(val startMs: Long, val endMs: Long, val text: String)

    /**
     * Serialize recognised image-subtitle cues into an SRT document ready for [SubtitlePoolClient.upload]
     * (origin "embedded", format "srt"), reusing the exact SRT writer the text extractor uses so pooled OCR
     * output and pooled embedded-text output are byte-identical in shape. Empty when there is nothing to upload.
     */
    fun serializeSrt(cues: List<RecognizedCue>): String {
        if (cues.isEmpty()) return ""
        val ordered = cues.sortedBy { it.startMs }
            .map { SubtitleEmbeddedExtractor.Cue(startMs = it.startMs, endMs = maxOf(it.startMs, it.endMs), text = it.text) }
        return SubtitleEmbeddedExtractor.serializeSrt(ordered)
    }
}
