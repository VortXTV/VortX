package com.vortx.android.network

import java.net.URI
import java.util.Base64
import javax.xml.parsers.DocumentBuilderFactory
import java.io.StringReader
import org.w3c.dom.Element
import org.xml.sax.InputSource

/**
 * Network shares: folders on a NAS or computer that VortX browses and plays directly, without Plex or Jellyfin.
 * The Android twin of Apple `NetworkShares.swift`, with the same rules:
 *   - WebDAV (Synology, QNAP, TrueNAS, Nextcloud, most NAS file services)
 *   - a web server's folder listing (nginx autoindex, Apache, Caddy file_server, `python3 -m http.server`)
 *   - SMB, Windows / Mac / NAS file sharing (an Android address names its share; see [NetworkShareSmbClient])
 * Pure: no network, no storage, so the parsing and the credential scoping are tested directly.
 */
enum class NetworkShareKind(val storageValue: String, val label: String) {
    WEBDAV("webdav", "WebDAV"),
    HTTP("http", "Web folder"),
    SMB("smb", "SMB");

    companion object {
        fun fromStorage(raw: String?): NetworkShareKind? = entries.firstOrNull { it.storageValue == raw }
    }
}

/** One saved share. Non-secret, kept on this device only; the password lives in the encrypted store. */
data class NetworkShare(
    val id: String,
    val name: String,
    val kind: NetworkShareKind,
    /** The share's root folder, normalized to end in "/". */
    val url: String,
    /** Empty when the share needs no login. */
    val username: String,
    val addedAtMs: Long,
)

/** Where an smb:// address points: the server, its port, the share (null at the server root), the path inside. */
data class SmbLocation(val host: String, val port: Int, val share: String?, val path: String)

/** A folder or video inside a share. */
data class NetworkShareEntry(val name: String, val url: String, val isFolder: Boolean, val size: Long?) {
    val isVideo: Boolean get() = !isFolder && NetworkSharePolicy.isVideo(name)
}

object NetworkSharePolicy {
    private val VIDEO_EXTENSIONS = setOf(
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "webm", "wmv", "flv", "mpg", "mpeg", "ogv",
        "3gp", "vob", "divx", "iso",
    )

    fun isVideo(name: String): Boolean = name.substringAfterLast('.', "").lowercase() in VIDEO_EXTENSIONS

    /**
     * The share root for what the viewer typed: http or https with a host, no login in the address (that goes
     * in the username and password fields, never a URL), no query or fragment, ending in "/". A bare
     * "nas.local:5005/video" gets http:// added.
     */
    fun rootUrl(raw: String): String? {
        var text = raw.trim()
        if (text.isEmpty()) return null
        if (!text.startsWith("http://", ignoreCase = true) && !text.startsWith("https://", ignoreCase = true)) {
            if (text.contains("://")) return null
            text = "http://$text"
        }
        val uri = runCatching { URI(text) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        val path = uri.rawPath.orEmpty().let { if (it.endsWith("/")) it else "$it/" }
        val port = if (uri.port >= 0) ":${uri.port}" else ""
        return "$scheme://$host$port$path"
    }

    const val SMB_PORT = 445

    /**
     * The SMB root for what the viewer typed: `smb://host/share[/folder]` or a Windows path `\\host\share\folder`,
     * with no login in it (that goes in the username and password fields), normalized to end in "/".
     */
    fun smbRootUrl(raw: String): String? {
        var text = raw.trim()
        if (text.startsWith("\\\\")) text = "smb://" + text.substring(2).replace('\\', '/')
        if (!text.startsWith("smb://", ignoreCase = true)) return null
        val uri = runCatching { URI(escape(text)) }.getOrNull() ?: return null
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        val path = uri.rawPath.orEmpty().let { if (it.endsWith("/")) it else "$it/" }
        val port = if (uri.port >= 0) ":${uri.port}" else ""
        return "smb://$host$port$path"
    }

    /** The parts of an smb:// [url], with the in-share path in SMB's backslash form; null when it is not one. */
    fun smbLocation(url: String): SmbLocation? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (!uri.scheme.equals("smb", ignoreCase = true)) return null
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
        val parts = uri.path.orEmpty().split('/').filter { it.isNotEmpty() }
        if (parts.any { it == "." || it == ".." || it.contains('\\') }) return null
        return SmbLocation(host, if (uri.port >= 0) uri.port else SMB_PORT, parts.firstOrNull(), parts.drop(1).joinToString("\\"))
    }

