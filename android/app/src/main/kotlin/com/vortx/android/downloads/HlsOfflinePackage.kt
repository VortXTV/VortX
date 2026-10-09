package com.vortx.android.downloads

import com.vortx.android.engine.PublicAddressPolicy
import com.vortx.android.engine.buildAddonManifestClient
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

internal data class HlsOfflinePackageResult(
    val playlistFile: File,
    val manifestFile: File,
    /** Includes the playlist, every media/key/map file, and the completion manifest. */
    val totalBytes: Long,
    internal val sourceSha256: String,
)

/** A transport seam for literal-loopback HTTP fixtures; production always uses public-address DNS. */
internal interface HlsOfflineTransport {
    fun validate(url: HttpUrl)
    fun execute(request: Request): Response
}

private class HlsOfflinePublicTransport : HlsOfflineTransport {
    private val client = buildAddonManifestClient(30_000).newBuilder()
        .callTimeout(120, TimeUnit.SECONDS)
        .retryOnConnectionFailure(false)
        .build()

    override fun validate(url: HttpUrl) = PublicAddressPolicy.requireLiteralPublicOrHostname(url.host)
    override fun execute(request: Request): Response = client.newCall(request).execute()
}

/**
 * Owns only a caller-validated staging directory. The caller must serialize [mutateFile] with its
 * generation/lifecycle lock. Every file creation, deletion, write, and sync is inside that callback;
 * its stale-generation exception is intentionally allowed to escape unchanged.
 */
