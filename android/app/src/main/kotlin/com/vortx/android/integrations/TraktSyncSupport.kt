package com.vortx.android.integrations

import kotlinx.coroutines.delay

internal object TraktSyncSupport {
    fun headers(token: String): Map<String, String> = mapOf(
        "Content-Type" to "application/json",
        "trakt-api-version" to "2",
        "trakt-api-key" to com.vortx.android.BuildConfig.TRAKT_CLIENT_ID.trim(),
        "Authorization" to "Bearer $token",
    )

    suspend fun request(
        method: String,
        path: String,
        body: String? = null,
        attempts: Int = 4,
    ): IntegrationsHttp.Response {
        var response = IntegrationsHttp.Response(0, "")
        repeat(attempts) { attempt ->
            val token = TraktAuth.validToken()
            response = IntegrationsHttp.request(
                method = method,
                urlString = "${TraktAuth.API_BASE}$path",
                headers = headers(token),
                body = body,
            )
            if (response.status != 429 && response.status != 0 && response.status !in 500..599) return response
            if (attempt + 1 < attempts) delay((1L shl attempt) * 1_000L)
        }
        return response
    }
}
