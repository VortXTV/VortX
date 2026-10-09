package com.vortx.android.downloads

import okhttp3.HttpUrl
import java.io.IOException

internal class HlsOfflineException(message: String) : IOException(message)

internal data class HlsOfflineByteRange(val offset: Long, val length: Long) {
    val endInclusive: Long get() = offset + length - 1
}

internal enum class HlsOfflineAssetKind(val prefix: String) {
    SEGMENT("segment"), KEY("key"), MAP("map"),
}

internal data class HlsOfflineAsset(
    val url: HttpUrl,
    val range: HlsOfflineByteRange?,
    val fileName: String,
    val kind: HlsOfflineAssetKind,
)

internal sealed interface HlsOfflinePlaylist {
    data class Master(val selectedVariant: HttpUrl) : HlsOfflinePlaylist
    data class Media(val localPlaylist: String, val assets: List<HlsOfflineAsset>) : HlsOfflinePlaylist
}

/**
 * Bounded RFC 8216 VOD subset. Every supported network reference is rewritten, and unknown EXT tags
 * fail closed. In particular, selecting only a video variant of an external-audio master is unsafe.
 * Byte-range resources become standalone local files, so their range tags must not survive rewriting.
 */
internal object HlsOfflinePlaylistParser {
    const val MAX_PLAYLIST_BYTES = 1024 * 1024
    const val MAX_SEGMENTS = 10_000
    const val MAX_ASSETS = 30_000
    private const val MAX_LINE_LENGTH = 8192

    fun parse(text: String, base: HttpUrl): HlsOfflinePlaylist {
        checkHls(text.toByteArray(Charsets.UTF_8).size <= MAX_PLAYLIST_BYTES, "HLS playlist is too large")
        checkHls(text.none { (it.code < 32 && it != '\r' && it != '\n') || it.code == 127 }, "Invalid HLS control character")
        val lines = text.replace("\r\n", "\n").split('\n')
        checkHls(lines.firstOrNull() == "#EXTM3U", "Missing HLS header")
        checkHls(lines.all { it.length <= MAX_LINE_LENGTH && '\r' !in it }, "Invalid HLS line")
        checkHls(lines.count { it == "#EXTM3U" } == 1, "Duplicate HLS header")
        checkHls(lines.count { it.startsWith("#EXT-X-VERSION:") } <= 1, "Duplicate HLS version")
        val master = lines.any { it.startsWith("#EXT-X-STREAM-INF:") }
        return if (master) parseMaster(lines, base) else parseMedia(lines, base)
    }

    private fun parseMaster(lines: List<String>, base: HttpUrl): HlsOfflinePlaylist.Master {
        val variants = mutableListOf<Pair<Long, HttpUrl>>()
        var pendingBandwidth: Long? = null
        for (line in lines.drop(1)) {
            when {
                line.isEmpty() -> Unit
                line.startsWith("#EXT-X-VERSION:") -> version(line)
                line == "#EXT-X-INDEPENDENT-SEGMENTS" -> Unit
                line.startsWith("#EXT-X-STREAM-INF:") -> {
                    checkHls(pendingBandwidth == null, "HLS variant has no URI")
                    val attrs = attributes(line.substringAfter(':'))
                    checkHls(attrs.keys.all { it in MASTER_ATTRIBUTES }, "Unsupported HLS variant attribute")
                    checkHls(attrs.keys.none { it in setOf("AUDIO", "VIDEO", "SUBTITLES") }, "External HLS renditions are not supported offline")
                    checkHls(attrs["CLOSED-CAPTIONS"] == null || attrs["CLOSED-CAPTIONS"] == "NONE", "External HLS captions are not supported offline")
                    pendingBandwidth = decimal(attrs["BANDWIDTH"], positive = true)
                }
                line.startsWith("#EXT") -> throw HlsOfflineException("Unsupported HLS master tag: ${line.substringBefore(':')}")
                line.startsWith('#') -> Unit
                else -> {
                    val bandwidth = pendingBandwidth ?: throw HlsOfflineException("Unexpected HLS variant URI")
                    checkHls(variants.size < 128, "Too many HLS variants")
                    variants += bandwidth to resolve(base, line)
                    pendingBandwidth = null
                }
            }
        }
        checkHls(pendingBandwidth == null && variants.isNotEmpty(), "Incomplete HLS master")
        // Highest advertised bandwidth; first listed variant wins ties, making selection reproducible.
        return HlsOfflinePlaylist.Master(variants.maxBy { it.first }.second)
    }