internal class HlsOfflinePackageDownloader(
    private val transport: HlsOfflineTransport = HlsOfflinePublicTransport(),
) {
    /** Recovers a fully published package after a crash between directory rename and index commit. */
    fun completedPackage(
        directory: File,
        rootUrl: String,
        headers: Map<String, String>,
        ensureCurrent: () -> Unit = {},
    ): HlsOfflinePackageResult? {
        ensureCurrent()
        val root = rootUrl.toHttpUrlOrNull() ?: return null
        validate(root)
        val result = HlsOfflinePackage.verify(directory, ensureCurrent = ensureCurrent) ?: return null
        ensureCurrent()
        return result.takeIf { it.sourceSha256 == sourceFingerprint(root, headers) }
    }

    fun download(
        rootUrl: String,
        headers: Map<String, String>,
        directory: File,
        ensureCurrent: () -> Unit,
        mutateFile: (() -> Unit) -> Unit,
        progress: (Long) -> Unit = {},
    ): HlsOfflinePackageResult {
        ensureCurrent()
        val root = rootUrl.toHttpUrlOrNull() ?: throw HlsOfflineException("Invalid HLS source URL")
        validate(root)
        val sourceSha256 = sourceFingerprint(root, headers)
        HlsOfflinePackage.verify(directory, ensureCurrent = ensureCurrent)?.let { existing ->
            if (existing.sourceSha256 == sourceSha256) {
                ensureCurrent()
                progress(existing.totalBytes)
                return existing
            }
        }
        // A partial is not a resume token: no representation identity exists for its remaining segments.
        mutateFile {
            HlsOfflinePackage.requireDirectory(directory, mayBeMissing = true)
            checkHls(HlsOfflinePackage.safeDelete(directory), "Unable to reset incomplete HLS package")
            checkHls(directory.mkdir(), "Unable to create HLS package directory")
            restrictPermissions(directory, isDirectory = true)
        }
        progress(0)
        val media = loadMedia(root, headers, ensureCurrent)
        val evidence = mutableListOf<HlsOfflineFileEvidence>()
        var written = 0L
        for (asset in media.assets) {
            ensureCurrent()
            val assetLimit = when (asset.kind) {
                HlsOfflineAssetKind.KEY -> 16L
                HlsOfflineAssetKind.MAP -> 64L * 1024 * 1024
                HlsOfflineAssetKind.SEGMENT -> 512L * 1024 * 1024
            }
            checkHls(asset.range == null || asset.range.length <= assetLimit, "HLS resource exceeds the offline size limit")
            val file = HlsOfflinePackage.child(directory, asset.fileName)
            val receipt = fetch(asset.url, root, headers, asset.range, ensureCurrent) { response, _ ->
                val body = response.body ?: throw HlsOfflineException("HLS resource has no body")
                if (asset.kind != HlsOfflineAssetKind.KEY) requireMediaContentType(response.header("Content-Type"))
                val declared = body.contentLength()
                val expected = asset.range?.length ?: declared.takeIf { it >= 0 }
                checkHls(declared <= assetLimit && (expected == null || expected <= assetLimit), "HLS resource exceeds the offline size limit")
                if (asset.range != null) {
                    checkHls(declared < 0 || declared == asset.range.length, "HLS range Content-Length does not match")
                }
                val digest = MessageDigest.getInstance("SHA-256")
                var output: FileOutputStream? = null
                var length = 0L
                try {
                    mutateFile {
                        output = FileOutputStream(HlsOfflinePackage.child(directory, file.name))
                        restrictPermissions(file)
                    }
                    body.byteStream().buffered().use { input ->
                        // A segment endpoint must not smuggle a second network playlist into the local package.
                        // Read a bounded prefix before committing bytes, including across fragmented HTTP reads.
                        input.mark(512)
                        val prefix = readPrefix(input, ensureCurrent)
                        input.reset()
                        if (asset.kind != HlsOfflineAssetKind.KEY) requireMediaPrefix(prefix)
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            ensureCurrent()
                            val count = input.read(buffer)
                            if (count < 0) break
                            checkHls(length <= assetLimit - count && written <= HlsOfflinePackage.MAX_PACKAGE_BYTES - count, "HLS package exceeds the offline size limit")
                            mutateFile { output!!.write(buffer, 0, count) }
                            digest.update(buffer, 0, count)
                            length += count
                            written += count
                            ensureCurrent()
                            progress(written)
                        }
                    }
                    checkHls(length > 0 && (expected == null || length == expected), "HLS resource body is incomplete")
                    checkHls(asset.kind != HlsOfflineAssetKind.KEY || length == 16L, "AES-128 key must contain exactly 16 bytes")
                    mutateFile { output!!.fd.sync() }
                } finally {
                    // FileOutputStream is unbuffered: close releases the descriptor without committing more bytes.
                    output?.close()
                }
                HlsOfflineFileEvidence(file.name, length, digest.digest().hex())
            }
            evidence += receipt
        }
        val playlistBytes = media.localPlaylist.toByteArray(Charsets.UTF_8)
        writeSmallFile(directory, HlsOfflinePackage.PLAYLIST_FILE_NAME, playlistBytes, mutateFile)
        evidence += HlsOfflineFileEvidence(HlsOfflinePackage.PLAYLIST_FILE_NAME, playlistBytes.size.toLong(), sha256(playlistBytes))
        val manifest = JSONObject()
            .put("version", 1)
            .put("playlist", HlsOfflinePackage.PLAYLIST_FILE_NAME)
            .put("sourceSha256", sourceSha256)
            .put("files", JSONArray().apply {
                evidence.forEach { entry ->
                    put(JSONObject().put("name", entry.name).put("length", entry.length).put("sha256", entry.sha256))
                }
            })
            .toString().toByteArray(Charsets.UTF_8)
        checkHls(manifest.size <= HlsOfflinePackage.MAX_MANIFEST_BYTES, "HLS completion manifest is too large")
        ensureCurrent()
        writeSmallFile(directory, HlsOfflinePackage.MANIFEST_FILE_NAME, manifest, mutateFile)
        val result = HlsOfflinePackage.verify(directory, ensureCurrent = ensureCurrent)
            ?: throw HlsOfflineException("HLS package failed completion verification")
        ensureCurrent()
        progress(result.totalBytes)
        return result
    }

    private fun loadMedia(root: HttpUrl, headers: Map<String, String>, ensureCurrent: () -> Unit): HlsOfflinePlaylist.Media {
        var current = root
        val seen = mutableSetOf<HttpUrl>()
        repeat(4) {
            checkHls(seen.add(current), "HLS playlist recursion detected")
            val parsed = fetch(current, root, headers, null, ensureCurrent) { response, finalUrl ->
                checkHls(seen.add(finalUrl) || finalUrl == current, "HLS playlist redirect recursion detected")
                val body = response.body ?: throw HlsOfflineException("HLS playlist has no body")
                checkHls(body.contentLength() <= HlsOfflinePlaylistParser.MAX_PLAYLIST_BYTES, "HLS playlist is too large")
                val bytes = body.byteStream().use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        ensureCurrent()
                        val count = input.read(buffer)
                        if (count < 0) break
                        checkHls(output.size() <= HlsOfflinePlaylistParser.MAX_PLAYLIST_BYTES - count, "HLS playlist is too large")
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                HlsOfflinePlaylistParser.parse(decodeUtf8(bytes), finalUrl)
            }
            when (parsed) {
                is HlsOfflinePlaylist.Media -> return parsed
                is HlsOfflinePlaylist.Master -> current = parsed.selectedVariant
            }
        }
        throw HlsOfflineException("HLS playlist nesting limit exceeded")
    }

    private fun <T> fetch(
        url: HttpUrl,
        root: HttpUrl,
        suppliedHeaders: Map<String, String>,
        range: HlsOfflineByteRange?,
        ensureCurrent: () -> Unit,
        consume: (Response, HttpUrl) -> T,
    ): T {
        var current = url
        var credentialsAllowed = sameOrigin(root, url)
        val visited = mutableSetOf<HttpUrl>()
        repeat(6) { redirectCount ->
            ensureCurrent()
            validate(current)
            checkHls(visited.add(current), "HLS redirect loop detected")
            val builder = Request.Builder().url(current).get()
            suppliedHeaders.forEach { (name, value) ->
                val normalized = name.lowercase(java.util.Locale.ROOT)
                if (normalized !in FORBIDDEN_HEADERS && (credentialsAllowed || normalized in CROSS_ORIGIN_HEADERS)) {
                    builder.header(name, value)
                }
            }
            builder.header("Accept-Encoding", "identity")
            if (range != null) builder.header("Range", "bytes=${range.offset}-${range.endInclusive}")
            transport.execute(builder.build()).use { response ->
                ensureCurrent()
                if (response.code in REDIRECT_CODES) {
                    checkHls(redirectCount < 5, "HLS redirect limit exceeded")
                    val target = response.header("Location")?.let(current::resolve)
                        ?: throw HlsOfflineException("HLS redirect has no valid target")
                    checkHls(current.scheme != "https" || target.scheme == "https", "HLS HTTPS downgrade is forbidden")
                    credentialsAllowed = credentialsAllowed && sameOrigin(current, target)
                    current = target
                } else {
                    if (response.code != if (range == null) 200 else 206) {
                        throw DownloadHttpStatusException(response.code, "Unexpected HLS response")
                    }
                    checkHls(response.header("Content-Encoding").let { it == null || it.equals("identity", ignoreCase = true) }, "Encoded HLS response is not supported")
                    if (range != null) validateContentRange(response.header("Content-Range"), range)
                    return consume(response, current)
                }
            }
        }
        throw HlsOfflineException("HLS redirect limit exceeded")
    }

    private fun validate(url: HttpUrl) {
        checkHls(url.scheme in setOf("http", "https") && url.username.isEmpty() && url.password.isEmpty() && url.fragment == null, "Unsupported HLS URL")
        transport.validate(url)
    }

    private fun validateContentRange(value: String?, range: HlsOfflineByteRange) {
        val match = value?.let { Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+|\\*)").matchEntire(it) }
            ?: throw HlsOfflineException("HLS range response has no valid Content-Range")
        val start = match.groupValues[1].toLongOrNull()
        val end = match.groupValues[2].toLongOrNull()
        val total = match.groupValues[3]
        checkHls(start == range.offset && end == range.endInclusive, "HLS server returned a different byte range")
        checkHls(total == "*" || total.toLongOrNull()?.let { it > range.endInclusive } == true, "Invalid HLS range total")
    }

    private fun writeSmallFile(directory: File, name: String, bytes: ByteArray, mutateFile: (() -> Unit) -> Unit) {
        mutateFile {
            FileOutputStream(HlsOfflinePackage.child(directory, name)).use { output ->
                restrictPermissions(File(directory, name))
                output.write(bytes)
                output.fd.sync()
            }
        }
    }

    private fun sameOrigin(a: HttpUrl, b: HttpUrl): Boolean = a.scheme == b.scheme && a.host == b.host && a.port == b.port

    private fun sourceFingerprint(url: HttpUrl, headers: Map<String, String>): String = sha256(
        JSONObject().put("url", url.toString()).put("headers", JSONArray().apply {
            headers.toSortedMap().forEach { (name, value) -> put(JSONArray().put(name).put(value)) }
        }).toString().toByteArray(Charsets.UTF_8),
    )

    private companion object {
        val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
        val CROSS_ORIGIN_HEADERS = setOf("user-agent", "accept", "accept-language")
        val FORBIDDEN_HEADERS = setOf("host", "connection", "proxy-authorization", "proxy-connection", "content-length", "transfer-encoding", "range", "accept-encoding", "if-range", "if-none-match", "if-modified-since")
    }
}

