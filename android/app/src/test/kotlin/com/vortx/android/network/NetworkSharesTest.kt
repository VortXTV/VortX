package com.vortx.android.network

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import kotlin.concurrent.thread
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Network shares, the same cases as Apple `NetworkSharesTests` + `NetworkShareClientLiveTests`. */
class NetworkSharesTest {
    // Addresses and credential scoping

    @Test fun `addresses are normalized and unsafe ones refused`() {
        assertEquals("http://nas.local:5005/video/", NetworkSharePolicy.rootUrl("nas.local:5005/video"))
        assertEquals("https://NAS.local/dav/", NetworkSharePolicy.rootUrl(" https://NAS.local/dav/ "))
        assertEquals("http://192.168.1.20/", NetworkSharePolicy.rootUrl("192.168.1.20"))
        assertNull(NetworkSharePolicy.rootUrl("http://me:secret@nas.local/"))
        assertNull(NetworkSharePolicy.rootUrl("smb://nas.local/video"))
        assertNull(NetworkSharePolicy.rootUrl("file:///etc/"))
        assertNull(NetworkSharePolicy.rootUrl("http://nas.local/?a=1"))
        assertNull(NetworkSharePolicy.rootUrl("   "))
    }

    @Test fun `the login goes only to files inside the share`() {
        val root = "https://nas.local:5006/video/"
        assertEquals(mapOf("Authorization" to "Basic bWU6cHc="),
            NetworkSharePolicy.headers("https://nas.local:5006/video/Films/a.mkv", root, "me", "pw"))
        for (outside in listOf("https://evil.example/video/a.mkv", "https://nas.local:5001/video/a.mkv",
                "http://nas.local:5006/video/a.mkv", "https://nas.local:5006/videos/a.mkv")) {
            assertTrue(outside, NetworkSharePolicy.headers(outside, root, "me", "pw").isEmpty())
        }
        assertFalse(NetworkSharePolicy.isInside("https://nas.local:5006/video/../photos/x.jpg", root))
        assertTrue(NetworkSharePolicy.headers("https://nas.local:5006/video/a.mkv", root, "", "").isEmpty())
        assertTrue(NetworkSharePolicy.isInside("http://nas.local:80/v/a.mkv", "http://nas.local/v/"))
    }

    // SMB

    @Test fun `SMB addresses are normalized, Windows paths accepted and logins refused`() {
        assertEquals("smb://nas.local/Movies/", NetworkSharePolicy.smbRootUrl(" smb://nas.local/Movies "))
        assertEquals("smb://NAS/Movies/Kids/", NetworkSharePolicy.smbRootUrl("\\\\NAS\\Movies\\Kids"))
        assertEquals("smb://nas:4455/My%20Movies/", NetworkSharePolicy.smbRootUrl("SMB://nas:4455/My Movies"))
        assertEquals("smb://192.168.1.20/", NetworkSharePolicy.smbRootUrl("smb://192.168.1.20"))
        for (refused in listOf("smb://me:secret@nas/Movies", "smb://me@nas/Movies", "http://nas/Movies", "nas/Movies", "smb:///Movies"))
            assertNull(refused, NetworkSharePolicy.smbRootUrl(refused))
        // As on Apple, "?" and "#" are escaped into the folder name, so an address never carries a query.
        assertEquals("smb://nas/Movies%3Fx=1/", NetworkSharePolicy.smbRootUrl("smb://nas/Movies?x=1"))
        assertNull(NetworkSharePolicy.rootUrl("smb://nas.local/Movies"))
    }

    @Test fun `SMB locations name the share and path, and listings stay inside the folder`() {
        assertEquals(SmbLocation("nas", 445, "Movies", "Kids\\Up (2009).mkv"), NetworkSharePolicy.smbLocation("smb://nas/Movies/Kids/Up%20(2009).mkv"))
        assertEquals(SmbLocation("nas", 4455, null, ""), NetworkSharePolicy.smbLocation("smb://nas:4455/"))
        assertNull(NetworkSharePolicy.smbLocation("smb://nas/Movies/../Photos/"))
        assertNull(NetworkSharePolicy.smbLocation("https://nas/Movies/"))
        val directory = "smb://nas/Movies/Kids/"
        val entries = NetworkSharePolicy.smbEntries(listOf("." to true, ".." to true, "Up (2009).mkv" to false, "Season 1" to true,
            "a/b.mkv" to false, "50% off?.mp4" to false, "notes.txt" to false, ".hidden.mkv" to false), directory)
        assertEquals(listOf("smb://nas/Movies/Kids/Up%20(2009).mkv", "smb://nas/Movies/Kids/Season%201/",
            "smb://nas/Movies/Kids/50%25%20off%3F.mp4", "smb://nas/Movies/Kids/notes.txt", "smb://nas/Movies/Kids/.hidden.mkv"), entries.map { it.url })
        assertEquals(listOf("Season 1", "50% off?.mp4", "Up (2009).mkv"), NetworkSharePolicy.visible(entries).map { it.name })
        assertTrue(entries.all { NetworkSharePolicy.isInside(it.url, "smb://nas/Movies/") })
        assertTrue(NetworkSharePolicy.isInside("smb://nas:445/Movies/a.mkv", "smb://nas/Movies/"))
        assertFalse(NetworkSharePolicy.isInside("smb://nas:4455/Movies/a.mkv", "smb://nas/Movies/"))
        assertFalse(NetworkSharePolicy.isInside("smb://other/Movies/a.mkv", "smb://nas/Movies/"))
        assertEquals("SMB", NetworkShareKind.fromStorage("smb")?.label)
    }

