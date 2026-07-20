package com.vortx.android.trailer

import android.util.Base64
import java.io.BufferedInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.net.URLDecoder
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/// A tiny local HTTP/1.1 range-proxy that sits between the player (libmpv OR ExoPlayer) and googlevideo so
/// YouTube trailers play. The Android port of Apple `app/SourcesShared/VXTrailerProxy.swift`, on
/// [ServerSocket] + [HttpURLConnection] instead of Network.framework.
///
/// WHY THIS EXISTS: googlevideo now 403s every Range shape a media stack can send on its own (an open-ended
/// `Range: bytes=0-`, or no Range at all) -- this hit ffmpeg on Apple, and it hits libmpv AND ExoPlayer's
/// `DefaultHttpDataSource` on Android identically. What googlevideo DOES answer 200 to is a bounded window
/// expressed as a query param on the URL itself: `&range=start-stop` (the browser player's mechanism). So we
/// cannot fix this with a request header; we fetch the bytes ourselves in bounded windows and re-serve them to
/// the player as a clean 206.
///
/// WHAT IT DOES: [proxied] returns a `http://127.0.0.1:<port>/yt?u=<b64url>&mime=<mime>&ua=<b64url>` URL the
/// player opens instead of the raw googlevideo URL. For each player connection the proxy:
///   1. reads the request line + headers, parses the client `Range: bytes=start-[end]` (default 0..clen-1),
///   2. replies 206 with Content-Range / Content-Length / Accept-Ranges,
///   3. streams the body by fetching googlevideo in <=1 MiB `&range=pos-stop` windows (each a plain HTTP 200),
///      sending the MINTING client's User-Agent upstream (the UA/URL lockstep) and writing each window out.
///
/// UA LOCKSTEP: unlike Apple (whose IOS client always wins, so it hardcodes one UA), the winning InnerTube
/// client varies on Android, so the UA to replay upstream is carried per-URL in the `ua` query param. The proxy
/// re-fetches every window with THAT exact UA. Sending any other UA earns a 403.
///
/// SSRF GATE: `u` is only ever proxied when its decoded host contains "googlevideo"; anything else is refused.
/// The listener binds to 127.0.0.1 on an OS-assigned ephemeral port, reachable only from this device.
///
/// FAIL-SOFT: every path is wrapped so a bad request, an upstream error, or a gone client just closes that one
/// connection. [proxied] returns null (caller falls back to the raw URL) for a non-googlevideo host or a
/// listener that will not start.
object VXTrailerProxy {

    /// Upstream fetch window. googlevideo 403s a full-file `&range=0-(clen-1)`, so the body is pulled in windows
    /// no larger than this. 1 MiB is the size proven end to end against ffmpeg in the Apple prototype.
    private const val WINDOW_SIZE = 1_048_576

    /// Per-window upstream retry budget: a single window failure must NOT truncate the fixed-length 206 (a
    /// trailer streams video + audio as TWO independent proxied connections, so one unretried hiccup ends just
    /// that track mid-clip). Each idempotent `&range=` window is re-requested up to this many times with backoff.
    private const val MAX_WINDOW_ATTEMPTS = 4
    private const val WINDOW_RETRY_BASE_DELAY_MS = 300L
    private const val WINDOW_TIMEOUT_MS = 20_000

    /// How long a client has to send a complete request header before its socket is dropped, so a client that
    /// connects then stalls cannot pin a worker thread forever.
    private const val HEADER_TIMEOUT_MS = 15_000
    private const val MAX_HEADER_BYTES = 64_000

    private val lock = Any()
    @Volatile private var server: ServerSocket? = null
    @Volatile private var port: Int = 0

    /// One worker per live connection (video + audio ride two at once during a trailer). Cached so idle threads
    /// are reclaimed between trailers.
    private val workers = Executors.newCachedThreadPool { r -> thread(start = false, isDaemon = true) { r.run() } }

    // MARK: - Public contract

    /// Return a `http://127.0.0.1/yt?...` proxy URL for a googlevideo [upstream], lazily starting the listener.
    /// [userAgent] is the minting client's UA the proxy replays upstream (UA/URL lockstep). Returns null (caller
    /// falls back to the raw URL) when the host is not googlevideo (SSRF gate) or the listener cannot start.
    fun proxied(upstream: String, mime: String, userAgent: String): String? {
        val host = runCatching { URL(upstream).host }.getOrNull() ?: return null
        if (!host.contains("googlevideo")) return null
        val boundPort = ensureListening() ?: return null
        val u = base64UrlEncode(upstream)
        val ua = base64UrlEncode(sanitizeUa(userAgent))
        val safeMime = sanitizedMime(mime)
        return "http://127.0.0.1:$boundPort/yt?u=$u&mime=$safeMime&ua=$ua"
    }

    // MARK: - Listener lifecycle

