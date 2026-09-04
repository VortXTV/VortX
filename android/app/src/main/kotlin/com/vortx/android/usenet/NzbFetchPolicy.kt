package com.vortx.android.usenet

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.URI
import java.net.URL

/** Testable SSRF and size boundary used for every initial NZB URL and redirect hop. */
internal object NzbFetchPolicy {
    const val MAX_BYTES = 4 * 1024 * 1024

    fun checkedUrl(raw: String, resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName): URL {
        val uri = try { URI(raw) } catch (_: Exception) { throw UsenetLocalResolver.ResolveException("invalid NZB URL") }
        if (uri.scheme?.lowercase() != "https" || uri.userInfo != null || uri.host.isNullOrBlank()) {
            throw UsenetLocalResolver.ResolveException("NZB URL must be HTTPS without user info")
        }
        val addresses = try { resolve(uri.host) } catch (_: Exception) {
            throw UsenetLocalResolver.ResolveException("NZB host cannot be resolved")
        }
        if (addresses.isEmpty() || addresses.any(::isPrivateAddress)) {
            throw UsenetLocalResolver.ResolveException("NZB host is not public")
        }
        return uri.toURL()
    }

    fun redirect(current: URL, location: String, resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName): URL =
        checkedUrl(URL(current, location).toExternalForm(), resolve)

    fun readBoundedUtf8(input: InputStream, limit: Int = MAX_BYTES): String {
        val output = ByteArrayOutputStream(minOf(limit, 8 * 1024))
        val buffer = ByteArray(8 * 1024)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > limit) throw UsenetLocalResolver.ResolveException("NZB exceeds size limit")
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }

    private fun isPrivateAddress(address: InetAddress): Boolean =
        address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
            address.isSiteLocalAddress || address.hostAddress?.startsWith("fc", true) == true ||
            address.hostAddress?.startsWith("fd", true) == true
}