    @Test fun `SMB logins never fall back to guest and split a domain`() {
        assertTrue(NetworkShareSmbClient.authentication(NetworkShareClient.Login("", "")).isGuest)
        val domain = NetworkShareSmbClient.authentication(NetworkShareClient.Login("HOME\\dad", "pw"))
        assertEquals("dad", domain.username); assertEquals("HOME", domain.domain); assertEquals("pw", String(domain.password))
        val plain = NetworkShareSmbClient.authentication(NetworkShareClient.Login("dad", "pw"))
        assertEquals("dad", plain.username); assertFalse(plain.isGuest)
    }

    @Test fun `SMB byte ranges follow the HTTP rules players rely on`() {
        assertEquals(0L until 100L, NetworkShareSmbRelay.byteRange(null, 100))
        assertEquals(10L..19L, NetworkShareSmbRelay.byteRange("bytes=10-19", 100))
        assertEquals(90L..99L, NetworkShareSmbRelay.byteRange("bytes=90-", 100))
        assertEquals(95L..99L, NetworkShareSmbRelay.byteRange("bytes=-5", 100))
        assertEquals(0L..99L, NetworkShareSmbRelay.byteRange("bytes=-500", 100))
        assertEquals(50L..99L, NetworkShareSmbRelay.byteRange("bytes=50-5000", 100))
        for (bad in listOf("bytes=100-", "bytes=20-10", "bytes=0-1,5-9", "items=0-1", "bytes=-0", "bytes=x-"))
            assertNull(bad, NetworkShareSmbRelay.byteRange(bad, 100))
        assertEquals("video/x-matroska", NetworkShareSmbRelay.contentType("Up.MKV"))
    }

