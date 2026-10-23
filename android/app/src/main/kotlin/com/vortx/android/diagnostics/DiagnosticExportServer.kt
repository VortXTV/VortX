package com.vortx.android.diagnostics

import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.Base64

/**
 * Serves ONE scrubbed diagnostic export to a phone on the same network, the Android TV counterpart of Apple
 * TV's `VXDiagExport` (a TV has no share sheet). The capability is in the URL: a fresh random path per
 * start, served once, bound to the LAN address only, with a request deadline and an overall window. The URL
 * is a secret for that window, so it is shown on screen and never written to a log line.
 */
internal class DiagnosticExportServer(
    private val body: () -> String,
    private val windowMs: Long = WINDOW_MS,
    private val bindAddress: () -> InetAddress? = ::lanIPv4,
    private val requestDeadlineMs: Long = REQUEST_DEADLINE_MS,
) {
    @Volatile private var server: ServerSocket? = null
    @Volatile private var active: Socket? = null
    @Volatile private var served = false

    /** Start serving and return the URL to show as a QR, or null when this device has no LAN address. */
    @Synchronized
    fun start(): String? {
        stop()
        val address = bindAddress() ?: return null
        val socket = try { ServerSocket(0, 4, address) } catch (_: IOException) { return null }
        val path = "/diag/" + capability()
        server = socket
        served = false
        Thread({ acceptLoop(socket, path) }, "vortx-diag-export").apply { isDaemon = true }.start()
        return "http://${address.hostAddress}:${socket.localPort}$path"
    }

    @Synchronized
    fun stop() {
        runCatching { server?.close() }
        runCatching { active?.close() }
        server = null
        active = null
    }

    /** True once the export was downloaded (the capability is spent). */
    val wasServed: Boolean get() = served

    private fun acceptLoop(socket: ServerSocket, path: String) {
        val deadline = System.currentTimeMillis() + windowMs
        try {
            while (!socket.isClosed && !served && System.currentTimeMillis() < deadline) {
                socket.soTimeout = (deadline - System.currentTimeMillis()).coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
                val client = try { socket.accept() } catch (_: SocketTimeoutException) { break }
                active = client
                try {
                    client.use { if (handle(it, path, minOf(deadline, System.currentTimeMillis() + requestDeadlineMs))) served = true }
                } catch (_: IOException) {
                    // A slow, broken or hostile client loses only its own request; keep serving the window.
                } finally {
                    active = null
                }
            }
        } catch (_: IOException) {
            // Closed by stop() or the network went away: the window simply ends.
        } finally {
            runCatching { socket.close() }
        }
    }

    /**
     * Answer one request; true only when the capability path was served the export. [requestDeadline] bounds
     * the WHOLE request, not each read, so a client trickling one byte at a time cannot hold the server.
     */
    private fun handle(client: Socket, path: String, requestDeadline: Long): Boolean {
        val requestLine = runCatching { readRequestLine(client, requestDeadline) }.getOrNull()
        val parts = requestLine?.split(' ')
        val matches = parts != null && parts.size >= 2 && parts[0] == "GET" && parts[1] == path
        val output = client.getOutputStream()
        if (!matches) {
            output.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            output.flush()
            return false
        }
        val bytes = body().toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Disposition: attachment; filename=\"VortX-diagnostics.txt\"\r\n" +
            "Cache-Control: no-store\r\n" +
            "Content-Length: ${bytes.size}\r\n" +
            "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.US_ASCII))
        output.write(bytes)
        output.flush()
        return true
    }

    /** The request line only, bounded; the headers are drained up to the blank line and ignored. */
    private fun readRequestLine(client: Socket, requestDeadline: Long): String? {
        val input = client.getInputStream()
        val line = StringBuilder()
        var requestLine: String? = null
        var total = 0
        while (total < MAX_REQUEST_BYTES) {
            val remaining = requestDeadline - System.currentTimeMillis()
            if (remaining <= 0) throw SocketTimeoutException("Request deadline passed")
            client.soTimeout = remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            val next = input.read()
            if (next < 0) break
            total++
            if (next != '\n'.code) {
                line.append(next.toChar())
                continue
            }
            val text = line.toString().trimEnd('\r')
            line.setLength(0)
            if (requestLine == null) requestLine = text else if (text.isEmpty()) break
        }
        return requestLine
    }

    private fun capability(): String {
        val bytes = ByteArray(24).also(SecureRandom()::nextBytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    internal companion object {
        const val WINDOW_MS = 10 * 60_000L
        /** One request, start to finish, the same 15 s Apple TV gives a client to send its header. */
        const val REQUEST_DEADLINE_MS = 15_000L
        private const val MAX_REQUEST_BYTES = 8 * 1024

        /** The device's LAN IPv4 (Wi-Fi or Ethernet), never loopback; null when not on a local network. */
        fun lanIPv4(): InetAddress? = runCatching {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { it.isUp && !it.isLoopback && !it.isVirtual }
                .sortedBy { if (it.name.startsWith("wlan") || it.name.startsWith("eth")) 0 else 1 }
                .flatMap { it.inetAddresses.toList() }
                .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }
        }.getOrNull()
    }
}