    /** The direct children of SMB [directory] from a share listing of (name, is folder): folders end in "/". */
    fun smbEntries(items: List<Pair<String, Boolean>>, directory: String): List<NetworkShareEntry> {
        val base = runCatching { URI(directory) }.getOrNull() ?: return emptyList()
        return items.mapNotNull { (name, isFolder) ->
            if (name.isEmpty() || name == "." || name == ".." || name.contains('/') || name.contains('\\')) return@mapNotNull null
            val url = runCatching { base.resolve(escapeSegment(name) + if (isFolder) "/" else "") }.getOrNull()
                ?.toASCIIString() ?: return@mapNotNull null
            NetworkShareEntry(name, url, isFolder, null)
        }
    }

    /** One path segment percent-escaped, so a name can never add a folder, a query or a login to an address. */
    fun escapeSegment(name: String): String = buildString {
        for (byte in name.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt() and 0xff
            val ch = c.toChar()
            if (c < 0x80 && (ch.isLetterOrDigit() || ch in "-._~!$&'()*+,=@")) append(ch)
            else append('%').append("%02X".format(c))
        }
    }

    /**
     * True when [url] is the share's own server and inside its root folder. Only such URLs ever receive the
     * share's login, and only such entries are listed, so a hostile listing cannot point VortX, or the
     * viewer's password, somewhere else.
     */
    fun isInside(url: String, root: String): Boolean {
        val candidate = runCatching { URI(url) }.getOrNull() ?: return false
        val base = runCatching { URI(root) }.getOrNull() ?: return false
        if (!candidate.scheme.equals(base.scheme, ignoreCase = true)) return false
        if (!candidate.host.equals(base.host, ignoreCase = true)) return false
        if (effectivePort(candidate) != effectivePort(base)) return false
        val path = decodedPath(candidate)
        if (path.split('/').contains("..")) return false
        return path.startsWith(decodedPath(base))
    }

    /** "Basic ..." for a share with a login, null without one. */
    fun authorization(username: String, password: String): String? =
        if (username.isEmpty()) null
        else "Basic " + Base64.getEncoder().encodeToString("$username:$password".toByteArray(Charsets.UTF_8))

    /** The headers a request to [url] carries: the login only inside the share's root. */
    fun headers(url: String, root: String, username: String, password: String): Map<String, String> {
        if (!isInside(url, root)) return emptyMap()
        return authorization(username, password)?.let { mapOf("Authorization" to it) } ?: emptyMap()
    }

