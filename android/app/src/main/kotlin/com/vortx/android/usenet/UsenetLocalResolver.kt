package com.vortx.android.usenet

import android.content.Context
import com.vortx.android.debrid.DebridResolver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger

/// Turns a bare-NZB source into a LOCAL playable file by driving the native NNTP path (the Android
/// counterpart of Apple's `UsenetLocalResolver`, which POSTs to the embedded server's `/nzb` engine).
/// Android embeds the rqbit TORRENT server (no NNTP engine, `VortxServer`), so this lane implements the
/// NNTP fetch directly: connect to the user's provider, authenticate, `GROUP`, read each missing segment
/// with `BODY`, yEnc-decode, and assemble into a cache file the player can open as a local file.
///
/// Bounded ([maxConnections] per provider, [timeoutMs] per read) so a stalled provider fails fast and the
/// caller falls back to the TorBox usenet path exactly like Apple.
internal class UsenetLocalResolver(
    private val context: Context,
    private val credentials: UsenetProviderCredentials,
    private val timeoutMs: Int = 30_000,
) {
    class ResolveException(message: String) : Exception(message)

    suspend fun resolve(
        nzbUrl: String,
        fileMustInclude: String? = null,
        fileIdx: Int? = null,
        episode: DebridResolver.Episode? = null,
    ): NzbResult = withContext(Dispatchers.IO) {
        require(credentials.isValid) { throw ResolveException("invalid provider credentials") }

        val xml = fetchNzb(nzbUrl)
        val files = NzbParser.parse(xml).filter { it.isVideo }
        if (files.isEmpty()) throw ResolveException("no playable video file in the NZB")

        val pick = pickFile(files, fileMustInclude, fileIdx, episode)
            ?: throw ResolveException("no matching file in the NZB")

        val target = assemble(pick)
        NzbResult(
            file = target,
            subject = pick.name,
            sizeBytes = target.length(),
        )
    }

    private suspend fun assemble(file: NzbFile): File = withContext(Dispatchers.IO) {
        val segments = file.segments
        if (segments.isEmpty()) throw ResolveException("file has no segments")

        val window = credentials.maxConnections.coerceIn(1, 100)
        val index = AtomicInteger(0)
        val results = arrayOfNulls<ByteArray>(segments.size)
        val slotCount = minOf(window, segments.size)

        // Workers pull the next segment index; each opens its own NNTP connection (stateless after
        // AUTH), so no shared socket state and no write interleaving.
        val workers = (0 until slotCount).map {
            async(Dispatchers.IO) {
                while (true) {
                    val seg = index.getAndIncrement()
                    if (seg >= segments.size) break
                    results[seg] = fetchSegment(segments[seg])
                }
            }
        }
        workers.awaitAll()

        val target = cacheFile()
        BufferedOutputStream(FileOutputStream(target)).use { out ->
            for (bytes in results) {
                if (bytes == null) throw ResolveException("segment assembly gap")
                out.write(bytes)
            }
        }
        target
    }

    private suspend fun fetchSegment(segment: NzbSegment): ByteArray = withContext(Dispatchers.IO) {
        val client = NntpClient(
            host = credentials.host,
            port = credentials.port,
            username = credentials.username,
            password = credentials.password,
            useSSL = credentials.useSSL,
            timeoutMs = timeoutMs,
        )
        try {
            client.connect()
            if (segment.article.isNotEmpty()) {
                val body = client.body(segment.article)
                YencDecoder.decode(body)
            } else {
                throw ResolveException("segment has no article id")
            }
        } finally {
            client.close()
        }
    }

    private suspend fun fetchNzb(nzbUrl: String): String = withContext(Dispatchers.IO) {
        val connection = URL(nzbUrl).openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = 20_000
        connection.readTimeout = 20_000
        try {
            val code = connection.responseCode
            if (code < 200 || code >= 300) throw ResolveException("NZB fetch rejected: $code")
            val bytes = connection.inputStream.readBytes()
            val text = bytes.toString(Charsets.UTF_8)
            if (text.isBlank()) throw ResolveException("NZB fetch was empty")
            text
        } finally {
            connection.disconnect()
        }
    }

    private fun pickFile(
        files: List<NzbFile>,
        mustInclude: String?,
        fileIdx: Int?,
        episode: DebridResolver.Episode?,
    ): NzbFile? {
        if (!mustInclude.isNullOrEmpty()) {
            val re = runCatching { Regex(mustInclude, RegexOption.IGNORE_CASE) }.getOrNull()
            if (re != null) {
                files.firstOrNull { it.isVideo && re.containsMatchIn(it.name) }?.let { return it }
            }
        }
        return pickHeuristic(files, episode, fileIdx)
    }

    private fun pickHeuristic(files: List<NzbFile>, episode: DebridResolver.Episode?, fileIdx: Int?): NzbFile? {
        val pool = files.filter { it.isVideo }.ifEmpty { files }
        if (pool.isEmpty()) return null
        if (episode == null) return pool.maxByOrNull { it.declaredBytes } ?: pool.firstOrNull()
        val season = episode.season
        val num = episode.episode
        if (season >= 0 && num > 0) {
            val patterns = episodePatterns(season, num)
            val matches = pool.filter { file -> patterns.any { it.containsMatchIn(file.name) } }
            // Mirrors the debrid policy: an ambiguous multi-file match is NOT a confident pick.
            if (matches.size == 1) return matches.single()
            if (matches.isNotEmpty()) return null
        }
        return pool.maxByOrNull { it.declaredBytes }
    }

    private fun episodePatterns(season: Int, episode: Int): List<Regex> =
        listOf(
            Regex("(?<![0-9])s0*$season" + "e0*$episode(?![0-9])", RegexOption.IGNORE_CASE),
            Regex("(?<![0-9])$season" + "x0*$episode(?![0-9])", RegexOption.IGNORE_CASE),
            Regex(
                "(?<![0-9])season[ ._-]+0*$season[ ._-]+episode[ ._-]+0*$episode(?![0-9])",
                RegexOption.IGNORE_CASE,
            ),
        )

    private fun cacheFile(): File {
        val home = File(context.cacheDir, "usenet")
        if (!home.exists() && !home.mkdirs()) throw ResolveException("cache dir unavailable")
        return File(home, "vortx-nzb-${System.nanoTime()}.mkv")
    }
}

/// The result of a native usenet resolve: a playable LOCAL file the player opens directly.
internal data class NzbResult(
    val file: File,
    val subject: String,
    val sizeBytes: Long,
) {
    val url: String get() = "file://" + file.absolutePath
}