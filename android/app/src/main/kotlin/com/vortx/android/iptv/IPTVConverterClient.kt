package com.vortx.android.iptv

import org.json.JSONObject

/// Client for the hosted IPTV converter at `iptv.vortx.tv`. Kotlin port of the Apple
/// `app/SourcesShared/IPTVConverterClient.swift`, with the SAME worker endpoints and the SAME request /
/// response shapes (derived from the Swift client, not invented).
///
/// It registers a user's M3U playlist or Xtream Codes login with the worker, which stores the (encrypted)
/// credentials server-side and returns an opaque slug; the app then installs
/// `https://iptv.vortx.tv/c/<slug>/manifest.json` as a normal add-on so the channels flow through the
/// existing catalog / Live pipeline engine-side. Removing a playlist calls `/c/<slug>/revoke` so the slug is
/// destroyed server-side, not just forgotten locally.
///
/// GATING: `iptv.vortx.tv` is in [com.vortx.android.net.VortXEdgeAuth]'s gated-host set, so every request
/// here is HMAC-signed by [IPTVHttp] (a safe no-op without a provisioned secret, so this works today and
/// tightens later without a client change), mirroring the Apple `VortXEdgeAuth.sign(&req)`.
///
/// The request-shape builders ([registerBodyM3U] / [registerBodyXtream]), the path builders, and the result
/// mapper ([mapRegisterResult]) are pure and `internal` so they can be unit-tested without the network.
object IPTVConverterClient {

    /// A user-facing error from a register attempt. Extends [Exception] so it rides Kotlin's [Result] failure
    /// channel (the repository idiom), while [message] carries copy matching the Apple `ClientError`.
    sealed class ClientError(message: String) : Exception(message) {
        /// The service returned a non-JSON / malformed body or a 2xx without a slug + manifest URL.
        object BadResponse : ClientError("The IPTV service returned an unexpected response.")

        /// The worker's `xtream_auth_failed` code: the Xtream credentials did not sign in.
        object XtreamAuthFailed :
            ClientError("Those Xtream details did not sign in. Check the server, username, and password.")

        /// Any other non-2xx: the worker's error code (or the raw status when it sent none).
        class Server(val code: String) : ClientError("The IPTV service could not add this playlist ($code).")

        /// A transport failure (offline / DNS / TLS / timeout): no HTTP response reached the client.
        object Network : ClientError("Could not reach the IPTV service. Check your connection and try again.")
    }

    /// The base URL of the converter worker (Apple `IPTVConverterClient.baseURL`).
    const val BASE_URL = "https://iptv.vortx.tv"

    // MARK: - Register

    /// Register an M3U playlist. [xmltvUrl] is an optional separate EPG source; [name] an optional label.
    /// Mirrors Apple `registerM3U(url:xmltvURL:name:)`.
    suspend fun registerM3U(url: String, xmltvUrl: String?, name: String?): Result<IPTVRegistration> =
        register(registerBodyM3U(url, xmltvUrl, name))

    /// Register an Xtream Codes login (the worker validates the credentials before returning a slug).
    /// Mirrors Apple `registerXtream(host:user:pass:xmltvURL:name:)`.
    suspend fun registerXtream(
        host: String,
        user: String,
        pass: String,
        xmltvUrl: String?,
        name: String?,
    ): Result<IPTVRegistration> = register(registerBodyXtream(host, user, pass, xmltvUrl, name))

    private suspend fun register(body: Map<String, Any?>): Result<IPTVRegistration> {
        val response = IPTVHttp.request(
            method = "POST",
            urlString = "$BASE_URL/$REGISTER_PATH",
            body = bodyToJson(body),
            timeoutMs = IPTVHttp.REGISTER_TIMEOUT_MS,
        )
        val obj = parseJsonObject(response.body)
        return mapRegisterResult(
            status = response.status,
            slug = obj?.optString("slug")?.ifEmpty { null },
            manifestUrl = obj?.optString("manifest_url")?.ifEmpty { null },
            errorCode = obj?.optString("error")?.ifEmpty { null },
        )
    }

    // MARK: - Revoke

    /// Revoke a slug server-side so its playlist can no longer be served. Fail-soft: a failure here is not
    /// surfaced (the add-on is uninstalled either way). Returns true on a clean revoke. Mirrors Apple
    /// `revoke(slug:)`.
    suspend fun revoke(slug: String): Boolean {
        if (slug.isEmpty()) return false
        val response = IPTVHttp.request(
            method = "POST",
            urlString = "$BASE_URL/${revokePath(slug)}",
            timeoutMs = IPTVHttp.REVOKE_TIMEOUT_MS,
        )
        return response.isSuccess
    }