    /** WebDAV PROPFIND body asking only for what the browser shows. */
    const val PROPFIND_BODY = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"""

    /** The direct children of [directory] in a WebDAV multistatus response, or null when it is not one. */
    fun parseWebDav(xml: String, directory: String, root: String): List<NetworkShareEntry>? {
        // A multistatus body never needs a DOCTYPE; refusing one rules out entity expansion outright instead of
        // relying on optional parser features, which some Android parsers do not support.
        if (xml.contains("<!DOCTYPE", ignoreCase = true) || xml.contains("<!ENTITY", ignoreCase = true) || xml.contains('\u0000')) return null
        val document = runCatching {
            val factory = DocumentBuilderFactory.newInstance()
            factory.isNamespaceAware = true
            factory.isExpandEntityReferences = false
            // No DOCTYPE, no external entities: a listing is data from the network.
            runCatching { factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { factory.setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            // A character stream: the parser reads exactly the text checked above, whatever encoding the
            // body's XML declaration claims.
            factory.newDocumentBuilder().parse(InputSource(StringReader(xml)))
        }.getOrNull() ?: return null
        val top = document.documentElement ?: return null
        if (localName(top) != "multistatus") return null
        val responses = top.getElementsByTagNameNS("*", "response")
        return (0 until responses.length).mapNotNull { index ->
            val response = responses.item(index) as? Element ?: return@mapNotNull null
            val href = firstText(response, "href") ?: return@mapNotNull null
            val folder = response.getElementsByTagNameNS("*", "collection").length > 0
            val url = child(href, directory, root, folder) ?: return@mapNotNull null
            val name = firstText(response, "displayname")?.takeIf { it.isNotEmpty() } ?: lastComponent(url)
            NetworkShareEntry(name, url, folder, firstText(response, "getcontentlength")?.toLongOrNull())
        }
    }

    private val HREF = Regex("""<a\s[^>]*href\s*=\s*["']([^"']+)["']""", RegexOption.IGNORE_CASE)

    /** The direct children of [directory] linked from a web server's folder listing. */
    fun parseHtmlIndex(html: String, directory: String, root: String): List<NetworkShareEntry> {
        val seen = HashSet<String>()
        return HREF.findAll(html).mapNotNull { match ->
            val href = match.groupValues[1].replace("&amp;", "&")
            if (href.startsWith("?") || href.startsWith("#") || href.startsWith("mailto:", ignoreCase = true)) return@mapNotNull null
            val folder = href.endsWith("/")
            val url = child(href, directory, root, folder) ?: return@mapNotNull null
            if (!seen.add(url)) return@mapNotNull null
            NetworkShareEntry(lastComponent(url), url, folder, null)
        }.toList()
    }

    /** What the browser shows: folders and videos, no hidden files, folders first, then natural name order. */
    fun visible(entries: List<NetworkShareEntry>): List<NetworkShareEntry> =
        entries.filter { !it.name.startsWith(".") && (it.isFolder || it.isVideo) }
            .sortedWith(compareBy<NetworkShareEntry> { !it.isFolder }.then { a, b -> naturalCompare(a.name, b.name) })

    // Helpers

    /** [href] resolved against [directory], kept only when it is a direct child inside the share root. */
    private fun child(href: String, directory: String, root: String, isFolder: Boolean): String? {
        val parsed = runCatching { URI(href) }.getOrNull() ?: runCatching { URI(escape(href)) }.getOrNull() ?: return null
        var url = runCatching { URI(directory).resolve(parsed) }.getOrNull() ?: return null
        if (isFolder && !url.rawPath.orEmpty().endsWith("/")) {
            // String assembly, not the multi-argument URI constructor, which would re-quote existing %XX escapes.
            url = runCatching { URI("${url.scheme}://${url.rawAuthority}${url.rawPath}/") }.getOrNull() ?: url
        }
        val text = url.toASCIIString()
        if (!isInside(text, root)) return null
        val childParts = decodedPath(url).split('/').filter { it.isNotEmpty() }
        val directoryParts = decodedPath(URI(directory)).split('/').filter { it.isNotEmpty() }
        if (childParts.size != directoryParts.size + 1 || childParts.take(directoryParts.size) != directoryParts) return null
        return text
    }

    /** Escapes raw spaces and other characters some servers leave in hrefs, keeping existing %XX escapes. */
    private fun escape(href: String): String = buildString {
        for (byte in href.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt() and 0xff
            val ch = c.toChar()
            if (c < 0x80 && (ch.isLetterOrDigit() || ch in "-._~/:@!$&'()*+,;=%")) append(ch)
            else append('%').append("%02X".format(c))
        }
    }

    private fun decodedPath(uri: URI): String {
        val path = uri.path.orEmpty()
        return if (path.endsWith("/")) path else "$path/"
    }

    private fun effectivePort(uri: URI): Int = when {
        uri.port >= 0 -> uri.port
        uri.scheme.equals("https", ignoreCase = true) -> 443
        uri.scheme.equals("smb", ignoreCase = true) -> SMB_PORT
        else -> 80
    }

    private fun lastComponent(url: String): String {
        val uri = runCatching { URI(url) }.getOrNull() ?: return url
        return uri.path.orEmpty().trimEnd('/').substringAfterLast('/').ifEmpty { uri.host.orEmpty() }
    }

    private fun localName(element: Element): String = (element.localName ?: element.nodeName.substringAfter(':')).lowercase()

    private fun firstText(element: Element, local: String): String? {
        val nodes = element.getElementsByTagNameNS("*", local)
        return if (nodes.length == 0) null else nodes.item(0).textContent?.trim()
    }

    /** Finder-style ordering: digit runs compare by value, so "E2" sorts before "E10". */
    private fun naturalCompare(a: String, b: String): Int {
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            val ca = a[i]
            val cb = b[j]
            if (ca.isDigit() && cb.isDigit()) {
                val startA = i
                val startB = j
                while (i < a.length && a[i].isDigit()) i++
                while (j < b.length && b[j].isDigit()) j++
                val numA = a.substring(startA, i).trimStart('0')
                val numB = b.substring(startB, j).trimStart('0')
                if (numA.length != numB.length) return numA.length - numB.length
                val cmp = numA.compareTo(numB)
                if (cmp != 0) return cmp
            } else {
                val cmp = ca.lowercaseChar().compareTo(cb.lowercaseChar())
                if (cmp != 0) return cmp
                i++
                j++
            }
        }
        return (a.length - i) - (b.length - j)
    }
}
