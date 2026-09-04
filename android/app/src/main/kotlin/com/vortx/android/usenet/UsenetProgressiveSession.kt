package com.vortx.android.usenet

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.ArrayBlockingQueue
import kotlinx.coroutines.Job

/**
 * One ordered, append-only NZB title plus its loopback HTTP representation.  A player may request any
 * byte range immediately. The HTTP handler writes its headers immediately, then waits only for the ordered
 * bytes it has promised. This is deliberately not a `file://` partial download: Media3 and mpv both use
 * ranges while probing containers and need a real range server.
 */
internal class UsenetProgressiveSession(
    val file: File,
    private val declaredBytes: Long,
    internal val mediaType: String = "video/x-matroska",
    private val allocation: UsenetCachePolicy.Allocation? = null,
) : AutoCloseable {
    private val monitor = Object()
    private var availableBytes = 0L
    private var completed = false
    private var failure: Throwable? = null
    @Volatile private var closed = false
    @Volatile private var producer: Job? = null
    private val id = UUID.randomUUID().toString()

    val url: String get() = UsenetProgressiveLoopback.register(id, this)

    fun appendCommitted(bytes: Long) = synchronized(monitor) {
        check(!closed) { "progressive session closed" }
        availableBytes += bytes
        monitor.notifyAll()
    }

    fun finish() = synchronized(monitor) {
        completed = true
        allocation?.complete()
        monitor.notifyAll()
    }

    fun fail(error: Throwable) = synchronized(monitor) {
        failure = error
        completed = true
        monitor.notifyAll()
        allocation?.abandon()
        UsenetProgressiveLoopback.unregister(id)
    }

    internal fun attachProducer(job: Job) { producer = job }

    /** Serve exactly the requested bytes, pausing at the append frontier without preloading title data. */
    internal fun copyRange(start: Long, end: Long, output: java.io.OutputStream) {
        var position = start
        val buffer = ByteArray(64 * 1024)
        while (position <= end) {
            val readable = synchronized(monitor) {
                while (!closed && position >= availableBytes && !completed) monitor.wait()
                when {
                    closed -> throw IOException("Usenet session closed")
                    position < availableBytes -> minOf(end - position + 1, availableBytes - position)
                    failure != null -> throw IOException("Usenet stream failed", failure)
                    else -> 0L
                }
            }
            if (readable == 0L) return // clean completion before an over-declared tail
            RandomAccessFile(file, "r").use { input ->
                input.seek(position)
                var remaining = readable
                while (remaining > 0) {
                    val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    if (count < 0) throw IOException("Usenet cache truncated")
                    output.write(buffer, 0, count)
                    remaining -= count
                    position += count
                }
                output.flush()
            }
        }
    }

    override fun close() {
        val delete = synchronized(monitor) {
            if (closed) return
            closed = true
            monitor.notifyAll()
            !completed
        }
        UsenetProgressiveLoopback.unregister(id)
        // Cancelling the assembly job starts each NNTP transport's cancellation hook, which closes its
        // currently published socket instead of leaving a background download behind after player teardown.
        producer?.cancel()
        allocation?.abandon()
        if (delete) file.delete()
    }

    internal fun totalBytes(): Long = declaredBytes
}

/** One private 127.0.0.1 listener shared by progressive NZB sessions. */
internal object UsenetProgressiveLoopback {
    private val sessions = ConcurrentHashMap<String, UsenetProgressiveSession>()
    private val workers: ExecutorService = ThreadPoolExecutor(2, 4, 30, java.util.concurrent.TimeUnit.SECONDS, ArrayBlockingQueue(8))
    private val lock = Any()
    @Volatile private var server: ServerSocket? = null
    @Volatile private var port = 0

    fun register(id: String, session: UsenetProgressiveSession): String {
        sessions[id] = session
        val boundPort = ensureListening() ?: throw IOException("Usenet loopback unavailable")
        return "http://127.0.0.1:$boundPort/nzb/$id"
    }

