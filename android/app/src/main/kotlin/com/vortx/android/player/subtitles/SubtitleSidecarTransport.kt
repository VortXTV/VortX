package com.vortx.android.player.subtitles

import android.content.Context
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.net.InetAddress
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Headerless, bounded transport for an untrusted external subtitle.  It never hands a remote URL to a
 * playback engine: every accepted sidecar is copied to the app cache with an extension selected from actual
 * text, then the local file is mounted. DNS is resolved once per hop and the exact vetted addresses are the
 * only addresses the TLS client may connect to; OkHttp still verifies the original HTTPS hostname.
 */
internal object SubtitleSidecarTransport {
    private const val MAX_BYTES = 1024 * 1024
    private const val MAX_REDIRECTS = 3
    private const val TIMEOUT_MS = 12_000L

    suspend fun fetch(context: Context, rawUrl: String, namespace: String): String? {
        var url = rawUrl.toHttpUrlOrNull()?.takeIf(::isAllowed) ?: return null
        repeat(MAX_REDIRECTS + 1) {
            val addresses = publicAddresses(url.host) ?: return null
            val client = clientFor(url.host, addresses)
            val response = runCatching {
                client.newCall(
                    Request.Builder().url(url).header("Accept-Encoding", "identity").get().build(),
                ).execute()
            }.getOrNull() ?: return null
            response.use { reply ->
                if (reply.isRedirect) {
                    val next = reply.header("Location")?.let { url.resolve(it) }?.takeIf(::isAllowed) ?: return null
                    url = next
                    return@use
                }
                if (!reply.isSuccessful) return null
                val body = reply.body ?: return null
                if (body.contentLength() !in 1..MAX_BYTES) return null
                val bytes = body.byteStream().use { input ->
                    val out = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (out.size() + count > MAX_BYTES) return null
                        out.write(buffer, 0, count)
                    }
                    out.toByteArray()
                }
                val extension = formatFrom(bytes, reply.header("Content-Type")) ?: return null
                val directory = File(context.cacheDir, "subtitle-sidecars/$namespace")
                if (!directory.exists() && !directory.mkdirs()) return null
                val name = sha256(rawUrl) + "." + extension
                val target = File(directory, name)
                val tmp = File.createTempFile("subtitle-", ".tmp", directory)
                return try {
                    tmp.outputStream().use { it.write(bytes) }
                    if (tmp.renameTo(target)) target.absolutePath else null
                } finally {
                    if (tmp.exists()) tmp.delete()
                }
            }
            // only reached after a redirect; the next iteration performs a fresh DNS/TLS validation.
        }
        return null
    }

    fun clear(context: Context) {
        File(context.cacheDir, "subtitle-sidecars").deleteRecursively()
    }

    private fun clientFor(host: String, addresses: List<InetAddress>): OkHttpClient = OkHttpClient.Builder()
        .dns(object : Dns {
            override fun lookup(hostname: String): List<InetAddress> =
                if (hostname.equals(host, true)) addresses else throw java.net.UnknownHostException(hostname)
        })
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .readTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .callTimeout(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        .build()

    private fun isAllowed(url: okhttp3.HttpUrl): Boolean =
        url.scheme == "https" && url.username.isEmpty() && url.password.isEmpty() && publicAddresses(url.host) != null

    private fun publicAddresses(host: String): List<InetAddress>? = runCatching {
        InetAddress.getAllByName(host).toList().takeIf { it.isNotEmpty() && it.all(::isPublic) }
    }.getOrNull()

    private fun isPublic(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
            address.isSiteLocalAddress || address.isMulticastAddress) return false
        val bytes = address.address
        if (bytes.size == 4) {
            val a = bytes[0].toInt() and 0xff
            val b = bytes[1].toInt() and 0xff
            if (a == 0 || a >= 224 || a == 127 || a == 10 || a == 169 && b == 254 ||
                a == 172 && b in 16..31 || a == 192 && b == 168) return false
        }
        // IPv4-mapped IPv6 inherits the IPv4 policy above rather than being treated as public by accident.
        if (bytes.size == 16 && bytes.take(10).all { it == 0.toByte() } && bytes[10] == 0xff.toByte() && bytes[11] == 0xff.toByte()) {
            return isPublic(InetAddress.getByAddress(bytes.copyOfRange(12, 16)))
        }
        return true
    }

    private fun formatFrom(bytes: ByteArray, contentType: String?): String? {
        val text = bytes.toString(Charsets.UTF_8).trimStart()
        return when {
            text.startsWith("WEBVTT") || contentType?.contains("vtt", true) == true -> "vtt"
            text.startsWith("[Script Info]", true) || text.contains("\nDialogue:", true) || contentType?.contains("ass", true) == true -> "ass"
            text.startsWith("<?xml", true) || text.startsWith("<tt", true) || contentType?.contains("ttml", true) == true -> "ttml"
            Regex("\\d{2}:\\d{2}:\\d{2}[,.]\\d{3}\\s*-->" ).containsMatchIn(text) || contentType?.contains("subrip", true) == true -> "srt"
            else -> null
        }
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}
