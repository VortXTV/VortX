package com.vortx.android.sync

import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.FileTime

/** Existing-only reader for the two exact empty shapes of the legacy string-map queue. */
internal object ExistingEmptyProviderRetryBacking {
    private const val PRIMARY = "vortx_account_sync_queue.xml"
    private const val MAX_BYTES = 4096L
    private const val MAX_DIRECTORY_ENTRIES = 4096
    private const val SPACE = """[ \t\r\n]"""
    private const val XML_DECLARATION = """<\?xml[ \t]+version=(?:'1\.0'|"1\.0")[ \t]+encoding=(?:'utf-8'|"utf-8"|'UTF-8'|"UTF-8")(?:[ \t]+standalone=(?:'yes'|"yes"))?[ \t]*\?>"""
    private const val EMPTY_MAP = """(?:<map[ \t]*/>|<map>$SPACE*</map>)"""
    private const val EMPTY_STRING = """<map>$SPACE*<string[ \t]+name=(?:'queue'|"queue")>\[\]</string>$SPACE*</map>"""
    private val emptyDocument = Regex("""(?:$XML_DECLARATION)?$SPACE*(?:($EMPTY_MAP)|$EMPTY_STRING)$SPACE*""")

    internal data class Observation(
        val rootIdentity: Any,
        val directoryIdentity: Any,
        val file: Stamp,
        val document: String,
        val expectedCache: Map<String, String>,
    )

    internal data class Stamp(val identity: Any, val modified: FileTime, val size: Long)

    fun observe(root: Path): Observation? {
        val directory = root.resolve("shared_prefs")
        val path = directory.resolve(PRIMARY)
        val rootBefore = stamp(root, directory = true) ?: return null
        val directoryBefore = stamp(directory, directory = true) ?: return null
        if (!unambiguous(directory)) return null
        val file = stamp(path, directory = false)?.takeIf { it.size in 1L..MAX_BYTES } ?: return null
        val bytes = ByteArray(file.size.toInt())
        Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { input ->
            var offset = 0
            while (offset < bytes.size) {
                val read = input.read(bytes, offset, bytes.size - offset)
                if (read <= 0) return null
                offset += read
            }
            if (input.read() != -1) return null
        }
        // The known empty XML grammar is ASCII. Reject byte-order marks, malformed encoding and
        // every unsupported shape before matching, rather than accepting XML/JSON normalizations.
        if (bytes.any { it < 0 }) return null
        val document = bytes.toString(Charsets.US_ASCII)
        val parsed = emptyDocument.matchEntire(document) ?: return null
        if (!unambiguous(directory) || stamp(path, directory = false) != file ||
            stamp(directory, directory = true) != directoryBefore || stamp(root, directory = true) != rootBefore) return null
        val expected = if (parsed.groups[1] != null) emptyMap() else mapOf("queue" to "[]")
        return Observation(rootBefore.identity, directoryBefore.identity, file, document, expected)
    }

    private fun unambiguous(directory: Path): Boolean {
        var count = 0
        var primarySeen = false
        Files.newDirectoryStream(directory).use { entries ->
            for (entry in entries) {
                val name = entry.fileName.toString()
                if (++count > MAX_DIRECTORY_ENTRIES || name.startsWith("$PRIMARY.")) return false
                if (name == PRIMARY) primarySeen = true
            }
        }
        return primarySeen
    }

    private fun stamp(path: Path, directory: Boolean): Stamp? {
        val attrs = Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        if (if (directory) !attrs.isDirectory else !attrs.isRegularFile) return null
        return Stamp(attrs.fileKey() ?: return null, attrs.lastModifiedTime(), attrs.size())
    }
}