    private fun parseMedia(lines: List<String>, base: HttpUrl): HlsOfflinePlaylist.Media {
        val output = mutableListOf("#EXTM3U")
        val assets = mutableListOf<HlsOfflineAsset>()
        val uniqueTags = mutableSetOf<String>()
        var segments = 0
        var durationPending = false
        var pendingRange: String? = null
        var previousSegment: HlsOfflineAsset? = null
        var ended = false
        var encrypted = false
        var keyHasIv = false
        fun asset(uri: String, kind: HlsOfflineAssetKind, range: HlsOfflineByteRange? = null): HlsOfflineAsset {
            checkHls(assets.size < MAX_ASSETS, "Too many HLS resources")
            val value = HlsOfflineAsset(resolve(base, uri), range, "${kind.prefix}-${assets.size.toString().padStart(6, '0')}.bin", kind)
            assets += value
            return value
        }
        for (line in lines.drop(1)) {
            if (line.isEmpty() || (line.startsWith('#') && !line.startsWith("#EXT"))) continue
            checkHls(!ended, "HLS content follows ENDLIST")
            val tag = line.substringBefore(':')
            when (tag) {
                "#EXT-X-VERSION" -> { version(line); output += line }
                "#EXT-X-TARGETDURATION", "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-DISCONTINUITY-SEQUENCE" -> {
                    checkHls(uniqueTags.add(tag) && segments == 0, "Invalid or duplicate HLS sequence/target tag")
                    decimal(line.substringAfter(':', ""), positive = tag == "#EXT-X-TARGETDURATION")
                    output += line
                }
                "#EXT-X-PLAYLIST-TYPE" -> {
                    checkHls(uniqueTags.add(tag) && line.substringAfter(':', "") in setOf("VOD", "EVENT"), "Invalid HLS playlist type")
                    output += "#EXT-X-PLAYLIST-TYPE:VOD"
                }
                "#EXTINF" -> {
                    checkHls(!durationPending && line.contains(','), "Invalid HLS segment duration")
                    val duration = line.substringAfter(':', "").substringBefore(',')
                    checkHls(duration.matches(Regex("[0-9]+(?:\\.[0-9]+)?")) && duration.toDoubleOrNull()?.let { it.isFinite() && it > 0 } == true, "Invalid HLS segment duration")
                    durationPending = true
                    output += line
                }
                "#EXT-X-BYTERANGE" -> {
                    checkHls(pendingRange == null, "Duplicate HLS byte range")
                    pendingRange = line.substringAfter(':', "")
                }
                "#EXT-X-KEY" -> {
                    val attrs = attributes(line.substringAfter(':', ""))
                    checkHls(attrs.keys.all { it in KEY_ATTRIBUTES }, "Unsupported HLS key attribute")
                    when (attrs["METHOD"]) {
                        "NONE" -> {
                            checkHls(attrs.size == 1, "Invalid unencrypted HLS key tag")
                            encrypted = false
                            keyHasIv = false
                            output += "#EXT-X-KEY:METHOD=NONE"
                        }
                        "AES-128" -> {
                            checkHls(attrs["KEYFORMAT"] in listOf(null, "identity") && attrs["KEYFORMATVERSIONS"] in listOf(null, "1"), "HLS DRM is not supported offline")
                            val iv = attrs["IV"]
                            checkHls(iv == null || iv.matches(Regex("0[xX][0-9a-fA-F]{1,32}")), "Invalid HLS key IV")
                            val key = asset(attrs["URI"] ?: throw HlsOfflineException("HLS key has no URI"), HlsOfflineAssetKind.KEY)
                            output += "#EXT-X-KEY:METHOD=AES-128,URI=\"${key.fileName}\"" + (iv?.let { ",IV=$it" } ?: "")
                            encrypted = true
                            keyHasIv = iv != null
                        }
                        else -> throw HlsOfflineException("HLS encryption method is not supported offline")
                    }
                }
                "#EXT-X-MAP" -> {
                    val attrs = attributes(line.substringAfter(':', ""))
                    checkHls(attrs.keys.all { it in setOf("URI", "BYTERANGE") }, "Unsupported HLS map attribute")
                    checkHls(!encrypted || keyHasIv, "Encrypted HLS map requires an explicit IV")
                    val range = attrs["BYTERANGE"]?.let { byteRange(it, null) }
                    val map = asset(attrs["URI"] ?: throw HlsOfflineException("HLS map has no URI"), HlsOfflineAssetKind.MAP, range)
                    output += "#EXT-X-MAP:URI=\"${map.fileName}\""
                }
                "#EXT-X-ENDLIST" -> {
                    checkHls(line == tag && !durationPending && pendingRange == null, "Incomplete HLS media playlist")
                    ended = true
                    output += line
                }
                "#EXT-X-DISCONTINUITY", "#EXT-X-INDEPENDENT-SEGMENTS" -> {
                    checkHls(line == tag, "Invalid HLS flag")
                    output += line
                }
                "#EXT-X-PROGRAM-DATE-TIME" -> {
                    checkHls(line.substringAfter(':', "").isNotEmpty(), "Invalid HLS timestamp")
                    output += line
                }
                else -> {
                    checkHls(!line.startsWith('#'), "Unsupported HLS media tag: $tag")
                    checkHls(durationPending && segments < MAX_SEGMENTS, "Missing HLS segment duration or too many segments")
                    val url = resolve(base, line)
                    val implicitOffset = previousSegment?.takeIf { it.url == url }?.range?.let {
                        checkHls(it.endInclusive < Long.MAX_VALUE, "HLS byte range overflows")
                        it.endInclusive + 1
                    }
                    val range = pendingRange?.let { byteRange(it, implicitOffset) }
                    // Cropped encrypted byte ranges can require CBC context not contained in the range.
                    checkHls(!encrypted || range == null, "Encrypted HLS byte ranges are not supported offline")
                    val segment = asset(line, HlsOfflineAssetKind.SEGMENT, range)
                    output += segment.fileName
                    previousSegment = segment
                    durationPending = false
                    pendingRange = null
                    segments++
                }
            }
        }
        checkHls(ended && segments > 0 && "#EXT-X-TARGETDURATION" in uniqueTags, "Offline HLS requires a finite ENDLIST media playlist")
        return HlsOfflinePlaylist.Media(output.joinToString("\n", postfix = "\n"), assets)
    }