    fun unregister(id: String) { sessions.remove(id) }

    private fun ensureListening(): Int? = synchronized(lock) {
        server?.takeIf { !it.isClosed && port != 0 }?.let { return port }
        runCatching {
            ServerSocket(0, 16, InetAddress.getByName("127.0.0.1")).also { socket ->
                server = socket
                port = socket.localPort
                Thread({ acceptLoop(socket) }, "vortx-usenet-loopback").apply { isDaemon = true; start() }
            }
        }.getOrNull()?.let { port }
    }

    private fun acceptLoop(listener: ServerSocket) {
        while (!listener.isClosed) runCatching { listener.accept() }.getOrNull()?.let { socket ->
            runCatching { workers.execute { handle(socket) } }.onFailure { socket.close() }
        } ?: return
    }

    private fun handle(client: Socket) {
        client.use {
            runCatching {
                client.soTimeout = 15_000
                val lines = client.getInputStream().bufferedReader(Charsets.ISO_8859_1).readLinesUntilBlank(64 * 1024)
                    ?: return@runCatching
                val request = lines.firstOrNull()?.split(' ') ?: return@runCatching send(client, 400)
                if (request.size != 3 || request[0] !in setOf("GET", "HEAD") || !request[1].startsWith("/nzb/") || request[2] != "HTTP/1.1") return@runCatching send(client, 400)
                val session = request[1].removePrefix("/nzb/").takeIf { it.matches(Regex("[0-9a-f-]{36}")) }?.let(sessions::get) ?: return@runCatching send(client, 404)
                val total = session.totalBytes()
                val explicitRange = lines.firstOrNull { it.startsWith("Range:", true) }
                val range = parseRange(explicitRange, total) ?: return@runCatching send(client, 416, total)
                val (start, end) = range
                val length = end - start + 1
                val out = client.getOutputStream()
                val status = if (explicitRange == null) "HTTP/1.1 200 OK" else "HTTP/1.1 206 Partial Content"
                val contentRange = if (explicitRange == null) "" else "Content-Range: bytes $start-$end/$total\r\n"
                out.write(("$status\r\nAccept-Ranges: bytes\r\nContent-Type: ${session.mediaType}\r\nContent-Length: $length\r\n${contentRange}Connection: close\r\n\r\n").toByteArray())
                out.flush()
                if (request.firstOrNull() != "HEAD") session.copyRange(start, end, out)
            }
        }
    }

    private fun send(client: Socket, code: Int, total: Long? = null) {
        val range = total?.let { "Content-Range: bytes */$it\r\n" }.orEmpty()
        client.getOutputStream().write("HTTP/1.1 $code Error\r\n${range}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
    }

    private fun parseRange(rangeLine: String?, total: Long): Pair<Long, Long>? {
        val raw = rangeLine?.substringAfter("Range:", "")?.trim()
        if (raw.isNullOrEmpty()) return 0L to (total - 1)
        if (!raw.startsWith("bytes=", ignoreCase = true)) return null
        val bounds = raw.substringAfter('=').split('-', limit = 2)
        if (bounds.firstOrNull().isNullOrEmpty()) {
            val suffix = bounds.getOrNull(1)?.toLongOrNull()?.takeIf { it > 0 } ?: return null
            return maxOf(0L, total - suffix) to (total - 1)
        }
        val start = bounds.firstOrNull()?.toLongOrNull() ?: return null
        val end = bounds.getOrNull(1)?.toLongOrNull()?.coerceAtMost(total - 1) ?: total - 1
        return if (start in 0..end && end < total) start to end else null
    }

    private fun java.io.BufferedReader.readLinesUntilBlank(limit: Int): List<String>? {
        val lines = mutableListOf<String>(); var count = 0
        while (true) {
            val line = readLine() ?: return null
            count += line.length
            if (count > limit) return null
            if (line.isEmpty()) return lines
            lines += line
        }
    }
}
