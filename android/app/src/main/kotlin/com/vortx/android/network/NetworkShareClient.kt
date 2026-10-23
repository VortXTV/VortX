package com.vortx.android.network

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Why a share could not be added or listed; [message] is the viewer-facing text (Apple `NetworkShareError`). */
class NetworkShareException(val reason: Reason) : Exception(reason.message) {
    enum class Reason(val message: String) {
        INVALID_ADDRESS("Enter an http:// or https:// address, like 192.168.1.20:5005/video."),
        UNAUTHORIZED("The share refused that username or password."),
        NOT_A_SHARE("That address answered, but not with a WebDAV share or a folder listing."),
        UNREACHABLE("Couldn't reach the share. Check the address and that this device is on the same network."),
        REDIRECTED_AWAY("The share sent this video to another address, so VortX won't send your login there."),
        CREDENTIAL_STORAGE("Couldn't save the password securely on this device."),
        SMB_SHARE_REQUIRED("Add the shared folder's name to the address, like smb://192.168.1.20/Movies."),
    }
}

/**
 * Talks to a share over HTTP (Apple `NetworkShareClient`). The login travels only in an Authorization header and
 * only to URLs inside the share's root. Redirects are followed by hand, and only within the root, so a
 * misconfigured or hostile server cannot bounce the request, or the password, to another host.
 */
class NetworkShareClient(private val http: OkHttpClient = DEFAULT_CLIENT) {
    data class Login(val username: String, val password: String)

    private sealed interface Outcome {
        data class Listing(val entries: List<NetworkShareEntry>) : Outcome
        data object Unauthorized : Outcome
        data object NotAListing : Outcome
        data object Unreachable : Outcome
    }

    /** WebDAV when the root answers PROPFIND with a multistatus body, else a web folder when it serves a listing. */
    suspend fun detect(root: String, login: Login): NetworkShareKind {
        when (propfind(root, root, login)) {
            is Outcome.Listing -> return NetworkShareKind.WEBDAV
            Outcome.Unauthorized -> throw NetworkShareException(NetworkShareException.Reason.UNAUTHORIZED)
            Outcome.Unreachable -> throw NetworkShareException(NetworkShareException.Reason.UNREACHABLE)
            Outcome.NotAListing -> Unit
        }
        return when (getIndex(root, root, login)) {
            is Outcome.Listing -> NetworkShareKind.HTTP
            Outcome.Unauthorized -> throw NetworkShareException(NetworkShareException.Reason.UNAUTHORIZED)
            Outcome.Unreachable -> throw NetworkShareException(NetworkShareException.Reason.UNREACHABLE)
            Outcome.NotAListing -> throw NetworkShareException(NetworkShareException.Reason.NOT_A_SHARE)
        }
    }

    /** The visible contents of [folder] (folders first, then videos). */
    suspend fun list(folder: String, kind: NetworkShareKind, root: String, login: Login): List<NetworkShareEntry> {
        val outcome = if (kind == NetworkShareKind.WEBDAV) propfind(folder, root, login) else getIndex(folder, root, login)
        return when (outcome) {
            is Outcome.Listing -> NetworkSharePolicy.visible(outcome.entries)
            Outcome.Unauthorized -> throw NetworkShareException(NetworkShareException.Reason.UNAUTHORIZED)
            Outcome.Unreachable -> throw NetworkShareException(NetworkShareException.Reason.UNREACHABLE)
            Outcome.NotAListing -> throw NetworkShareException(NetworkShareException.Reason.NOT_A_SHARE)
        }
    }

    /**
     * The address a player should open for [file]. The server's redirects are followed here, within the share only,
     * so the player starts at the final address and never carries the login to another host. HEAD first; a server
     * that refuses it gets a one-byte ranged GET whose body is never read.
     */
    suspend fun resolveForPlayback(file: String, root: String, login: Login): String = withContext(Dispatchers.IO) {
        if (!NetworkSharePolicy.isInside(file, root)) throw NetworkShareException(NetworkShareException.Reason.REDIRECTED_AWAY)
        var probe = probe(file, root, login, head = true)
        if (probe.first == 405 || probe.first == 501) probe = probe(file, root, login, head = false)
        when (probe.first) {
            401, 403 -> throw NetworkShareException(NetworkShareException.Reason.UNAUTHORIZED)
            in 300..399 -> throw NetworkShareException(NetworkShareException.Reason.REDIRECTED_AWAY)
            in 200..299 -> probe.second
            else -> throw NetworkShareException(NetworkShareException.Reason.UNREACHABLE)
        }
    }

