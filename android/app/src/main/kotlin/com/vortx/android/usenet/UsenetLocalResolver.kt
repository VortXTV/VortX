package com.vortx.android.usenet

import android.content.Context
import com.vortx.android.debrid.DebridResolver
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
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

        // Return a loopback range URL as soon as the producer is scheduled.  The session exposes only
        // committed ordered bytes, so a media probe can open now but never sees a fictitious complete file.
        val session = startProgressiveAssembly(pick)
        NzbResult(
            file = session.file,
            subject = pick.name,
            sizeBytes = pick.declaredBytes,
            progressiveSession = session,
        )
    }

    private fun startProgressiveAssembly(file: NzbFile): UsenetProgressiveSession {
        val declaredBytes = file.declaredBytes
        if (file.segments.isEmpty() || declaredBytes !in 1..MAX_TITLE_BYTES) {
            throw ResolveException("NZB declared size is invalid")
        }
        val target = cacheFile(declaredBytes)
        val session = UsenetProgressiveSession(target, declaredBytes)
        try {
            session.url // register before the worker can make progress or fail
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
        val producer = CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                assemble(file, target, session)
                session.finish()
            } catch (error: Throwable) {
                session.fail(error)
                target.delete()
            }
        }
        session.attachProducer(producer)
        return session
    }

    private suspend fun assemble(file: NzbFile, target: File, session: UsenetProgressiveSession) = withContext(Dispatchers.IO) {
        val segments = file.segments
        if (segments.isEmpty()) throw ResolveException("file has no segments")
        val declaredBytes = file.declaredBytes
        if (declaredBytes !in 1..MAX_TITLE_BYTES) throw ResolveException("NZB declared size is invalid")

        val window = credentials.maxConnections.coerceIn(1, MAX_SEGMENT_WORKERS)
        val slotCount = minOf(window, segments.size)
        val workDir = File(context.cacheDir, "usenet/work-${System.nanoTime()}")
        if (!workDir.mkdirs()) throw ResolveException("cache work dir unavailable")
        val requiredSpace = declaredBytes + minOf(
            declaredBytes,
            MAX_SEGMENT_BYTES.toLong() * slotCount.toLong(),
        )
        if (target.parentFile?.usableSpace ?: 0L < requiredSpace) {
            workDir.delete()
            throw ResolveException("insufficient cache storage for NZB")
        }

        try {
            coroutineScope {
                // The writer releases the next index only after committing its predecessor. Thus there can
                // never be more than [slotCount] private parts in-flight/reordered, even if segment zero is
                // slow while later NNTP workers finish immediately.
                val jobs = Channel<Int>(slotCount)
                val completed = Channel<CompletedPart>(slotCount)
                repeat(slotCount) { jobs.trySend(it) }
                val workers = List(slotCount) {
                    launch(Dispatchers.IO) {
                        for (seg in jobs) {
                            coroutineContext.ensureActive()
                            val part = File(workDir, "$seg.part")
                            val decodedBytes = fetchSegmentTo(segments[seg], part)
                            completed.send(CompletedPart(seg, part, decodedBytes))
                        }
                    }
                }

                var expected = 0
                var nextToSchedule = slotCount
                var assembledBytes = 0L
                val reordered = HashMap<Int, CompletedPart>(slotCount)
                BufferedOutputStream(FileOutputStream(target)).use { out ->
                    while (expected < segments.size) {
                        coroutineContext.ensureActive()
                        val finished = completed.receive()
                        if (reordered.put(finished.index, finished) != null) {
                            throw ResolveException("duplicate NZB segment completion")
                        }
                        while (true) {
                            val next = reordered.remove(expected) ?: break
                            if (!NzbAssemblyLimits.permitsAppend(assembledBytes, next.decodedBytes, declaredBytes)) {
                                throw ResolveException("NZB decoded size exceeds declared title size")
                            }
                            next.file.inputStream().use { input -> input.copyTo(out, SEGMENT_COPY_BUFFER_BYTES) }
                            assembledBytes += next.decodedBytes
                            // Make the complete ordered part visible before waking a range reader. The reader
                            // never observes a half-written part, which keeps its file reads deterministic.
                            out.flush()
                            session.appendCommitted(next.decodedBytes)
                            if (!next.file.delete()) throw ResolveException("segment cache cleanup failed")
                            expected += 1
                            if (nextToSchedule < segments.size) jobs.send(nextToSchedule++)
                        }
                    }
                }
                jobs.close()
                workers.forEach { it.join() }
            }
        } catch (error: Throwable) {
            target.delete()
            throw error
        } finally {
            workDir.listFiles()?.forEach { it.delete() }
            workDir.delete()
        }
    }

    @OptIn(InternalCoroutinesApi::class)
    private suspend fun fetchSegmentTo(segment: NzbSegment, destination: File): Long = withContext(Dispatchers.IO) {
        if (segment.article.isEmpty()) throw ResolveException("segment has no article id")
        val client = NntpClient(
            host = credentials.host,
            port = credentials.port,
            username = credentials.username,
            password = credentials.password,
            useSSL = credentials.useSSL,
            timeoutMs = timeoutMs,
        )
        // `withContext(IO)` does not itself interrupt a blocking socket read. Couple cancellation to close
        // so a cancelled resolve immediately tears down the transport rather than waiting for readTimeout.
        // A normal completion handler waits for this blocked child. The cancellation-start hook closes the
        // published socket immediately, even with the deliberately long provider read timeout below.
        val cancellationClose = coroutineContext[Job]?.invokeOnCompletion(
            onCancelling = true,
            invokeImmediately = true,
        ) { client.close() }
        try {
            client.connect()
            FileOutputStream(destination).use { output ->
                client.bodyTo(
                    article = segment.article,
                    output = output,
                    encodedLimit = MAX_ENCODED_SEGMENT_BYTES.toLong(),
                    decodedLimit = MAX_SEGMENT_BYTES.toLong(),
                )
            }
        } catch (error: java.io.IOException) {
            // Socket close is how coroutine cancellation interrupts connect/TLS/read. Do not turn that into
            // a normal resolver failure after the caller has abandoned playback.
            coroutineContext.ensureActive()
            throw error
        } finally {
            cancellationClose?.dispose()
            client.close()
        }
    }

    private suspend fun fetchNzb(nzbUrl: String): String = withContext(Dispatchers.IO) {
        var request = NzbFetchPolicy.checkedRequest(nzbUrl)
        val transport = PinnedNzbTransport(NZB_TIMEOUT_MS)
        repeat(MAX_NZB_REDIRECTS + 1) {
            val response = transport.execute(request)
            when (response.code) {
                in 200..299 -> {
                    val text = response.body ?: throw ResolveException("NZB fetch was empty")
                    if (text.isBlank()) throw ResolveException("NZB fetch was empty")
                    return@withContext text
                }
                301, 302, 303, 307, 308 -> {
                    val location = response.location ?: throw ResolveException("NZB redirect missing location")
                    request = NzbFetchPolicy.redirect(request, location)
                }
                else -> throw ResolveException("NZB fetch rejected: ${response.code}")
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

    private fun cacheFile(reservationBytes: Long): File {
        val home = File(context.cacheDir, "usenet")
        if (!UsenetCachePolicy.reserve(home, reservationBytes)) {
            throw ResolveException("insufficient bounded Usenet cache storage")
        }
        return File(home, "vortx-nzb-${System.nanoTime()}.mkv")
    }

    private companion object {
        const val MAX_NZB_REDIRECTS = 3
        const val NZB_TIMEOUT_MS = 20_000
        const val SEGMENT_COPY_BUFFER_BYTES = 64 * 1024
        const val MAX_SEGMENT_WORKERS = 4
        const val MAX_SEGMENT_BYTES = 64 * 1024 * 1024
        const val MAX_ENCODED_SEGMENT_BYTES = 96 * 1024 * 1024
        const val MAX_TITLE_BYTES = 100L * 1024 * 1024 * 1024
    }

    private data class CompletedPart(val index: Int, val file: File, val decodedBytes: Long)
}

/** The aggregate assembly boundary. It is checked before copying every ordered part to the playable file. */
internal object NzbAssemblyLimits {
    private const val MAX_TITLE_BYTES = 100L * 1024 * 1024 * 1024

    fun permitsAppend(assembledBytes: Long, nextPartBytes: Long, declaredBytes: Long): Boolean =
        assembledBytes >= 0 && nextPartBytes >= 0 && declaredBytes in 1..MAX_TITLE_BYTES &&
            nextPartBytes <= MAX_TITLE_BYTES - assembledBytes &&
            nextPartBytes <= declaredBytes - assembledBytes
}

/// The result of a native usenet resolve: a playable LOCAL file the player opens directly.
internal data class NzbResult(
    val file: File,
    val subject: String,
    val sizeBytes: Long,
    private val progressiveSession: UsenetProgressiveSession? = null,
) {
    val url: String get() = progressiveSession?.url ?: "file://" + file.absolutePath
    fun cancel() = progressiveSession?.close()
}
