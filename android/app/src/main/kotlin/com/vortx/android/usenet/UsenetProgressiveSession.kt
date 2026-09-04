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
import java.util.concurrent.Executors
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
        monitor.notifyAll()
    }

    fun fail(error: Throwable) = synchronized(monitor) {
        failure = error
        completed = true
        monitor.notifyAll()
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
        if (delete) file.delete()
    }

    internal fun totalBytes(): Long = declaredBytes
}

/** One private 127.0.0.1 listener shared by progressive NZB sessions. */
internal object UsenetProgressiveLoopback {
    private val sessions = ConcurrentHashMap<String, UsenetProgressiveSession>()
    private val workers: ExecutorService = Executors.newCachedThreadPool()
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
            workers.execute { handle(socket) }
        } ?: return
    }

    private fun handle(client: Socket) {
        client.use {
            runCatching {
                client.soTimeout = 15_000
                val lines = client.getInputStream().bufferedReader(Charsets.ISO_8859_1).readLinesUntilBlank(64 * 1024)
                    ?: return@runCatching
                val request = lines.firstOrNull()?.split(' ') ?: return@runCatching
                val session = request.getOrNull(1)?.removePrefix("/nzb/")?.let(sessions::get) ?: return@runCatching send(client, 404)
                val total = session.totalBytes()
                val range = parseRange(lines, total) ?: return@runCatching send(client, 416)
                val (start, end) = range
                val length = end - start + 1
                val out = client.getOutputStream()
                val head = if (request.firstOrNull() == "HEAD") "HTTP/1.1 200 OK" else "HTTP/1.1 206 Partial Content"
                out.write(("$head\r\nAccept-Ranges: bytes\r\nContent-Type: video/x-matroska\r\nContent-Length: $length\r\nContent-Range: bytes $start-$end/$total\r\nConnection: close\r\n\r\n").toByteArray())
                out.flush()
                if (request.firstOrNull() != "HEAD") session.copyRange(start, end, out)
            }
        }
    }

    private fun send(client: Socket, code: Int) {
        client.getOutputStream().write("HTTP/1.1 $code Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
    }

    private fun parseRange(lines: List<String>, total: Long): Pair<Long, Long>? {
        val raw = lines.firstOrNull { it.startsWith("Range:", true) }?.substringAfter('=' )?.trim()
        if (raw.isNullOrEmpty()) return 0L to (total - 1)
        val bounds = raw.removePrefix("bytes=").split('-', limit = 2)
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