    internal fun attributes(value: String): Map<String, String> {
        val result = linkedMapOf<String, String>()
        var cursor = 0
        while (cursor < value.length) {
            val equals = value.indexOf('=', cursor)
            checkHls(equals > cursor, "Invalid HLS attribute")
            val name = value.substring(cursor, equals)
            checkHls(name.matches(Regex("[A-Z0-9-]+")) && name !in result, "Invalid or duplicate HLS attribute")
            cursor = equals + 1
            checkHls(cursor < value.length, "Empty HLS attribute")
            val content: String
            if (value[cursor] == '"') {
                val end = value.indexOf('"', cursor + 1)
                checkHls(end >= 0, "Unterminated HLS attribute")
                content = value.substring(cursor + 1, end)
                cursor = end + 1
            } else {
                val end = value.indexOf(',', cursor).let { if (it < 0) value.length else it }
                content = value.substring(cursor, end)
                checkHls(content.isNotEmpty() && content.none { it.isWhitespace() || it == '"' }, "Invalid HLS attribute value")
                cursor = end
            }
            result[name] = content
            if (cursor < value.length) {
                checkHls(value[cursor] == ',' && cursor + 1 < value.length, "Invalid HLS attribute separator")
                cursor++
            }
        }
        return result
    }

    private fun version(line: String) {
        checkHls(decimal(line.substringAfter(':', ""), positive = true) <= 7, "Unsupported HLS protocol version")
    }

    private fun byteRange(value: String, implicitOffset: Long?): HlsOfflineByteRange {
        val parts = value.split('@')
        checkHls(parts.size in 1..2, "Invalid HLS byte range")
        val length = decimal(parts[0], positive = true)
        val offset = if (parts.size == 2) decimal(parts[1]) else implicitOffset
            ?: throw HlsOfflineException("HLS implicit byte range has no previous matching resource")
        checkHls(offset <= Long.MAX_VALUE - length, "HLS byte range overflows")
        return HlsOfflineByteRange(offset, length)
    }

    private fun decimal(value: String?, positive: Boolean = false): Long {
        checkHls(value != null && value.matches(Regex("[0-9]{1,19}")), "Invalid HLS integer")
        val parsed = value?.toLongOrNull() ?: throw HlsOfflineException("HLS integer overflows")
        checkHls(!positive || parsed > 0, "Invalid HLS positive integer")
        return parsed
    }

    private fun resolve(base: HttpUrl, uri: String): HttpUrl {
        checkHls(uri.isNotBlank() && uri == uri.trim() && '\\' !in uri && uri.none { it.isWhitespace() }, "Invalid HLS URI")
        val url = base.resolve(uri) ?: throw HlsOfflineException("Invalid HLS URI")
        checkHls(url.username.isEmpty() && url.password.isEmpty() && url.fragment == null, "Unsupported HLS URI credentials/fragment")
        checkHls(base.scheme != "https" || url.scheme == "https", "HLS HTTPS downgrade is forbidden")
        return url
    }

    private val KEY_ATTRIBUTES = setOf("METHOD", "URI", "IV", "KEYFORMAT", "KEYFORMATVERSIONS")
    private val MASTER_ATTRIBUTES = setOf("BANDWIDTH", "AVERAGE-BANDWIDTH", "CODECS", "RESOLUTION", "FRAME-RATE", "HDCP-LEVEL", "AUDIO", "VIDEO", "SUBTITLES", "CLOSED-CAPTIONS")
}

internal fun checkHls(condition: Boolean, message: String) {
    if (!condition) throw HlsOfflineException(message)
}
