package com.vortx.android.home

import java.io.ByteArrayOutputStream
import java.io.InputStream

// Bounds the public Cinemeta editorial response before JSON parsing. Card selection is separate.
internal const val MAX_CURATED_CATALOG_BYTES = 2 * 1024 * 1024

/** The caller owns/ closes [input]. Read at most the byte budget plus one overflow probe.
 * Unknown or inaccurate Content-Length headers cannot bypass this streamed limit. */
internal fun readCuratedCatalogBody(
    input: InputStream,
    maximumBytes: Int = MAX_CURATED_CATALOG_BYTES,
    checkActive: () -> Unit = {},
): ByteArray? {
    require(maximumBytes in 1..MAX_CURATED_CATALOG_BYTES)
    val buffer = ByteArray(minOf(8_192, maximumBytes + 1))
    val output = ByteArrayOutputStream(minOf(8_192, maximumBytes))
    var total = 0
    while (true) {
        checkActive()
        val count = input.read(buffer, 0, minOf(buffer.size, maximumBytes - total + 1))
        checkActive()
        if (count < 0) return output.toByteArray()
        // A non-progressing stream must not spin indefinitely.
        if (count == 0 || count > maximumBytes - total) return null
        output.write(buffer, 0, count)
        total += count
    }
}