    /** An in-memory SMB file that records whether every handle it gave out was closed. */
    private class FakeFile(val bytes: ByteArray) : SmbFileSource {
        @Volatile var closed = false
        override val size: Long get() = bytes.size.toLong()
        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            if (offset >= bytes.size) return -1
            val count = minOf(length, bytes.size - offset.toInt())
            System.arraycopy(bytes, offset.toInt(), buffer, 0, count)
            return count
        }
        override fun close() { closed = true }
    }

    private fun relayRequest(address: String, method: String = "GET", range: String? = null): Triple<Int, Map<String, String>, ByteArray> {
        val url = java.net.URL(address)
        Socket(url.host, url.port).use { socket ->
            val request = buildString {
                append("$method ${url.path} HTTP/1.1\r\nHost: 127.0.0.1\r\n")
                range?.let { append("Range: $it\r\n") }
                append("\r\n")
            }
            socket.getOutputStream().write(request.toByteArray())
            val raw = socket.getInputStream().readBytes()
            val split = (0 until raw.size - 3).first { raw[it] == '\r'.code.toByte() && raw[it + 1] == '\n'.code.toByte() && raw[it + 2] == '\r'.code.toByte() && raw[it + 3] == '\n'.code.toByte() }
            val lines = String(raw, 0, split).split("\r\n")
            val headers = lines.drop(1).associate { it.substringBefore(':').lowercase() to it.substringAfter(':').trim() }
            return Triple(lines.first().split(' ')[1].toInt(), headers, raw.copyOfRange(split + 4, raw.size))
        }
    }

    @Test fun `the SMB relay streams ranges on loopback behind an expiring token without the login`() {
        val content = ByteArray(700_000) { (it % 251).toByte() }
        val opened = mutableListOf<FakeFile>()
        var clock = 1_000L
        val relay = NetworkShareSmbRelay({ FakeFile(content).also { opened += it } }, now = { clock })
        try {
            val location = NetworkSharePolicy.smbLocation("smb://nas/Movies/Up%20(2009).mkv")!!
            val address = relay.address(SmbTarget(location, NetworkShareClient.Login("dad", "s3cret"), "Up (2009).mkv"))!!
            assertTrue(address, address.startsWith("http://127.0.0.1:") && address.endsWith("/Up%20(2009).mkv"))
            assertFalse(address.contains("dad") || address.contains("s3cret"))

            val whole = relayRequest(address)
            assertEquals(200, whole.first); assertEquals("700000", whole.second["content-length"]); assertEquals("bytes", whole.second["accept-ranges"])
            assertTrue(whole.third.contentEquals(content))
            val part = relayRequest(address, range = "bytes=300000-300099")
            assertEquals(206, part.first); assertEquals("bytes 300000-300099/700000", part.second["content-range"])
            assertTrue(part.third.contentEquals(content.copyOfRange(300_000, 300_100)))
            val tail = relayRequest(address, range = "bytes=-10")
            assertTrue(tail.third.contentEquals(content.copyOfRange(699_990, 700_000)))
            val head = relayRequest(address, "HEAD")
            assertEquals(200, head.first); assertEquals("700000", head.second["content-length"]); assertEquals(0, head.third.size)
            val beyond = relayRequest(address, range = "bytes=900000-")
            assertEquals(416, beyond.first); assertEquals("bytes */700000", beyond.second["content-range"])
            assertEquals(405, relayRequest(address, "POST").first)
            assertEquals(404, relayRequest(address.replaceAfterLast(":", address.substringAfterLast(":").substringBefore('/') + "/" + "0".repeat(32) + "/x.mkv")).first)
            Thread.sleep(50)
            assertTrue("every opened file is closed", opened.isNotEmpty() && opened.all { it.closed })
            clock += 13L * 60 * 60 * 1000
            assertEquals("an expired token opens nothing", 404, relayRequest(address).first)
        } finally {
            relay.close()
        }
    }

    // Listings

    @Test fun `WebDAV listings keep only direct children inside the share`() {
        val root = "https://nas.local:5006/video/"
        val directory = "https://nas.local:5006/video/Films/"
        val body = """<?xml version="1.0" encoding="UTF-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/video/Films/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>/video/Films/Dune%20Part%20Two%20(2024)/</D:href><D:propstat><D:prop><D:displayname>Dune Part Two (2024)</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>https://nas.local:5006/video/Films/Arrival.2016.1080p.mkv</D:href><D:propstat><D:prop><D:getcontentlength>8123456789</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>/video/Films/poster.jpg</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>/video/Films/.DS_Store</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>/video/Films/Raw Name [1080p].mp4</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>https://evil.example/video/Films/x.mkv</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>/photos/private.mkv</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>/video/Films/Deep/Nested/x.mkv</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
            </D:multistatus>"""
        val parsed = requireNotNull(NetworkSharePolicy.parseWebDav(body, directory, root))
        assertEquals(5, parsed.size)
        val shown = NetworkSharePolicy.visible(parsed)
        assertEquals(listOf("Dune Part Two (2024)", "Arrival.2016.1080p.mkv", "Raw Name [1080p].mp4"), shown.map { it.name })
        assertTrue(shown[0].isFolder)
        assertEquals(8_123_456_789L, shown[1].size)
        assertEquals("https://nas.local:5006/video/Films/Raw%20Name%20%5B1080p%5D.mp4", shown[2].url)
        assertNull(NetworkSharePolicy.parseWebDav("<html><body>Login</body></html>", directory, root))
        assertNull(NetworkSharePolicy.parseWebDav("""<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><multistatus xmlns="DAV:">&e;</multistatus>""", directory, root))
        assertNull(NetworkSharePolicy.parseWebDav("""<?xml version="1.0"?><!doctype m [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;">]><multistatus xmlns="DAV:"><response><href>&b;</href></response></multistatus>""", directory, root))
        val utf16Declared = """<?xml version="1.0" encoding="UTF-16"?><multistatus xmlns="DAV:"><response><href>/video/Films/a.mkv</href><propstat><prop><resourcetype/></prop></propstat></response></multistatus>"""
        assertEquals("a declared encoding cannot change what the parser reads",
            listOf("a.mkv"), NetworkSharePolicy.parseWebDav(utf16Declared, directory, root)?.map { it.name })
        assertNull(NetworkSharePolicy.parseWebDav("<\u0000!\u0000D\u0000O\u0000C", directory, root))
        val unprefixed = """<multistatus xmlns="DAV:"><response><href>/video/Films/a.mkv</href><propstat><prop><resourcetype/></prop></propstat></response></multistatus>"""
        assertEquals(listOf("a.mkv"), NetworkSharePolicy.parseWebDav(unprefixed, directory, root)?.map { it.name })
    }

    @Test fun `web folder listings from nginx, Apache and python`() {
        val root = "http://192.168.1.20:8080/media/"
        val nginx = """<html><body><pre><a href="../">../</a>
            <a href="Shows/">Shows/</a>
            <a href="The%20Matrix%20(1999).mkv">The Matrix (1999).mkv</a>
            <a href="notes.txt">notes.txt</a></pre></body></html>"""
        assertEquals(listOf("Shows", "The Matrix (1999).mkv"),
            NetworkSharePolicy.visible(NetworkSharePolicy.parseHtmlIndex(nginx, root, root)).map { it.name })
        val apache = """<a href="?C=N;O=D">Name</a><a href="/">Parent Directory</a><a href="Movies/">Movies/</a>
            <a href="/media/clip.MP4">clip.MP4</a><a href="http://other.example/media/x.mkv">x</a><a href="Movies/inner.mkv">i</a>"""
        assertEquals(listOf("Movies", "clip.MP4"),
            NetworkSharePolicy.visible(NetworkSharePolicy.parseHtmlIndex(apache, root, root)).map { it.name })
        val python = """<ul><li><a href="Season%201/">Season 1/</a></li><li><a href='E01.mkv'>E01.mkv</a></li><li><a href="E01.mkv">dup</a></li></ul>"""
        val entries = NetworkSharePolicy.parseHtmlIndex(python, root, root)
        assertEquals(listOf("Season 1", "E01.mkv"), entries.map { it.name })
        assertTrue(entries[0].isFolder && entries[0].url.endsWith("/media/Season%201/"))
    }

    @Test fun `episodes sort in natural order`() {
        val names = listOf("E10.mkv", "E2.mkv", "e1.mkv")
        assertEquals(listOf("e1.mkv", "E2.mkv", "E10.mkv"),
            NetworkSharePolicy.visible(names.map { NetworkShareEntry(it, "http://h/$it", false, null) }).map { it.name })
    }

    // The client against a local fixture server

    private lateinit var server: ServerSocket
    private var port = 0
    private val auth = "Basic " + Base64.getEncoder().encodeToString("me:pw".toByteArray())
    private val tree = mapOf(
        "/dav/" to listOf("Films/", "Arrival (2016).mkv", "poster.jpg"),
        "/dav/Films/" to listOf("Dune Part Two.mkv"),
        "/web/" to listOf("Shows/", "The Matrix (1999).mp4", "notes.txt"),
        "/web/Shows/" to listOf("S01E01.mkv"),
    )

    /** A minimal HTTP/1.1 fixture (one request per connection): the JDK server is not on the Android test classpath. */
    @Before fun startServer() {
        server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        port = server.localPort
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { socket.use { serve(it) } }
            }
        }
    }

    @After fun stopServer() = server.close()

    private fun serve(socket: Socket) {
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.ISO_8859_1))
        val requestLine = reader.readLine() ?: return
        val headers = HashMap<String, String>()
        while (true) {
            val line = reader.readLine() ?: break
            if (line.isEmpty()) break
            headers[line.substringBefore(':').trim().lowercase()] = line.substringAfter(':').trim()
        }
        repeat(headers["content-length"]?.toIntOrNull() ?: 0) { reader.read() }
        val (method, target) = requestLine.split(' ').let { it[0] to it[1] }
        val (status, body, extra) = route(method, URLDecoder.decode(target.substringBefore('?'), "UTF-8"), headers["authorization"],
            headers["range"])
        val bytes = if (method == "HEAD") ByteArray(0) else body.toByteArray()
        val head = buildString {
            append("HTTP/1.1 $status X\r\n")
            extra.forEach { (k, v) -> append("$k: $v\r\n") }
            append("Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n")
        }
        socket.getOutputStream().apply { write(head.toByteArray(Charsets.ISO_8859_1)); write(bytes); flush() }
    }

    private fun route(method: String, path: String, authorization: String?, range: String?): Triple<Int, String, Map<String, String>> {
        // Video files for the playback probe; /dav/ refuses HEAD so the client falls back to a ranged GET.
        if (path == "/web/moved.mkv") return Triple(302, "", mapOf("Location" to "/web/The%20Matrix%20(1999).mp4"))
        if (path == "/web/go-away.mkv") return Triple(302, "", mapOf("Location" to "http://elsewhere.invalid/x.mkv"))
        if (path == "/web/The Matrix (1999).mp4" || path == "/dav/Arrival (2016).mkv") {
            if (authorization != auth) return Triple(401, "", emptyMap())
            if (method == "HEAD" && path.startsWith("/dav/")) return Triple(405, "", emptyMap())
            return if (range == "bytes=0-0") Triple(206, "0", emptyMap()) else Triple(200, "0123456789", emptyMap())
        }
        if (path == "/dav/away/") return Triple(302, "", mapOf("Location" to "http://elsewhere.invalid/dav/"))
        if (path == "/web/hop/") return Triple(302, "", mapOf("Location" to "/web/Shows/"))
        val dav = path.startsWith("/dav/")
        if ((method == "PROPFIND") != dav) return Triple(405, "", emptyMap())
        if (authorization != auth) return Triple(401, "", emptyMap())
        val children = tree[path] ?: return Triple(404, "", emptyMap())
        return if (dav) {
            val rows = children.joinToString("") { name ->
                val folder = name.endsWith("/")
                "<D:response><D:href>${path}${name.replace(" ", "%20")}</D:href><D:propstat><D:prop><D:resourcetype>" +
                    (if (folder) "<D:collection/>" else "") + "</D:resourcetype></D:prop></D:propstat></D:response>"
            }
            Triple(207, """<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">$rows</D:multistatus>""", emptyMap())
        } else {
            val links = children.joinToString("\n") { "<a href=\"${it.replace(" ", "%20")}\">$it</a>" }
            Triple(200, "<html><body><pre><a href=\"../\">../</a>\n$links</pre></body></html>", emptyMap())
        }
    }

    @Test fun `the client detects, lists and keeps the login inside the share`() = runBlocking {
        val client = NetworkShareClient()
        val good = NetworkShareClient.Login("me", "pw")
        val dav = requireNotNull(NetworkSharePolicy.rootUrl("127.0.0.1:$port/dav"))
        val web = requireNotNull(NetworkSharePolicy.rootUrl("127.0.0.1:$port/web"))
        assertEquals(NetworkShareKind.WEBDAV, client.detect(dav, good))
        assertEquals(NetworkShareKind.HTTP, client.detect(web, good))
        assertEquals(NetworkShareException.Reason.UNAUTHORIZED,
            runCatching { client.detect(dav, NetworkShareClient.Login("me", "nope")) }.exceptionOrNull().let { (it as? NetworkShareException)?.reason })
        assertEquals(NetworkShareException.Reason.UNREACHABLE,
            runCatching { client.detect("http://127.0.0.1:1/x/", good) }.exceptionOrNull().let { (it as? NetworkShareException)?.reason })
        val davRoot = client.list(dav, NetworkShareKind.WEBDAV, dav, good)
        assertEquals(listOf("Films", "Arrival (2016).mkv"), davRoot.map { it.name })
        assertEquals(listOf("Dune Part Two.mkv"), client.list(davRoot[0].url, NetworkShareKind.WEBDAV, dav, good).map { it.name })
        assertEquals(listOf("Shows", "The Matrix (1999).mp4"), client.list(web, NetworkShareKind.HTTP, web, good).map { it.name })
        assertEquals(listOf("S01E01.mkv"), client.list("${web}hop/", NetworkShareKind.HTTP, web, good).map { it.name })
        assertEquals(NetworkShareException.Reason.NOT_A_SHARE,
            runCatching { client.list("${dav}away/", NetworkShareKind.WEBDAV, dav, good) }.exceptionOrNull().let { (it as? NetworkShareException)?.reason })

        // Playback: the player only ever gets an address inside the share.
        val matrix = "${web}The%20Matrix%20(1999).mp4"
        assertEquals(matrix, client.resolveForPlayback(matrix, web, good))
        assertEquals(matrix, client.resolveForPlayback("${web}moved.mkv", web, good))
        assertEquals(NetworkShareException.Reason.REDIRECTED_AWAY,
            runCatching { client.resolveForPlayback("${web}go-away.mkv", web, good) }.exceptionOrNull().let { (it as? NetworkShareException)?.reason })
        val arrival = "${dav}Arrival%20(2016).mkv"
        assertEquals(arrival, client.resolveForPlayback(arrival, dav, good))
        assertEquals(NetworkShareException.Reason.UNAUTHORIZED,
            runCatching { client.resolveForPlayback(matrix, web, NetworkShareClient.Login("me", "nope")) }.exceptionOrNull().let { (it as? NetworkShareException)?.reason })
    }
}
