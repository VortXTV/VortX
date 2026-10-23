package com.vortx.android.network

import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.mserref.NtStatus
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.common.SMBRuntimeException
import com.hierynomus.smbj.share.DiskShare
import java.io.BufferedInputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.EnumSet
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** One readable SMB file: its size and positional reads. Closing releases the file, share and session. */
interface SmbFileSource : Closeable {
    val size: Long

    /** Reads up to [length] bytes at [offset] into [buffer] from index 0; the count read, or -1 at the end. */
    fun read(offset: Long, buffer: ByteArray, length: Int): Int
}

/** A file inside a share and the login that opens it. Not a data class, so no toString can print the password. */
class SmbTarget(val location: SmbLocation, val login: NetworkShareClient.Login, val name: String)

/**
 * Browses SMB shares and opens their files with smbj. Android's libmpv is built without SMB (Apple's MPVKit
 * FFmpeg has it), so the player reads SMB files through [NetworkShareSmbRelay] instead. A login is used as given
 * and never falls back to guest; an empty username is a guest login. "DOMAIN\user" logs in to a domain. Without
 * smbj-rpc a server cannot list its shares, so an Android address must name its share.
 */
class NetworkShareSmbClient(private val client: SMBClient = DEFAULT_CLIENT) {

    /** The visible contents of [folder] (folders first, then videos). */
    suspend fun list(folder: String, root: String, login: NetworkShareClient.Login): List<NetworkShareEntry> = withContext(Dispatchers.IO) {
        if (!NetworkSharePolicy.isInside(folder, root)) throw NetworkShareException(NetworkShareException.Reason.REDIRECTED_AWAY)
        val location = NetworkSharePolicy.smbLocation(folder) ?: throw NetworkShareException(NetworkShareException.Reason.INVALID_ADDRESS)
        val shareName = location.share ?: throw NetworkShareException(NetworkShareException.Reason.SMB_SHARE_REQUIRED)
        val items = translate {
            client.connect(location.host, location.port).use { connection ->
                connection.authenticate(authentication(login)).use { session ->
                    val share = session.connectShare(shareName) as? DiskShare
                        ?: throw NetworkShareException(NetworkShareException.Reason.NOT_A_SHARE)
                    share.use { disk ->
                        disk.list(location.path).map { it.fileName to (it.fileAttributes and DIRECTORY != 0L) }
                    }
                }
            }
        }
        NetworkSharePolicy.visible(NetworkSharePolicy.smbEntries(items, folder))
    }

    /** Opens [target] for reading. Blocking: call it off the main thread (the relay's workers do). */
    fun open(target: SmbTarget): SmbFileSource = translate {
        val location = target.location
        val shareName = location.share ?: throw NetworkShareException(NetworkShareException.Reason.SMB_SHARE_REQUIRED)
        val opened = ArrayList<AutoCloseable>()
        try {
            val connection = client.connect(location.host, location.port).also { opened += it }
            val session = connection.authenticate(authentication(target.login)).also { opened += it }
            val share = (session.connectShare(shareName) as? DiskShare)?.also { opened += it }
                ?: throw NetworkShareException(NetworkShareException.Reason.NOT_A_SHARE)
            val file = share.openFile(location.path, EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN, null)
            opened += file
            val size = file.fileInformation.standardInformation.endOfFile
            object : SmbFileSource {
                override val size: Long = size
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int = translate { file.read(buffer, offset, 0, length) }
                override fun close() = closeAll(opened)
            }
        } catch (failure: Throwable) {
            closeAll(opened)
            throw failure
        }
    }

