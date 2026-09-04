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
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

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

        val window = credentials.maxConnections.coerceIn(1, MAX_SEGMENT_WORKERS)
        val index = AtomicInteger(0)
        val slotCount = minOf(window, segments.size)
        val workDir = File(context.cacheDir, "usenet/work-${System.nanoTime()}")
        if (!workDir.mkdirs()) throw ResolveException("cache work dir unavailable")
        val target = cacheFile()

        try {
            // The window bounds decoded bytes retained at once: each worker commits its segment to a private
            // disk part before pulling another job. The final writer consumes parts by index, so playback
            // file order is deterministic even though NNTP completions are not.
            val workers = (0 until slotCount).map {
                async(Dispatchers.IO) {
                    while (true) {
                        coroutineContext.ensureActive()
                        val seg = index.getAndIncrement()
                        if (seg >= segments.size) break
                        val bytes = fetchSegment(segments[seg])
                        if (bytes.size > MAX_SEGMENT_BYTES) throw ResolveException("NZB segment exceeds memory limit")
                        coroutineContext.ensureActive()
                        FileOutputStream(File(workDir, "$seg.part")).use { it.write(bytes) }
                    }
                }
            }
            workers.awaitAll()
            BufferedOutputStream(FileOutputStream(target)).use { out ->
                for (segment in segments.indices) {
                    coroutineContext.ensureActive()
                    val part = File(workDir, "$segment.part")
                    if (!part.isFile) throw ResolveException("segment assembly gap")
                    part.inputStream().use { input -> input.copyTo(out, SEGMENT_COPY_BUFFER_BYTES) }
                    if (!part.delete()) throw ResolveException("segment cache cleanup failed")
                }
            }
            return@withContext target
        } catch (error: Exception) {
            target.delete()
            throw error
        } finally {
            workDir.listFiles()?.forEach { it.delete() }
            workDir.delete()
        }
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
        var url = NzbFetchPolicy.checkedUrl(nzbUrl)
        repeat(MAX_NZB_REDIRECTS + 1) {
            val connection = (url.openConnection() as? HttpURLConnection)
                ?: throw ResolveException("NZB URL is not HTTP")
            connection.instanceFollowRedirects = false
            connection.requestMethod = "GET"
            connection.connectTimeout = NZB_TIMEOUT_MS
            connection.readTimeout = NZB_TIMEOUT_MS
            try {
                when (val code = connection.responseCode) {
                    in 200..299 -> {
                        val text = NzbFetchPolicy.readBoundedUtf8(connection.inputStream)
                        if (text.isBlank()) throw ResolveException("NZB fetch was empty")
                        return@withContext text
                    }
                    301, 302, 303, 307, 308 -> {
                        val location = connection.getHeaderField("Location")
                            ?: throw ResolveException("NZB redirect missing location")
                        url = NzbFetchPolicy.redirect(url, location)
                    }
                    else -> throw ResolveException("NZB fetch rejected: $code")
                }
            } finally {
                connection.disconnect()
            }
        }
        throw ResolveException("NZB redirect limit exceeded")
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

    private companion object {
        const val MAX_NZB_REDIRECTS = 3
        const val NZB_TIMEOUT_MS = 20_000
        const val SEGMENT_COPY_BUFFER_BYTES = 64 * 1024
        const val MAX_SEGMENT_WORKERS = 4
        const val MAX_SEGMENT_BYTES = 64 * 1024 * 1024
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