private data class HlsOfflineFileEvidence(val name: String, val length: Long, val sha256: String)

/** Filesystem-only checks are available for UI/playback; downloads/restarts must use fullHash=true. */
internal object HlsOfflinePackage {
    const val PLAYLIST_FILE_NAME = "index.m3u8"
    const val MANIFEST_FILE_NAME = "complete.json"
    const val MAX_MANIFEST_BYTES = 8 * 1024 * 1024
    const val MAX_PACKAGE_BYTES = 128L * 1024 * 1024 * 1024
    private val ASSET_NAME = Regex("(?:segment|key|map)-[0-9]{6}\\.bin")
    private val HASH = Regex("[0-9a-f]{64}")
    private val LOCAL_BASE = "https://offline.invalid/".toHttpUrlOrNull()!!

    fun isSafeFileName(name: String): Boolean = name == PLAYLIST_FILE_NAME || name == MANIFEST_FILE_NAME || ASSET_NAME.matches(name)

    fun verify(directory: File, fullHash: Boolean = true, ensureCurrent: () -> Unit = {}): HlsOfflinePackageResult? {
        // Do not put a caller cancellation callback inside runCatching: ownership loss must propagate unchanged.
        ensureCurrent()
        val entries = try {
            requireDirectory(directory)
            val manifest = child(directory, MANIFEST_FILE_NAME)
            checkHls(manifest.isFile && manifest.length() in 1..MAX_MANIFEST_BYTES.toLong(), "Missing HLS completion manifest")
            val json = JSONObject(decodeUtf8(manifest.readBytes()))
            checkHls(json.getInt("version") == 1 && json.getString("playlist") == PLAYLIST_FILE_NAME, "Invalid HLS completion manifest")
            val source = json.getString("sourceSha256")
            checkHls(HASH.matches(source), "Invalid HLS source evidence")
            val files = json.getJSONArray("files")
            checkHls(files.length() in 2..HlsOfflinePlaylistParser.MAX_ASSETS + 1, "Invalid HLS completion file count")
            val evidence = (0 until files.length()).map { index ->
                val value = files.getJSONObject(index)
                HlsOfflineFileEvidence(value.getString("name"), value.getLong("length"), value.getString("sha256"))
            }
            checkHls(evidence.map { it.name }.toSet().size == evidence.size, "Duplicate HLS completion entry")
            checkHls(evidence.all { isSafeFileName(it.name) && it.name != MANIFEST_FILE_NAME && it.length in 1..MAX_PACKAGE_BYTES && HASH.matches(it.sha256) }, "Invalid HLS completion entry")
            val children = directory.listFiles() ?: throw HlsOfflineException("Unreadable HLS directory")
            val evidenceNames = evidence.map { it.name }.toSet()
            checkHls(children.size == evidence.size + 1 && children.all { it.name == MANIFEST_FILE_NAME || it.name in evidenceNames }, "Unexpected HLS package files")
            val playlist = child(directory, PLAYLIST_FILE_NAME)
            checkHls(playlist.isFile && playlist.length() <= HlsOfflinePlaylistParser.MAX_PLAYLIST_BYTES, "Invalid local HLS playlist")
            val playlistText = decodeUtf8(playlist.readBytes())
            val parsed = HlsOfflinePlaylistParser.parse(playlistText, LOCAL_BASE) as? HlsOfflinePlaylist.Media
                ?: throw HlsOfflineException("Local HLS playlist is not media")
            val references = localReferences(playlistText)
            checkHls(references.isNotEmpty() && parsed.assets.all { it.range == null }, "Invalid local HLS references")
            checkHls(references.toSet() == evidence.map { it.name }.filter { it != PLAYLIST_FILE_NAME }.toSet(), "HLS completion does not cover playlist references")
            source to evidence
        } catch (_: Exception) {
            return null
        }
        var total = 0L
        for (entry in entries.second) {
            ensureCurrent()
            val file = try {
                child(directory, entry.name).also {
                    checkHls(it.isFile && it.length() == entry.length, "HLS resource length does not match")
                    checkHls(total <= MAX_PACKAGE_BYTES - entry.length, "HLS package is too large")
                }
            } catch (_: Exception) { return null }
            if (entry.name.startsWith("segment-") || entry.name.startsWith("map-")) {
                val input = try { file.inputStream() } catch (_: Exception) { return null }
                // UI checks still inspect a bounded prefix, preventing a login/error document from posing as media.
                // Cancellation remains outside exception conversion, including while the prefix is read.
                val prefix = input.use {
                    val buffer = ByteArray(512)
                    var length = 0
                    while (length < buffer.size) {
                        ensureCurrent()
                        val count = try { it.read(buffer, length, buffer.size - length) } catch (_: Exception) { return null }
                        if (count < 0) break
                        length += count
                    }
                    buffer.copyOf(length)
                }
                try { requireMediaPrefix(prefix) } catch (_: HlsOfflineException) { return null }
            }
            if (fullHash) {
                // Read exceptions mean corrupt/incomplete cache; cancellation from ensureCurrent must escape.
                val digest = MessageDigest.getInstance("SHA-256")
                val input = try { file.inputStream() } catch (_: Exception) { return null }
                input.use {
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        ensureCurrent()
                        val count = try { it.read(buffer) } catch (_: Exception) { return null }
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                }
                if (digest.digest().hex() != entry.sha256) return null
            }
            total += entry.length
        }
        val manifest = try { child(directory, MANIFEST_FILE_NAME) } catch (_: Exception) { return null }
        ensureCurrent()
        return HlsOfflinePackageResult(File(directory, PLAYLIST_FILE_NAME), manifest, total + manifest.length(), entries.first)
    }