    companion object {
        private val DIRECTORY = FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value

        private val DEFAULT_CLIENT: SMBClient by lazy {
            SMBClient(SmbConfig.builder().withTimeout(15, TimeUnit.SECONDS).withSoTimeout(30, TimeUnit.SECONDS).build())
        }

        /** The smbj login for [login]: guest without a username, "DOMAIN\user" split into its domain. */
        internal fun authentication(login: NetworkShareClient.Login): AuthenticationContext {
            if (login.username.isEmpty()) return AuthenticationContext.guest()
            val parts = login.username.split('\\', limit = 2)
            return if (parts.size == 2) AuthenticationContext(parts[1], login.password.toCharArray(), parts[0])
            else AuthenticationContext(login.username, login.password.toCharArray(), null)
        }

        /** smbj failures as the viewer-facing reasons the other share kinds use. */
        private inline fun <T> translate(body: () -> T): T = try {
            body()
        } catch (failure: SMBApiException) {
            throw NetworkShareException(when (failure.status) {
                NtStatus.STATUS_ACCESS_DENIED, NtStatus.STATUS_LOGON_FAILURE, NtStatus.STATUS_PASSWORD_EXPIRED,
                NtStatus.STATUS_ACCOUNT_DISABLED -> NetworkShareException.Reason.UNAUTHORIZED
                NtStatus.STATUS_BAD_NETWORK_NAME, NtStatus.STATUS_OBJECT_NAME_NOT_FOUND, NtStatus.STATUS_OBJECT_PATH_NOT_FOUND,
                NtStatus.STATUS_NOT_A_DIRECTORY, NtStatus.STATUS_FILE_IS_A_DIRECTORY -> NetworkShareException.Reason.NOT_A_SHARE
                else -> NetworkShareException.Reason.UNREACHABLE
            })
        } catch (_: SMBRuntimeException) {
            throw NetworkShareException(NetworkShareException.Reason.UNREACHABLE)
        } catch (_: IOException) {
            throw NetworkShareException(NetworkShareException.Reason.UNREACHABLE)
        }

        private fun closeAll(handles: List<AutoCloseable>) {
            for (handle in handles.asReversed()) runCatching { handle.close() }
        }
    }
}

/**
 * The address the player opens for an SMB file: a small HTTP/1.1 server on 127.0.0.1 that answers GET and HEAD
 * with byte ranges read from the share (Android's libmpv and ExoPlayer have no SMB protocol). Each file gets a
 * random 128-bit path token that expires, so another app on this device cannot reach a share by guessing, and
 * the login never appears in an address. Fail-soft: a bad request or a share error closes that one connection.
 */