    /// Start the loopback listener once (idempotent) and return its bound port, or null on failure. Serialized so
    /// a double-resolve (hero + trailer button within seconds) cannot race two listeners into existence.
    private fun ensureListening(): Int? {
        server?.let { if (!it.isClosed && port != 0) return port }
        synchronized(lock) {
            server?.let { if (!it.isClosed && port != 0) return port }
            return try {
                val loopback = InetAddress.getByName("127.0.0.1")
                val socket = ServerSocket(0, 50, loopback)
                port = socket.localPort
                server = socket
                thread(isDaemon = true, name = "vx-trailer-proxy") { acceptLoop(socket) }
                port
            } catch (_: IOException) {
                null
            }
        }
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (_: IOException) {
                break
            }
            workers.execute { handle(client) }
        }
    }

    // MARK: - Per-connection handling

    /// Accept one player connection: read its request header, then stream the requested byte range from
    /// googlevideo. Fail-soft: any error just closes this one socket.
    private fun handle(client: Socket) {
        try {
            client.soTimeout = HEADER_TIMEOUT_MS
            val header = readHeader(client.getInputStream()) ?: run { close(client, "400 Bad Request"); return }
            serve(client, header)
        } catch (_: IOException) {
            // fall through to close
        } finally {
            runCatching { client.close() }
        }
    }

    /// Read from the socket until the CRLFCRLF header terminator, bounded by [MAX_HEADER_BYTES]. Returns the
    /// header text (without the terminator), or null on a malformed / oversized / truncated header.
    private fun readHeader(input: java.io.InputStream): String? {
        val buffer = StringBuilder()
        val stream = BufferedInputStream(input)
        var b = stream.read()
        while (b >= 0) {
            buffer.append(b.toChar())
            if (buffer.length >= 4 && buffer.endsWith("\r\n\r\n")) {
                return buffer.substring(0, buffer.length - 4)
            }
            if (buffer.length > MAX_HEADER_BYTES) return null
            b = stream.read()
        }
        return null
    }

    /// Parse the request header (path query `u`/`mime`/`ua` + `Range:`), apply the SSRF gate, then stream windows.
    private fun serve(client: Socket, header: String) {
        val lines = header.split("\r\n")
        val requestLine = lines.firstOrNull() ?: run { close(client, "400 Bad Request"); return }
        val parts = requestLine.split(" ")
        if (parts.size < 2) { close(client, "400 Bad Request"); return }
        val query = queryOf(parts[1]) ?: run { close(client, "400 Bad Request"); return }

        val mime = sanitizedMime(query["mime"])
        val upstream = query["u"]?.let { base64UrlDecode(it) } ?: run { close(client, "400 Bad Request"); return }
        val upstreamHost = runCatching { URL(upstream).host }.getOrNull()
        // SSRF gate: refuse anything that is not a googlevideo URL.
        if (upstreamHost == null || !upstreamHost.contains("googlevideo")) { close(client, "400 Bad Request"); return }
        val userAgent = query["ua"]?.let { base64UrlDecode(it) }?.let { sanitizeUa(it) }.orEmpty()

        // `clen` (total content length) is always present on a googlevideo URL.
        val clen = queryOf("?" + (runCatching { URL(upstream).query }.getOrNull() ?: ""))?.get("clen")?.toLongOrNull() ?: 0L
        if (clen <= 0L) { close(client, "404 Not Found"); return }

        val (start, end) = parseRange(lines, clen) ?: run { close(client, "416 Range Not Satisfiable"); return }
        val length = end - start + 1
        val out = client.getOutputStream()
        val head = buildString {
            append("HTTP/1.1 206 Partial Content\r\n")
            append("Content-Type: $mime\r\n")
            append("Accept-Ranges: bytes\r\n")
            append("Content-Range: bytes $start-$end/$clen\r\n")
            append("Content-Length: $length\r\n")
            append("Connection: close\r\n\r\n")
        }
        out.write(head.toByteArray(Charsets.UTF_8))
        out.flush()
        streamWindows(out, upstream, userAgent, start, end)
    }

    // MARK: - Windowed streaming

    /// Fetch `[start, end]` from googlevideo one <=1 MiB `&range=` window at a time, writing each to the client
    /// before requesting the next (backpressure keeps memory bounded to a single window). Advances by the bytes
    /// ACTUALLY delivered so a short upstream read cannot skip bytes and truncate the fixed-length 206.
    private fun streamWindows(out: OutputStream, upstream: String, userAgent: String, start: Long, end: Long) {
        var pos = start
        while (pos <= end) {
            val stop = minOf(pos + WINDOW_SIZE - 1, end)
            val data = fetchWindow(upstream, userAgent, pos, stop) ?: return // gave up -> close (truncated)
            if (data.isEmpty()) return
            val requested = (stop - pos + 1).toInt()
            val payload = if (data.size > requested) data.copyOf(requested) else data
            try {
                out.write(payload)
                out.flush()
            } catch (_: IOException) {
                return // client went away
            }
            pos += payload.size
        }
    }

    /// Fetch ONE `[start, stop]` window with a bounded retry (transient network error / non-2xx / empty body).
    /// Returns the window bytes, or null once the retry budget is exhausted (the caller then closes the socket,
    /// truncating that one track rather than hanging). Sends NO Range header -- the bounded `&range=` query is a
    /// plain 200 -- and the minting [userAgent].
    private fun fetchWindow(upstream: String, userAgent: String, start: Long, stop: Long): ByteArray? {
        val windowUrl = appendRange(upstream, start, stop) ?: return null
        var attempt = 1
        while (attempt <= MAX_WINDOW_ATTEMPTS) {
            var connection: HttpURLConnection? = null
            try {
                connection = (URL(windowUrl).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = WINDOW_TIMEOUT_MS
                    readTimeout = WINDOW_TIMEOUT_MS
                    useCaches = false
                    if (userAgent.isNotEmpty()) setRequestProperty("User-Agent", userAgent)
                }
                val status = connection.responseCode
                if (status in 200..299) {
                    val bytes = connection.inputStream.readBytes()
                    if (bytes.isNotEmpty()) return bytes
                }
            } catch (_: IOException) {
                // fall through to retry
            } finally {
                connection?.disconnect()
            }
            attempt += 1
            if (attempt <= MAX_WINDOW_ATTEMPTS) {
                runCatching { Thread.sleep(WINDOW_RETRY_BASE_DELAY_MS * (attempt - 1)) }
            }
        }
        return null
    }

    // MARK: - Helpers

    /// The client Range: "Range: bytes=start-[end]" (default the whole file), clamped to `[0, clen-1]`. Returns
    /// null for an unsatisfiable range (416).
    private fun parseRange(lines: List<String>, clen: Long): Pair<Long, Long>? {
        var start = 0L
        var end = clen - 1
        val rangeLine = lines.firstOrNull { it.lowercase().startsWith("range:") }
        if (rangeLine != null) {
            val spec = rangeLine.substringAfter('=', "").trim()
            val bounds = spec.split("-")
            if (bounds.firstOrNull().isNullOrEmpty() && bounds.size > 1) {
                // suffix range "bytes=-N": the last N bytes (RFC 7233)
                val n = bounds[1].toLongOrNull()
                if (n != null && n > 0) { start = maxOf(0L, clen - n); end = clen - 1 }
            } else {
                bounds.getOrNull(0)?.toLongOrNull()?.let { if (it >= 0) start = it }
                bounds.getOrNull(1)?.toLongOrNull()?.let { if (it >= start) end = it }
            }
        }
        end = minOf(end, clen - 1)
        return if (start <= end) start to end else null
    }

    /// The only mime types this proxy serves. A client-supplied value not in the set (including a CR/LF-bearing
    /// injection attempt) falls back to video/mp4, so the Content-Type response header can never carry attacker
    /// text.
    private val ALLOWED_MIMES = setOf("video/mp4", "audio/mp4")

    private fun sanitizedMime(raw: String?): String = if (raw != null && raw in ALLOWED_MIMES) raw else "video/mp4"

    /// Strip CR/LF (and control chars) from a UA before it goes into the UPSTREAM request header, so a crafted
    /// value can never inject extra headers into the googlevideo GET.
    private fun sanitizeUa(raw: String): String = raw.filter { it >= ' ' && it != '\u007F' }

    /// Append (or replace) the bounded `&range=start-stop` window on a googlevideo URL.
    private fun appendRange(url: String, start: Long, stop: Long): String? {
        val hashIdx = url.indexOf('#')
        val fragment = if (hashIdx >= 0) url.substring(hashIdx) else ""
        val beforeFragment = if (hashIdx >= 0) url.substring(0, hashIdx) else url
        val qIdx = beforeFragment.indexOf('?')
        if (qIdx < 0) return "$beforeFragment?range=$start-$stop$fragment"
        val base = beforeFragment.substring(0, qIdx)
        val kept = beforeFragment.substring(qIdx + 1).split('&')
            .filter { it.isNotEmpty() && it.substringBefore('=') != "range" }
        val rebuilt = (kept + "range=$start-$stop").joinToString("&")
        return "$base?$rebuilt$fragment"
    }

    /// Parse the `key=value` pairs of a request target ("/yt?u=...&mime=...") or a bare "?query". URL-decodes
    /// each value. Returns null when there is no query.
    private fun queryOf(target: String): Map<String, String>? {
        val qIdx = target.indexOf('?')
        if (qIdx < 0) return null
        val query = target.substring(qIdx + 1)
        if (query.isEmpty()) return emptyMap()
        val out = HashMap<String, String>()
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val name = pair.substringBefore('=')
            val value = pair.substringAfter('=', "")
            out[name] = runCatching { URLDecoder.decode(value, "UTF-8") }.getOrDefault(value)
        }
        return out
    }

    /// Write a bare status line and close (the refusal / error paths).
    private fun close(client: Socket, status: String) {
        runCatching {
            val body = "HTTP/1.1 $status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            client.getOutputStream().apply {
                write(body.toByteArray(Charsets.UTF_8))
                flush()
            }
        }
        runCatching { client.close() }
    }

    private fun base64UrlEncode(s: String): String =
        Base64.encodeToString(s.toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun base64UrlDecode(s: String): String? = runCatching {
        String(Base64.decode(s, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING), Charsets.UTF_8)
    }.getOrNull()
}