    // MARK: - Pure request-shape + result seams (unit-tested)

    /// The worker's register path (Apple `baseURL.appendingPathComponent("register")`).
    internal const val REGISTER_PATH = "register"

    /// The worker's revoke path for a slug (Apple `baseURL/c/<slug>/revoke`). The slug is a worker-generated
    /// opaque capability token, so it is interpolated as a single already-safe path segment.
    internal fun revokePath(slug: String): String = "c/$slug/revoke"

    /// The M3U register body: `{"m3u_url": url}`, with `xmltv_url` and `name` added ONLY when non-empty
    /// (matches the Apple `registerM3U` body construction exactly). A [LinkedHashMap] so key order is stable
    /// for tests; the wire order is irrelevant to the worker.
    internal fun registerBodyM3U(url: String, xmltvUrl: String?, name: String?): LinkedHashMap<String, Any?> {
        val body = LinkedHashMap<String, Any?>()
        body["m3u_url"] = url
        if (!xmltvUrl.isNullOrEmpty()) body["xmltv_url"] = xmltvUrl
        if (!name.isNullOrEmpty()) body["name"] = name
        return body
    }

    /// The Xtream register body: `{"xtream": {"host": host, "user": user, "pass": pass}}`, with `xmltv_url`
    /// and `name` added ONLY when non-empty (matches the Apple `registerXtream` body construction exactly).
    internal fun registerBodyXtream(
        host: String,
        user: String,
        pass: String,
        xmltvUrl: String?,
        name: String?,
    ): LinkedHashMap<String, Any?> {
        val xtream = LinkedHashMap<String, Any?>()
        xtream["host"] = host
        xtream["user"] = user
        xtream["pass"] = pass
        val body = LinkedHashMap<String, Any?>()
        body["xtream"] = xtream
        if (!xmltvUrl.isNullOrEmpty()) body["xmltv_url"] = xmltvUrl
        if (!name.isNullOrEmpty()) body["name"] = name
        return body
    }

    /// Map a worker response (status + the fields the network path extracted) to the typed result. Pure, so
    /// the whole decision table is unit-tested without a socket. Mirrors the Apple `register` result branch:
    ///   - status 0 (transport failure) -> [ClientError.Network]
    ///   - 2xx with slug + manifest URL  -> success
    ///   - 2xx missing either field      -> [ClientError.BadResponse]
    ///   - non-2xx `xtream_auth_failed`  -> [ClientError.XtreamAuthFailed]
    ///   - any other non-2xx            -> [ClientError.Server] (the worker's code, or the raw status)
    internal fun mapRegisterResult(
        status: Int,
        slug: String?,
        manifestUrl: String?,
        errorCode: String?,
    ): Result<IPTVRegistration> {
        if (status == 0) return Result.failure(ClientError.Network)
        if (status in 200..299) {
            if (slug.isNullOrEmpty() || manifestUrl.isNullOrEmpty()) return Result.failure(ClientError.BadResponse)
            return Result.success(IPTVRegistration(slug = slug, manifestUrl = manifestUrl))
        }
        val code = errorCode?.takeIf { it.isNotEmpty() } ?: status.toString()
        if (code == "xtream_auth_failed") return Result.failure(ClientError.XtreamAuthFailed)
        return Result.failure(ClientError.Server(code))
    }

    // MARK: - JSON (network path only)

    /// Serialize an ordered body map to a JSON string, converting one level of nested map (the `xtream`
    /// object) into a nested `JSONObject`. Kept off the pure builders above so the request-shape tests never
    /// need `org.json` on the classpath.
    private fun bodyToJson(body: Map<String, Any?>): String {
        val root = JSONObject()
        for ((key, value) in body) {
            when (value) {
                null -> {}
                is Map<*, *> -> {
                    val nested = JSONObject()
                    for ((k, v) in value) if (v != null) nested.put(k.toString(), v)
                    root.put(key, nested)
                }
                else -> root.put(key, value)
            }
        }
        return root.toString()
    }

    private fun parseJsonObject(text: String): JSONObject? =
        if (text.isEmpty()) null else runCatching { JSONObject(text) }.getOrNull()
}