    /** Never traverses symlinks or subdirectories; refuses unexpected files instead of deleting them. */
    fun safeDelete(directory: File): Boolean = try {
        requireDirectory(directory, mayBeMissing = true)
        if (!Files.exists(directory.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            true
        } else {
            val children = directory.listFiles() ?: throw HlsOfflineException("Unreadable HLS directory")
            checkHls(children.size <= HlsOfflinePlaylistParser.MAX_ASSETS + 2 && children.all { isSafeFileName(it.name) && !Files.isDirectory(it.toPath(), LinkOption.NOFOLLOW_LINKS) }, "Unexpected HLS package files")
            children.forEach { Files.delete(it.toPath()) }
            Files.delete(directory.toPath())
            true
        }
    } catch (_: Exception) { false }

    /** Includes partial files, but never follows a package/file symlink. */
    fun safeSize(directory: File): Long = try {
        requireDirectory(directory)
        val children = directory.listFiles() ?: throw HlsOfflineException("Unreadable HLS directory")
        checkHls(children.size <= HlsOfflinePlaylistParser.MAX_ASSETS + 2, "Too many HLS package files")
        children.fold(0L) { total, file ->
            checkHls(isSafeFileName(file.name) && !Files.isSymbolicLink(file.toPath()) && file.isFile, "Unexpected HLS package file")
            checkHls(file.length() <= MAX_PACKAGE_BYTES - total, "HLS package is too large")
            total + file.length()
        }
    } catch (_: Exception) { 0L }

    internal fun requireDirectory(directory: File, mayBeMissing: Boolean = false) {
        val absolute = directory.absoluteFile.toPath().normalize().toFile()
        checkHls(absolute == directory.canonicalFile && !Files.isSymbolicLink(directory.toPath()), "HLS package directory is redirected")
        checkHls(directory.isDirectory || (mayBeMissing && !Files.exists(directory.toPath(), LinkOption.NOFOLLOW_LINKS)), "Invalid HLS package directory")
    }

    internal fun child(directory: File, name: String): File {
        requireDirectory(directory)
        checkHls(isSafeFileName(name), "Unsafe HLS package filename")
        val file = File(directory, name)
        checkHls(file.canonicalFile.parentFile == directory.canonicalFile && !Files.isSymbolicLink(file.toPath()), "HLS package file is redirected")
        return file
    }

    private fun localReferences(text: String): List<String> {
        val references = mutableListOf<String>()
        text.lineSequence().filter { it.isNotEmpty() }.forEach { line ->
            val uri = when {
                !line.startsWith('#') -> line
                line.startsWith("#EXT-X-KEY:") || line.startsWith("#EXT-X-MAP:") -> HlsOfflinePlaylistParser.attributes(line.substringAfter(':'))["URI"]
                else -> null
            }
            if (uri != null) {
                checkHls(ASSET_NAME.matches(uri), "Local HLS playlist references a network or external file")
                references += uri
            }
        }
        return references
    }
}

private fun decodeUtf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
    .onMalformedInput(CodingErrorAction.REPORT)
    .onUnmappableCharacter(CodingErrorAction.REPORT)
    .decode(ByteBuffer.wrap(bytes)).toString()

private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).hex()
private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

