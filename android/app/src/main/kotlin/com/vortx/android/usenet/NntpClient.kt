package com.vortx.android.usenet

import java.io.BufferedWriter
import java.io.InputStream
import java.io.IOException
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.SSLParameters

/// A minimal, synchronous NNTP client over a single connection. The resolve runs the bounded
/// [maxConnections] window on [kotlinx.coroutines.Dispatchers.IO]; this class is the raw protocol
/// surface and intentionally knows nothing about coroutines so it is trivially testable.
///
/// Protocol (RFC 3977): greeting `200/201`, `AUTHINFO USER <u>` / `AUTHINFO PASS <p>` (both must answer
/// `281`), `GROUP <group>` -> `211 n f l s group` (n = article count), `BODY <article>` -> `222` then the
/// article body terminated by a lone `.`. The body is decoded into a private segment file as it arrives;
/// no full article body is represented in heap memory.
///
/// Security: TLS via [SSLSocketFactory] when [useSSL]; the password is sent ONLY as the AUTHINFO PASS
/// argument (never logged). Timeouts are enforced per-read so a stalled provider cannot hang resolve.
internal class NntpClient(
    host: String,
    port: Int,
    private val username: String,
    private val password: String,
    private val useSSL: Boolean,
    private val timeoutMs: Int = 30_000,
) {
    private val address = host.trim().let {
        require(it.isNotEmpty()) { "NNTP host cannot be empty" }
        InetSocketAddress(it, port.coerceIn(1, 65535))
    }
    private val originalHost = host.trim()

    private val socketLock = Any()
    @Volatile private var socket: Socket? = null
    private var reader: NntpLineReader? = null
    private var writer: BufferedWriter? = null

    /// Connect + authenticate against the configured server. Throws [IOException] on any failure.
    /// The greeting format is `200/POST`-style (NNTP "ready") or a 480-auth-required error.
    fun connect() {
        val baseSocket = Socket()
        // Publish before DNS/connect/TLS: close() from cancellation can now interrupt every blocking phase.
        replaceSocket(baseSocket)
        try {
            baseSocket.soTimeout = timeoutMs
            baseSocket.connect(address, timeoutMs)
        } catch (error: IOException) {
            baseSocket.close()
            throw error
        }

        if (!useSSL) {
            baseSocket.close()
            throw IOException("NNTP credentials require TLS")
        }
        val chosen = if (useSSL) {
            val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
            val ssl = factory.createSocket(baseSocket, originalHost, address.port, true) as SSLSocket
            replaceSocket(ssl)
            ssl.soTimeout = timeoutMs
            ssl.sslParameters = SSLParameters().also { it.endpointIdentificationAlgorithm = "HTTPS" }
            ssl.startHandshake()
            ssl
        } else {
            baseSocket
        }

        val input = NntpLineReader(chosen.getInputStream())
        val output = BufferedWriter(OutputStreamWriter(chosen.getOutputStream(), Charsets.ISO_8859_1))
        replaceSocket(chosen)
        reader = input
        writer = output

        val greeting = readResponse()
        // 200/201 = server ready; 480 = auth required (we authenticate next regardless).
        // Any other 4xx/5xx is fatal; 3xx-broadcast responses are not expected on the greeting.
        val greetingOk = greeting.startsWith("200") || greeting.startsWith("201") || greeting.startsWith("480")
        if (!greetingOk) {
            throw IOException("NNTP greeting rejected")
        }

        writeLine("AUTHINFO USER $username")
        val userCode = readResponse()
        if (userCode.startsWith("481") || userCode.startsWith("482") || userCode.startsWith("5")) {
            throw IOException("NNTP user rejected")
        }
        writeLine("AUTHINFO PASS $password")
        val passCode = readResponse()
        if (!passCode.startsWith("281")) {
            throw IOException("NNTP password rejected")
        }
    }

    /// Switch to a newsgroup (`GROUP`). Returns the article count on success.
    fun group(name: String): Long {
        writeLine("GROUP $name")
        val code = readResponse()
        // 211 n f l s group
        if (!code.startsWith("211")) throw IOException("NNTP group rejected")
        return code.substringAfter(' ', "").substringBefore(' ').toLongOrNull() ?: 0L
    }

    /**
     * Fetch and yEnc-decode an article straight into [output]. Both encoded wire data and decoded bytes are
     * bounded while reading. Closing this client closes the underlying socket, promptly unblocking a stuck
     * `readLine` when its coroutine is cancelled.
     */
    fun bodyTo(
        article: String,
        output: OutputStream,
        encodedLimit: Long,
        decodedLimit: Long,
    ): Long {
        writeLine("BODY $article")
        val code = readResponse()
        if (!code.startsWith("222")) throw IOException("NNTP body rejected")
        val decoder = YencDecoder.StreamingDecoder(output, decodedLimit)
        var encodedBytes = 0L
        while (true) {
            val line = reader!!.readLine(MAX_BODY_LINE_BYTES) ?: throw IOException("NNTP body truncated")
            if (line.size == 1 && line[0] == '.'.code.toByte()) break
            // BufferedReader strips CRLF. Count the original line terminator conservatively to reject an
            // oversized wire article before it can be decoded or held beyond one protocol line.
            encodedBytes += line.size.toLong() + 2L
            if (encodedBytes > encodedLimit) throw IOException("NNTP body exceeds encoded size limit")
            decoder.consumeLine(line, line.size, if (line.size > 1 && line[0] == '.'.code.toByte() && line[1] == '.'.code.toByte()) 1 else 0)
        }
        return decoder.finish()
    }

    fun close() {
        val active = synchronized(socketLock) { socket.also { socket = null } }
        try {
            active?.close()
        } catch (_: IOException) {
        }
        reader = null
        writer = null
    }

    private fun writeLine(line: String) {
        writer!!.write(line)
        writer!!.newLine()
        writer!!.flush()
    }

    private fun readResponse(): String = reader!!.readLine(MAX_RESPONSE_LINE_BYTES)
        ?.toString(Charsets.ISO_8859_1) ?: throw IOException("NNTP connection closed")

    private companion object {
        const val MAX_RESPONSE_LINE_BYTES = 8 * 1024
        const val MAX_BODY_LINE_BYTES = 256 * 1024
    }

    private fun replaceSocket(next: Socket) = synchronized(socketLock) { socket = next }
}

/** Byte-level CRLF reader: rejects an overlong or unterminated NNTP line before allocating it. */
internal class NntpLineReader(private val input: InputStream) {
    fun readLine(limit: Int): ByteArray? {
        val output = java.io.ByteArrayOutputStream(minOf(limit, 1024))
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (output.size() == 0) null else throw IOException("NNTP line truncated")
            if (byte == '\n'.code) {
                val line = output.toByteArray()
                return if (line.lastOrNull() == '\r'.code.toByte()) line.copyOf(line.size - 1) else line
            }
            if (output.size() == limit) throw IOException("NNTP line exceeds limit")
            output.write(byte)
        }
    }
}
