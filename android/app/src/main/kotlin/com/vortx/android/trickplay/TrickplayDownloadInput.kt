package com.vortx.android.trickplay

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Reads at most [maxBytes] plus one overflow witness; a length header never grants extra capacity. */
internal object TrickplayDownloadInput {
    fun read(
        input: InputStream,
        maxBytes: Int,
        declaredLength: Long = -1L,
        isActive: () -> Boolean = { true },
    ): ByteArray? {
        require(maxBytes > 0 && maxBytes < Int.MAX_VALUE)
        if (declaredLength > maxBytes.toLong() || !isActive()) return null
        val output = ByteArrayOutputStream(minOf(maxBytes, 8_192))
        val buffer = ByteArray(8_192)
        while (isActive()) {
            val remaining = maxBytes - output.size()
            val count = input.read(buffer, 0, minOf(buffer.size, remaining + 1))
            if (!isActive()) return null
            if (count < 0) return output.toByteArray()
            if (count > remaining) return null
            if (count == 0) {
                // InputStream's positive-length read normally makes progress. Keep unusual wrappers
                // finite as well, without an unbounded zero-read spin.
                val byte = input.read()
                if (!isActive()) return null
                if (byte < 0) return output.toByteArray()
                if (remaining == 0) return null
                output.write(byte)
            } else {
                output.write(buffer, 0, count)
            }
        }
        return null
    }
}

/** Bounds-only admission before BitmapFactory allocates a downloaded sheet's pixels. */
internal object TrickplaySpriteGeometry {
    // Apple producers may use the fleet's maxTiles upper clamp (400), while Android uploads 80.
    // Keep those valid shared 320x180 sheets readable, with a finite ~88 MiB ARGB pixel budget.
    const val MAX_PIXELS: Long = 400L * 320L * 180L

    fun permits(
        width: Int,
        height: Int,
        frameCount: Int,
        cols: Int,
        tileW: Int,
        tileH: Int,
    ): Boolean {
        if (width <= 0 || height <= 0 || frameCount <= 0 || cols <= 0 || tileW <= 0 || tileH <= 0) return false
        if (width.toLong() * height.toLong() > MAX_PIXELS) return false
        val rows = (frameCount.toLong() + cols.toLong() - 1L) / cols.toLong()
        // The final row may be partial, and retained older sheets may include padding. Admission
        // requires every declared tile to fit, not a rescale or an invented coverage interval.
        return width.toLong() >= cols.toLong() * tileW.toLong() &&
            height.toLong() >= rows * tileH.toLong()
    }
}
