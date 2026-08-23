package com.vortx.android.usenet

import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.ByteArrayInputStream
import javax.xml.parsers.DocumentBuilderFactory

/// The parsed shape of one file inside an NZB document. An `.nzb` is XML: zero or more `<file>` elements,
/// each carrying a display name, an optional `<group>` metadata block, and a list of `<segment>` articles
/// that together reconstruct the file.
internal data class NzbFile(
    val name: String,
    val poster: String,
    val date: String,
    val subject: String,
    val group: String,
    val segments: List<NzbSegment>,
) {
    val isVideo: Boolean
        get() = VIDEO_EXTENSIONS.any { name.lowercase().endsWith(it) }

    /// Estimated size: the sum of every segment's declared bytes. Used only for the earliest-file probe;
    /// the real size comes from the NNTP SIZE response.
    val declaredBytes: Long get() = segments.sumOf { it.bytes }

    private companion object {
        val VIDEO_EXTENSIONS = listOf(
            ".mkv", ".mp4", ".avi", ".mov", ".ts", ".m2ts", ".webm", ".flv", ".mpg",
            ".mpeg", ".m4v", ".m4a",
        )
    }
}

/// One NNTP article a segment maps to (`<segment bytes=".." number="..">` inside a `<file>`).
internal data class NzbSegment(
    val subject: String,
    val bytes: Long,
    val number: Long,
    val article: String,
    val isBinary: Boolean,
)