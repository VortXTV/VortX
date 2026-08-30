package com.vortx.android.communityjs

import com.vortx.android.engine.PublicAddressPolicy
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Origin and redirect rules shared by provider fetch and provider-originated playback. */
internal object CommunityJsHttpPolicy {
    data class Origin(val scheme: String, val host: String, val port: Int)
    data class Redirect(
        val url: HttpUrl,
        val method: String,
        val body: ByteArray?,
    )

    private val safeTransportHeaders = setOf("accept", "range", "user-agent")
    private val forbiddenHeaders = setOf(
        "connection", "content-length", "host", "proxy-connection", "transfer-encoding", "upgrade",
    )

    fun admit(rawUrl: String): HttpUrl? = rawUrl.toHttpUrlOrNull()?.takeIf(::admit)

    fun admit(url: HttpUrl): Boolean = runCatching {
        if (url.scheme != "http" && url.scheme != "https") return false
        if (url.username.isNotEmpty() || url.password.isNotEmpty()) return false
        PublicAddressPolicy.requireLiteralPublicOrHostname(url.host)
        true
    }.getOrDefault(false)

    fun origin(url: HttpUrl): Origin = Origin(url.scheme, url.host.lowercase(), url.port)

    fun requestHeaders(root: HttpUrl, target: HttpUrl, providerHeaders: Map<String, String>): Map<String, String> {
        val sameOrigin = origin(root) == origin(target)
        if (!sameOrigin) return emptyMap()
        return providerHeaders.entries.mapNotNull { (name, value) ->
            val normalized = name.trim().lowercase()
            if (name.isBlank() || '\r' in name || '\n' in name || '\r' in value || '\n' in value) return@mapNotNull null
            if (normalized in forbiddenHeaders) return@mapNotNull null
            name to value
        }.toMap()
    }

    fun transportHeaders(headers: Map<String, String>): Map<String, String> = headers.entries.mapNotNull { (name, value) ->
        val normalized = name.trim().lowercase()
        if (normalized !in safeTransportHeaders || '\r' in value || '\n' in value) return@mapNotNull null
        name to value
    }.toMap()

    fun redirect(
        root: HttpUrl,
        current: HttpUrl,
        location: String,
        status: Int,
        method: String,
        body: ByteArray?,
    ): Redirect? {
        val target = current.resolve(location)?.takeIf(::admit) ?: return null
        if (current.isHttps && !target.isHttps) return null
        var nextMethod = method
        var nextBody = body
        when (status) {
            303 -> if (method != "HEAD") { nextMethod = "GET"; nextBody = null }
            301, 302 -> if (method == "POST") { nextMethod = "GET"; nextBody = null }
            307, 308 -> Unit
            else -> return null
        }
        if (origin(root) != origin(target) && nextBody != null) return null
        return Redirect(target, nextMethod, nextBody)
    }
}