class NetworkShareSmbRelay(
    private val open: (SmbTarget) -> SmbFileSource,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private class Grant(val target: SmbTarget, val expiresAtMs: Long)

    private val lock = Any()
    private val grants = LinkedHashMap<String, Grant>()
    private val random = SecureRandom()
    @Volatile private var server: ServerSocket? = null
    private val workers = Executors.newCachedThreadPool { task -> thread(start = false, isDaemon = true, name = "vx-smb-relay") { task.run() } }

    /** A loopback address that streams [target], or null when the listener cannot start. */
    fun address(target: SmbTarget): String? {
        val port = ensureListening() ?: return null
        val token = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        synchronized(lock) {
            val time = now()
            grants.entries.removeAll { it.value.expiresAtMs <= time }
            while (grants.size >= MAX_GRANTS) grants.remove(grants.keys.first())
            grants[token] = Grant(target, time + GRANT_LIFETIME_MS)
        }
        return "http://127.0.0.1:$port/$token/${NetworkSharePolicy.escapeSegment(target.name)}"
    }

    /** Stops listening and forgets every grant. */
    fun close() {
        synchronized(lock) {
            grants.clear()
            runCatching { server?.close() }
            server = null
        }
    }

    private fun ensureListening(): Int? = synchronized(lock) {
        server?.takeIf { !it.isClosed }?.let { return it.localPort }
        try {
            val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
            server = socket
            thread(isDaemon = true, name = "vx-smb-relay-accept") { acceptLoop(socket) }
            socket.localPort
        } catch (_: IOException) {
            null
        }
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try { socket.accept() } catch (_: IOException) { break }
            workers.execute { handle(client) }
        }
    }

    private fun handle(client: Socket) {
        try {
            client.soTimeout = HEADER_TIMEOUT_MS
            val header = readHeader(client.getInputStream()) ?: return reply(client, "400 Bad Request")
            val lines = header.split("\r\n")
            val parts = lines.first().split(' ')
            if (parts.size < 3) return reply(client, "400 Bad Request")
            val method = parts[0]
            if (method != "GET" && method != "HEAD") return reply(client, "405 Method Not Allowed")
            val token = parts[1].removePrefix("/").substringBefore('/')
            val target = synchronized(lock) { grants[token]?.takeIf { it.expiresAtMs > now() }?.target }
                ?: return reply(client, "404 Not Found")
            val rangeHeader = lines.drop(1).firstOrNull { it.startsWith("range:", ignoreCase = true) }?.substringAfter(':')?.trim()
            val source = try { open(target) } catch (_: Exception) { return reply(client, "502 Bad Gateway") }
            source.use { serve(client, method == "HEAD", rangeHeader, it, contentType(target.name)) }
        } catch (_: IOException) {
            // The player went away mid-transfer; nothing to report.
        } catch (_: NetworkShareException) {
            // The share failed mid-transfer; the player sees a short body and retries or reports it.
        } finally {
            runCatching { client.close() }
        }
    }

    private fun serve(client: Socket, headOnly: Boolean, rangeHeader: String?, source: SmbFileSource, type: String) {
        val size = source.size
        val range = when (val requested = byteRange(rangeHeader, size)) {
            null -> return reply(client, "416 Range Not Satisfiable", "Content-Range: bytes */$size\r\n")
            else -> requested
        }
        val partial = rangeHeader != null
        val head = buildString {
            append(if (partial) "HTTP/1.1 206 Partial Content\r\n" else "HTTP/1.1 200 OK\r\n")
            append("Content-Type: $type\r\nAccept-Ranges: bytes\r\n")
            if (partial) append("Content-Range: bytes ${range.first}-${range.last}/$size\r\n")
            append("Content-Length: ${if (range.isEmpty()) 0 else range.last - range.first + 1}\r\nConnection: close\r\n\r\n")
        }
        val out = client.getOutputStream()
        out.write(head.toByteArray(Charsets.US_ASCII))
        if (!headOnly && !range.isEmpty()) {
            val buffer = ByteArray(CHUNK_BYTES)
            var position = range.first
            while (position <= range.last) {
                val wanted = minOf(CHUNK_BYTES.toLong(), range.last - position + 1).toInt()
                val read = source.read(position, buffer, wanted)
                if (read <= 0) break
                out.write(buffer, 0, read)
                position += read
            }
        }
        out.flush()
    }

    private fun reply(client: Socket, status: String, extra: String = "") {
        runCatching {
            client.getOutputStream().apply {
                write("HTTP/1.1 $status\r\n${extra}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                flush()
            }
        }
    }

    /** The request header up to its blank line, bounded, or null when malformed, oversized or cut short. */
    private fun readHeader(input: InputStream): String? {
        val stream = BufferedInputStream(input)
        val text = StringBuilder()
        while (true) {
            val byte = stream.read()
            if (byte < 0 || text.length > MAX_HEADER_BYTES) return null
            text.append(byte.toChar())
            if (text.endsWith("\r\n\r\n")) return text.substring(0, text.length - 4)
        }
    }

    companion object {
        private const val MAX_GRANTS = 64
        private const val GRANT_LIFETIME_MS = 12L * 60 * 60 * 1000
        private const val HEADER_TIMEOUT_MS = 15_000
        private const val MAX_HEADER_BYTES = 16_384
        private const val CHUNK_BYTES = 256 * 1024

        /**
         * The bytes a request asks for: the whole file without a Range header, else one `bytes=start-[end]` or
         * suffix `bytes=-n` range clamped to the file. Null when unsatisfiable (or a multi-range, which players
         * never send). An empty file answers its whole (empty) range.
         */
        internal fun byteRange(header: String?, size: Long): LongRange? {
            if (header == null) return 0L until size
            val spec = header.removePrefix("bytes=").takeIf { header.startsWith("bytes=") && !it.contains(',') } ?: return null
            val first = spec.substringBefore('-').trim()
            val last = spec.substringAfter('-', "").trim()
            if (first.isEmpty()) {
                val suffix = last.toLongOrNull()?.takeIf { it > 0 } ?: return null
                return if (size == 0L) null else maxOf(0L, size - suffix)..(size - 1)
            }
            val start = first.toLongOrNull()?.takeIf { it >= 0 } ?: return null
            val end = if (last.isEmpty()) size - 1 else last.toLongOrNull()?.takeIf { it >= start } ?: return null
            if (start >= size) return null
            return start..minOf(end, size - 1)
        }

        /** The player only needs a hint; it sniffs the container either way. */
        internal fun contentType(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
            "mkv" -> "video/x-matroska"
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "webm" -> "video/webm"
            "avi" -> "video/x-msvideo"
            "ts", "m2ts", "mts" -> "video/mp2t"
            else -> "application/octet-stream"
        }
    }
}
