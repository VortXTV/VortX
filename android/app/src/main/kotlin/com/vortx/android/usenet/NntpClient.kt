package com.vortx.android.usenet

import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/// A minimal, synchronous NNTP client over a single connection. The resolve runs the bounded
/// [maxConnections] window on [kotlinx.coroutines.Dispatchers.IO]; this class is the raw protocol
/// surface and intentionally knows nothing about coroutines so it is trivially testable.
///
/// Protocol (RFC 3977): greeting `200/201`, `AUTHINFO USER <u>` / `AUTHINFO PASS <p>` (both must answer
/// `281`), `GROUP <group>` -> `211 n f l s group` (n = article count), `BODY <article>` -> `222` then the
/// article body terminated by a lone `.`. The body is returned with the dot-terminator check only; yEnc
/// decoding happens in [YencDecoder].
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

    private var socket: Socket? = null
    private var reader: BufferedReader? = null
    private var writer: BufferedWriter? = null

    /// Connect + authenticate against the configured server. Throws [IOException] on any failure.
    /// The greeting format is `200/POST`-style (NNTP "ready") or a 480-auth-required error.
    fun connect() {
        val baseSocket = Socket()
        try {
            baseSocket.soTimeout = timeoutMs
            baseSocket.connect(address, timeoutMs)
        } catch (error: IOException) {
            baseSocket.close()
            throw error
        }

        val chosen = if (useSSL) {
            val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
            val ssl = factory.createSocket(baseSocket, address.hostName, address.port, true) as SSLSocket
            ssl.soTimeout = timeoutMs
            ssl.startHandshake()
            ssl
        } else {
            baseSocket
        }

        val input = BufferedReader(InputStreamReader(chosen.getInputStream(), Charsets.ISO_8859_1))
        val output = BufferedWriter(OutputStreamWriter(chosen.getOutputStream(), Charsets.ISO_8859_1))
        socket = chosen
        reader = input
        writer = output

        val greeting = readResponse()
        // 200/201 = server ready; 480 = auth required (we authenticate next regardless).
        // Any other 4xx/5xx is fatal; 3xx-broadcast responses are not expected on the greeting.
        val greetingOk = greeting.startsWith("200") || greeting.startsWith("201") || greeting.startsWith("480")
        if (!greetingOk) {
            throw IOException("NNTP greeting rejected: $greeting")
        }

        writeLine("AUTHINFO USER $username")
        val userCode = readResponse()
        if (userCode.startsWith("481") || userCode.startsWith("482") || userCode.startsWith("5")) {
            throw IOException("NNTP user rejected: $userCode")
        }
        writeLine("AUTHINFO PASS $password")
        val passCode = readResponse()
        if (!passCode.startsWith("281")) {
            throw IOException("NNTP password rejected: $passCode")
        }
    }

    /// Switch to a newsgroup (`GROUP`). Returns the article count on success.
    fun group(name: String): Long {
        writeLine("GROUP $name")
        val code = readResponse()
        // 211 n f l s group
        if (!code.startsWith("211")) throw IOException("NNTP group rejected: $code")
        val tokens = code.split(" ")
        return tokens.getOrNull(1)?.toLongOrNull() ?: 0L
    }

    /// Fetch the yEnc body for an article. Returns the raw body lines joined by \n (the byte content is
    /// ASCII-safe yEnc text; decode with [YencDecoder]). Honors the leading `222` and the trailing `.`.
    fun body(article: String): String {
        writeLine("BODY $article")
        val code = readResponse()
        if (!code.startsWith("222")) throw IOException("NNTP body rejected for $article: $code")
        val lines = arrayListOf<String>()
        while (true) {
            val line = reader!!.readLine() ?: throw IOException("NNTP body truncated for $article")
            if (line == ".") break
            lines.add(line)
        }
        return lines.joinToString("\n")
    }

    fun close() {
        try {
            socket?.close()
        } catch (_: IOException) {
        }
        socket = null
        reader = null
        writer = null
    }

    private fun writeLine(line: String) {
        writer!!.write(line)
        writer!!.newLine()
        writer!!.flush()
    }

    private fun readResponse(): String = reader!!.readLine() ?: throw IOException("NNTP connection closed")
}