    /** (status, final URL) for [file], following redirects only within the share. */
    private fun probe(file: String, root: String, login: Login, head: Boolean): Pair<Int, String> {
        var url = file
        repeat(MAX_REDIRECTS + 1) {
            val builder = Request.Builder().url(url)
            NetworkSharePolicy.headers(url, root, login.username, login.password).forEach { (name, value) -> builder.header(name, value) }
            val request = if (head) builder.head().build() else builder.header("Range", "bytes=0-0").get().build()
            val response = try { http.newCall(request).execute() } catch (_: IOException) {
                throw NetworkShareException(NetworkShareException.Reason.UNREACHABLE)
            }
            response.use {
                if (it.code !in 300..399) return it.code to url
                val next = it.header("Location")?.let { location -> runCatching { java.net.URI(url).resolve(location).toASCIIString() }.getOrNull() }
                if (next == null || !NetworkSharePolicy.isInside(next, root)) return it.code to url
                url = next
            }
        }
        return 310 to url
    }

    private suspend fun propfind(folder: String, root: String, login: Login): Outcome =
        perform(folder, root, login, method = "PROPFIND") { body, status, url ->
            if (status != 207) null else NetworkSharePolicy.parseWebDav(body, url, root)
        }

    private suspend fun getIndex(folder: String, root: String, login: Login): Outcome =
        perform(folder, root, login, method = "GET") { body, status, url ->
            if (status != 200 || !body.contains("<a ", ignoreCase = true)) null
            else NetworkSharePolicy.parseHtmlIndex(body, url, root)
        }

    private suspend fun perform(
        start: String,
        root: String,
        login: Login,
        method: String,
        parse: (body: String, status: Int, url: String) -> List<NetworkShareEntry>?,
    ): Outcome = withContext(Dispatchers.IO) {
        var url = start
        repeat(MAX_REDIRECTS + 1) {
            val request = runCatching { build(url, root, login, method) }.getOrNull() ?: return@withContext Outcome.Unreachable
            val response = try { http.newCall(request).execute() } catch (_: IOException) { return@withContext Outcome.Unreachable }
            response.use {
                when (it.code) {
                    401, 403 -> return@withContext Outcome.Unauthorized
                    in 300..399 -> {
                        val next = it.header("Location")?.let { location -> runCatching { java.net.URI(url).resolve(location).toASCIIString() }.getOrNull() }
                        if (next == null || !NetworkSharePolicy.isInside(next, root)) return@withContext Outcome.NotAListing
                        url = next
                    }
                    else -> {
                        val raw = it.body ?: return@withContext Outcome.Unreachable
                        val body = try { readCapped(raw) } catch (_: IOException) { return@withContext Outcome.Unreachable }
                            ?: return@withContext Outcome.NotAListing
                        val entries = parse(body, it.code, url) ?: return@withContext Outcome.NotAListing
                        return@withContext Outcome.Listing(entries)
                    }
                }
            }
        }
        Outcome.NotAListing
    }

    private fun build(url: String, root: String, login: Login, method: String): Request {
        val builder = Request.Builder().url(url)
        NetworkSharePolicy.headers(url, root, login.username, login.password).forEach { (name, value) -> builder.header(name, value) }
        return if (method == "PROPFIND") {
            builder.header("Depth", "1")
                .method("PROPFIND", NetworkSharePolicy.PROPFIND_BODY.toRequestBody("application/xml; charset=utf-8".toMediaType()))
                .build()
        } else {
            builder.header("Accept", "text/html").get().build()
        }
    }

    /** The body as text, or null when it exceeds [MAX_LISTING_BYTES]; a listing is never held beyond that. */
    private fun readCapped(body: okhttp3.ResponseBody): String? {
        if (body.contentLength() > MAX_LISTING_BYTES) return null
        val source = body.source()
        if (source.request(MAX_LISTING_BYTES + 1)) return null
        // Listings are read as UTF-8 only, the same text the WebDAV parser and its DOCTYPE check see.
        return source.buffer.readUtf8()
    }

    companion object {
        private const val MAX_REDIRECTS = 5
        private const val MAX_LISTING_BYTES = 8L * 1024 * 1024

        private val DEFAULT_CLIENT: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(15, TimeUnit.SECONDS)
                .build()
        }
    }
}
