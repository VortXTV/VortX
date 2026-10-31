package com.vortx.android.engine

import com.vortx.android.cast.CastEligibility
import com.vortx.android.model.Playable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class StreamingServerSelectionTest {
    private val hash = "a".repeat(40)
    private val base = "http://100.89.1.2:11470/server"

    private suspend fun resolve(selection: StreamingServerSelection, owner: () -> Boolean = { true },
        prepare: suspend (ChosenStreamingServer, String, Int) -> StreamingServerPreparedFile = { _, _, _ -> StreamingServerPreparedFile("episode.mkv") }): Playable =
        resolveSelectedStreamingServerTorrent(checkNotNull(selection.capture()), hash, 3, "episode",
            { true }, owner, prepare)

    @Test fun `saved explicit choice produces exact prepared hash route consumed by normal Cast callers`() = runBlocking {
        var persisted: String? = null
        val selection = StreamingServerSelection(null) { persisted = it; true }
        assertNull(selection.capture())
        assertTrue(selection.save("  $base/  "))
        assertEquals(base, persisted)
        var prepares = 0
        val playable = resolve(selection, prepare = { captured, preparedHash, index ->
            assertEquals(base, captured.base)
            assertEquals(hash, preparedHash)
            prepares++
            assertEquals(3, index)
            StreamingServerPreparedFile("episode.mkv")
        })
        assertEquals(1, prepares)
        assertEquals("$base/$hash/3", playable.url)
        assertEquals("video/x-matroska", CastEligibility.receiverContentType(playable))
        assertTrue(playable.isTorrent)
        assertTrue(playable.viaStreamingServer)
        assertTrue(CastEligibility.isCastable(playable)) // The actual PlayerScreen/manager call signature.
        assertFalse(CastEligibility.isCastable(Playable(playable.url, "restored", isTorrent = true, viaStreamingServer = true)))
    }

    @Test fun `selection edits and same URL ABA revoke existing receipt rather than adopting current preferences`() = runBlocking {
        val selection = StreamingServerSelection(base) { true }
        val old = resolve(selection)
        assertTrue(CastEligibility.isCastable(old))
        assertTrue(selection.save("https://192.168.1.8:8443"))
        assertFalse(CastEligibility.isCastable(old))
        assertTrue(selection.save(base))
        assertFalse(CastEligibility.isCastable(old))
        val fresh = resolve(selection)
        assertTrue(CastEligibility.isCastable(fresh))
        assertTrue(selection.useEmbedded())
        assertFalse(CastEligibility.isCastable(fresh))
        assertNull(selection.capture())
    }

    @Test fun `changing server cancels the exact active transport registration and releases completed ones`() {
        val selection = StreamingServerSelection(base) { true }
        val old = checkNotNull(selection.capture())
        var liveCancellations = 0
        var completedCancellations = 0
        old.onRetire { liveCancellations++ }
        val completed = old.onRetire { completedCancellations++ }
        completed.close()
        assertTrue(selection.save(base))
        assertEquals(1, liveCancellations)
        assertEquals(0, completedCancellations)
        old.onRetire { liveCancellations++ }
        assertEquals(2, liveCancellations)
        assertTrue(selection.useEmbedded())
        assertEquals(2, liveCancellations)
    }

    @Test fun `failed persistence cannot revoke the still saved user choice`() = runBlocking {
        val selection = StreamingServerSelection(base) { false }
        val old = resolve(selection)
        assertFalse(selection.save("https://server.example"))
        assertFalse(selection.useEmbedded())
        assertEquals(base, selection.currentBase())
        assertTrue(CastEligibility.isCastable(old))
    }

    @Test fun `source lifetime retirement rejects the carried receipt after resolution`() = runBlocking {
        var current = true
        val playable = resolve(StreamingServerSelection(base) { true }, owner = { current })
        assertTrue(CastEligibility.isCastable(playable))
        current = false
        assertFalse(CastEligibility.isCastable(playable))
    }

    @Test fun `settings change during preparation never produces a receipt for the new server`() = runBlocking {
        val selection = StreamingServerSelection(base) { true }
        try {
            resolve(selection, prepare = { _, _, _ -> selection.save("http://192.168.1.9:11470"); StreamingServerPreparedFile("episode.mkv") })
            fail("Retired selection must not publish")
        } catch (_: CancellationException) { }
        assertEquals("http://192.168.1.9:11470", selection.currentBase())
    }

    @Test fun `owner retirement during preparation cannot return playable and preparation errors propagate`() = runBlocking {
        var ownerCurrent = true
        try {
            resolve(StreamingServerSelection(base) { true }, owner = { ownerCurrent },
                prepare = { _, _, _ -> ownerCurrent = false; StreamingServerPreparedFile("episode.mkv") })
            fail("Retired source must not publish")
        } catch (_: CancellationException) { }
        try {
            resolve(StreamingServerSelection(base) { true }, prepare = { _, _, _ -> error("rejected") })
            fail("Preparation must succeed")
        } catch (expected: IllegalStateException) { assertEquals("rejected", expected.message) }
    }

    @Test fun `route receipt cannot authorize another file hash endpoint query or disabled transport`() = runBlocking {
        val playable = resolve(StreamingServerSelection(base) { true })
        for (url in listOf("$base/$hash/4", "$base/${"b".repeat(40)}/3", "$base/settings", "$base/$hash/3?token=other"))
            assertFalse(url, CastEligibility.isCastable(playable.copy(url = url)))
        assertFalse(CastEligibility.isCastable(playable.copy(viaStreamingServer = false)))
        assertFalse(CastEligibility.isCastable(playable.copy(headers = mapOf("Cookie" to "private"))))
        assertFalse(CastEligibility.isCastable(playable.copy(playbackLease = AutoCloseable { })))
    }

    @Test fun `retired original resolve admission sends no server request`() = runBlocking {
        var requests = 0
        val captured = checkNotNull(StreamingServerSelection(base) { true }.capture())
        try {
            resolveSelectedStreamingServerTorrent(captured, hash, 3, "episode", { false }, { true },
                prepare = { _, _, _ -> requests++; StreamingServerPreparedFile("episode.mkv") })
            fail("Original source admission retired")
        } catch (_: CancellationException) { }
        assertEquals(0, requests)
    }

    @Test fun `unknown file container remains locally resolved without guessing receiver MP4`() = runBlocking {
        val playable = resolve(StreamingServerSelection(base) { true },
            prepare = { _, _, _ -> StreamingServerPreparedFile("opaque.bin") })
        assertEquals("$base/$hash/3", playable.url)
        assertEquals("application/octet-stream", CastEligibility.receiverContentType(playable))
        assertFalse(CastEligibility.isCastable(playable))
    }

    @Test fun `invalid hash and index produce no server request and no ordinal guess`() = runBlocking {
        val captured = checkNotNull(StreamingServerSelection(base) { true }.capture())
        var requests = 0
        for ((badHash, badIndex) in listOf("not-a-hash" to 0, hash to -1)) {
            try {
                resolveSelectedStreamingServerTorrent(captured, badHash, badIndex, "movie", { true }, { true },
                    prepare = { _, _, _ -> requests++; StreamingServerPreparedFile("episode.mkv") })
                fail("Invalid torrent target")
            } catch (_: IllegalArgumentException) { }
        }
        assertEquals(0, requests)
        assertNull(nativeTorrentFallbackFileIndex(null, isEpisode = true))
        assertEquals(3, nativeTorrentFallbackFileIndex(3, isEpisode = true))
    }

    @Test fun `normalization permits selected LAN Tailscale prefix and HTTPS while rejecting forbidden carriers`() {
        assertEquals("http://nas.local:11470", StreamingServerSelection.normalizedBase("nas.local:11470/"))
        assertEquals(base, StreamingServerSelection.normalizedBase(base))
        assertEquals("https://server.example/stream", StreamingServerSelection.normalizedBase("https://server.example/stream/"))
        for (raw in listOf("", "ftp://server.example", "http://user:secret@nas", "http://nas?token=secret", "http://nas/#key",
            "http://127.0.0.1", "http://169.254.169.254", "http://100.100.100.200", "http://[::1]", "http://[fe80::1]",
            "http://nas/a/../b", "http://nas/%2e%2e", "http://nas/path%2fsub", "http://nas/../", "http://nas:0"))
            assertNull(raw, StreamingServerSelection.normalizedBase(raw))
    }

    @Test fun `create receipt must name the original hash and actual selected nonempty file`() {
        fun body(actualHash: String = hash, name: String = "episode.mkv", length: String = "123"): ByteArray =
            "{\"infoHash\":\"$actualHash\",\"files\":[{\"name\":\"$name\",\"length\":$length}]}".toByteArray()
        val file = StreamingServerTransport.preparedFile(200, body(), hash, 0)
        assertEquals("video/x-matroska", file?.contentType)
        assertNull(StreamingServerTransport.preparedFile(200, body(actualHash = "b".repeat(40)), hash, 0))
        assertNull(StreamingServerTransport.preparedFile(200, body(), hash, 1))
        assertNull(StreamingServerTransport.preparedFile(302, body(), hash, 0))
        assertNull(StreamingServerTransport.preparedFile(200, body(length = "0"), hash, 0))
        assertNull(StreamingServerTransport.preparedFile(200, body(length = "1.5"), hash, 0))
        assertNull(StreamingServerTransport.preparedFile(200, body(name = ""), hash, 0))
        assertNull(StreamingServerTransport.preparedFile(200, ByteArray(1048577), hash, 0))
    }

    @Test fun `settings probe recognizes body not a generic successful LAN listener`() {
        assertTrue(StreamingServerTransport.acceptsSettings(200, "{\"values\":{}}".toByteArray()))
        for ((status, body) in listOf(200 to "{}", 200 to "{\"values\":[]}", 200 to "broken", 302 to "{\"values\":{}}", 404 to "{\"values\":{}}"))
            assertFalse(StreamingServerTransport.acceptsSettings(status, body.toByteArray()))
        assertFalse(StreamingServerTransport.acceptsSettings(200, ByteArray(65537)))
    }

    @Test fun `reply preflight rejects deep structure before recursive JSONObject sees it`() {
        fun settingsAtDepth(arrayDepth: Int): ByteArray =
            ("{\"values\":{},\"extra\":" + "[".repeat(arrayDepth) + "0" + "]".repeat(arrayDepth) + "}").toByteArray()
        assertTrue(StreamingServerTransport.acceptsSettings(200, settingsAtDepth(31)))
        assertFalse(StreamingServerTransport.acceptsSettings(200, settingsAtDepth(32)))
        val nested = "[".repeat(10_000) + "0" + "]".repeat(10_000)
        assertFalse(StreamingServerTransport.acceptsSettings(200, ("{\"values\":{},\"extra\":" + nested + "}").toByteArray()))
        val create = "{\"infoHash\":\"$hash\",\"files\":[{\"name\":\"episode.mkv\",\"length\":1}],\"extra\":$nested}"
        assertNull(StreamingServerTransport.preparedFile(200, create.toByteArray(), hash, 0))
    }

    @Test fun `reply preflight bounds flat node work separately from response bytes`() {
        val wide = List(50_001) { "0" }.joinToString(",", "[", "]")
        val body = "{\"infoHash\":\"$hash\",\"files\":[{\"name\":\"episode.mkv\",\"length\":1}],\"extra\":$wide}"
        assertTrue(body.toByteArray().size < 1024 * 1024)
        assertNull(StreamingServerTransport.preparedFile(200, body.toByteArray(), hash, 0))
    }

    @Test fun `reply framing counts braces quotes and escaped backslashes in filenames as string content`() {
        val name = """scene { [ \ " ] } / café 🎬.mkv"""
        val body = org.json.JSONObject().put("infoHash", hash).put("files", org.json.JSONArray().put(
            org.json.JSONObject().put("name", name).put("length", 123)))
            .put("extra", org.json.JSONObject().put("nested", org.json.JSONArray().put(true).put(org.json.JSONObject.NULL).put(1.25)))
            .toString().toByteArray()
        assertEquals("video/x-matroska", StreamingServerTransport.preparedFile(200, body, hash, 0)?.contentType)
        assertTrue(StreamingServerTransport.acceptsSettings(200, " \r\n{\"values\":{},\"extra\":[true,false,null,-12,1.25,1e3]}\t ".toByteArray()))
    }

    @Test fun `whole reply must be one strict object without trailing or lenient JSON syntax`() {
        for (body in listOf("{\"values\":{}} {}", "{\"values\":{}}ignored", "{\"values\":{}}/*comment*/",
            "{\"values\":{},}", "{values:{}}", "{'values':{}}", "{\"values\":{};\"x\":1}",
            "{\"values\":{},\"x\":[1,]}", "{\"values\":{},\"x\":01}", "{\"values\":{},\"x\":NaN}",
            "{\"values\":{},\"x\":\"bad\\q\"}", "[{\"values\":{}}]", "{\"values\":{}"))
            assertFalse(body, StreamingServerTransport.acceptsSettings(200, body.toByteArray()))
        for (hex in listOf("١٢٣٤", "１２３４")) {
            val invalidEscape = "{\"values\":{},\"text\":\"\\u" + hex + "\"}"
            assertFalse(StreamingServerTransport.acceptsSettings(200, invalidEscape.toByteArray()))
        }
        assertTrue(StreamingServerTransport.acceptsSettings(200, "{\"values\":{},\"text\":\"\\u005b\\u007B\\u0022\\u005c\"}".toByteArray()))
        val create = "{\"infoHash\":\"$hash\",\"files\":[{\"name\":\"episode.mkv\",\"length\":1}]}"
        assertNull(StreamingServerTransport.preparedFile(200, (create + "true").toByteArray(), hash, 0))
    }

    @Test fun `reply UTF8 must be exact and byte ceilings still apply before parsing`() {
        val prefix = "{\"values\":{},\"text\":\"".toByteArray()
        val suffix = "\"}".toByteArray()
        for (invalid in listOf(byteArrayOf(0xc3.toByte(), 0x28), byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()), byteArrayOf(0xc2.toByte())))
            assertFalse(StreamingServerTransport.acceptsSettings(200, prefix + invalid + suffix))
        assertFalse(StreamingServerTransport.acceptsSettings(200, ("{\"values\":{}}" + " ".repeat(65_536)).toByteArray()))
        val create = "{\"infoHash\":\"$hash\",\"files\":[{\"name\":\"episode.mkv\",\"length\":1}],\"text\":\"".toByteArray()
        assertNull(StreamingServerTransport.preparedFile(200, create + byteArrayOf(0xc3.toByte(), 0x28) + suffix, hash, 0))
        assertNull(StreamingServerTransport.preparedFile(200, ByteArray(1_048_577), hash, 0))
    }
}
