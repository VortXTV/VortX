package com.vortx.android.player

import com.vortx.android.model.SubtitleRequestMetadata
import java.net.ServerSocket
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SubtitleAddonHttpTest {
    private fun withServer(status: Int = 200, block: suspend (SubtitleAddonSource, List<String>) -> Unit) = runBlocking {
        val paths = CopyOnWriteArrayList<String>()
        val server = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        val worker = thread(isDaemon = true, name = "subtitle-http-fixture") {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: java.net.SocketException) { break }
                socket.use {
                    socket.soTimeout = 4_000
                    val reader = socket.getInputStream().bufferedReader()
                    val path = reader.readLine().split(' ')[1]
                    paths += path
                    while (!reader.readLine().isNullOrEmpty()) { /* request headers */ }
                    val code = if (status in listOf(404, 405) && !path.contains("/filename=")) 200 else status
                    val bytes = """{"subtitles":[{"url":"https://cdn.invalid/en.srt","lang":"eng","subtitleFileName":"Matched release"},9,{"url":null},{"url":17},{"url":"https://cdn.invalid/other.srt","lang":8,"subtitleFileName":8}]}""".toByteArray()
                    val output = socket.getOutputStream()
                    output.write("HTTP/1.1 $code Fixture\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    output.write(bytes)
                    output.flush()
                }
            }
        }
        try {
            block(SubtitleAddonSource("http://127.0.0.1:${server.localPort}", "Fixture"), paths)
        } finally { server.close(); worker.join(1_000) }
    }

    @Test fun exactFileRequestSurvivesPartialMalformedRows() = withServer { source, paths ->
        val rows = SubtitleAddonService.fetch(listOf(source), "series", "tt123:1:9",
            SubtitleRequestMetadata("Episode 9 & #1/%?.mkv", "0123456789abcdef", 6_750_000_000L))
        assertEquals(listOf("/subtitles/series/tt123:1:9/videoHash=0123456789abcdef&videoSize=6750000000&filename=Episode%209%20%26%20%231%2F%25%3F.mkv.json"), paths)
        assertEquals(2, rows.size)
        assertEquals("Fixture · Matched release", rows[0].displayTitle)
        assertEquals("und", rows[1].lang)
        assertEquals("Fixture", rows[1].displayTitle)
    }

    @Test fun legacyRouterGetsOnlyOneBoundedRouteFallback() {
        for (status in listOf(404, 405)) withServer(status) { source, paths ->
            val rows = SubtitleAddonService.fetch(listOf(source), "movie", "tt123", SubtitleRequestMetadata(filename = "a.mkv"))
            assertEquals(listOf("/subtitles/movie/tt123/filename=a.mkv.json", "/subtitles/movie/tt123.json"), paths)
            assertEquals(2, rows.size)
        }
    }

    @Test fun serverFailureDoesNotRetryAnIdOnlyRoute() = withServer(502) { source, paths ->
        val rows = SubtitleAddonService.fetch(listOf(source), "movie", "tt123", SubtitleRequestMetadata(filename = "a.mkv"))
        assertTrue(rows.isEmpty())
        assertEquals(1, paths.size)
    }
}