private fun readPrefix(input: InputStream, ensureCurrent: () -> Unit): ByteArray {
    val buffer = ByteArray(512)
    var length = 0
    while (length < buffer.size) {
        ensureCurrent()
        val count = input.read(buffer, length, buffer.size - length)
        if (count < 0) break
        length += count
    }
    return buffer.copyOf(length)
}

private fun requireMediaContentType(value: String?) {
    val type = value?.substringBefore(';')?.trim()?.lowercase(java.util.Locale.ROOT).orEmpty()
    checkHls(
        !type.contains("mpegurl") && type !in setOf("text/html", "application/xhtml+xml", "text/xml", "application/xml", "application/dash+xml"),
        "HLS resource is a playlist or server error document",
    )
}

private fun requireMediaPrefix(prefix: ByteArray) {
    val text = String(prefix, Charsets.UTF_8).removePrefix("\uFEFF").trimStart().lowercase(java.util.Locale.ROOT)
    checkHls(!text.startsWith("#extm3u"), "HLS resource unexpectedly contains another playlist")
    checkHls(
        listOf("<?xml", "<!doctype", "<html", "<head", "<body", "<error", "<response", "<accessdenied", "<listbucketresult", "<mpd").none(text::startsWith),
        "HLS resource is an HTML/XML server error document",
    )
}

private fun restrictPermissions(file: File, isDirectory: Boolean = false) {
    checkHls(
        file.setReadable(false, false) && file.setWritable(false, false) && file.setExecutable(false, false) &&
            file.setReadable(true, true) && file.setWritable(true, true) && (!isDirectory || file.setExecutable(true, true)),
        "Unable to protect HLS package permissions",
    )
}
