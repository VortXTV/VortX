package com.vortx.android.usenet

/// A user's own USENET provider account, used to play a bare-NZB source ON DEVICE through the native NNTP
/// path (no debrid, no TorBox). Mirrors the Apple `UsenetProviderCredentials` (app/SourcesShared/
/// UsenetProvider.swift) field for field so a future cross-platform key sync lines up.
///
/// Every field is a credential and lives in the encrypted store ONLY (see [UsenetProviderStore]), never in
/// a plain preference or a backup. The whole value is JSON-encoded into a SINGLE encrypted entry, so
/// host/port/connections travel with the secret bytes and nothing about the account is ever written to a
/// plain preference. The password is never logged and never rendered back in plaintext.
internal data class UsenetProviderCredentials(
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val maxConnections: Int,
    val useSSL: Boolean,
) {
    /// A configured provider needs a host, a login, a password, and sane numeric bounds.
    val isValid: Boolean
        get() = host.trim().isNotEmpty() &&
            username.isNotEmpty() &&
            password.isNotEmpty() &&
            port in 1..65535 &&
            maxConnections in 1..100

    /// The `nntp(s)://user:pass@host:port/connections` server URL the NNTP client parses. The user and
    /// pass are percent-encoded down to alphanumerics so no `:` `@` `/` survives inside a segment; the
    /// connection count rides the final path segment exactly like the Apple nntpServerURL.
    val nntpServerURL: String
        get() {
            val scheme = if (useSSL) "nntps" else "nntp"
            val user = encodeComponent(username)
            val pass = encodeComponent(password)
            val cleanHost = host.trim()
            val boundedPort = port.coerceIn(1, 65535)
            val boundedConns = maxConnections.coerceIn(1, 100)
            return "$scheme://$user:$pass@$cleanHost:$boundedPort/$boundedConns"
        }

    private fun encodeComponent(value: String): String =
        value.map { char ->
            when {
                char.isLetterOrDigit() -> char.toString()
                else -> "%" + "%02X".format(char.code)
            }
        }.joinToString("")

    fun toJson(): org.json.JSONObject =
        org.json.JSONObject().put("host", host)
            .put("port", port)
            .put("username", username)
            .put("password", password)
            .put("maxConnections", maxConnections)
            .put("useSSL", useSSL)

    companion object {
        fun fromJson(json: org.json.JSONObject): UsenetProviderCredentials? = try {
            UsenetProviderCredentials(
                host = json.optString("host"),
                port = json.optInt("port", 0),
                username = json.optString("username"),
                password = json.optString("password"),
                maxConnections = json.optInt("maxConnections", 0),
                useSSL = json.optBoolean("useSSL", false),
            )
        } catch (_: Exception) {
            null
        }
    }
}