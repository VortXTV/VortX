package com.vortx.android.usenet

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Legacy one-server credential shape. It remains available because old settings callers still use
 * [UsenetProviderStore.load] and [UsenetProviderStore.save]. New persistence uses the versioned list.
 */
internal data class UsenetProviderCredentials(
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val maxConnections: Int,
    val useSSL: Boolean,
) {
    val isValid: Boolean
        get() = UsenetProviderConfiguration.isBareHost(host) && username.isNotEmpty() && password.isNotEmpty() &&
            port in 1..65535 && maxConnections in 1..100 && useSSL

    /** Never includes a login or password. Safe for bounded diagnostics. */
    val nntpEndpoint: String
        get() = "${if (useSSL) "nntps" else "nntp"}://${host.trim()}:${port.coerceIn(1, 65535)}/${maxConnections.coerceIn(1, 100)}"

    override fun toString(): String =
        "UsenetProviderCredentials(host=${host.trim()}, port=$port, username=<redacted>, password=<redacted>, maxConnections=$maxConnections, useSSL=$useSSL)"

    fun toJson(): JSONObject = JSONObject()
        .put("host", host).put("port", port).put("username", username).put("password", password)
        .put("maxConnections", maxConnections).put("useSSL", useSSL)

    companion object {
        /** Strict legacy decode: absence/mistyped fields are corruption, not an empty configuration. */
        fun fromJson(json: JSONObject): UsenetProviderCredentials? = runCatching {
            UsenetProviderCredentials(
                host = json.requiredString("host"),
                port = json.requiredInt("port"),
                username = json.requiredString("username"),
                password = json.requiredString("password"),
                maxConnections = json.requiredInt("maxConnections"),
                useSSL = json.requiredBoolean("useSSL"),
            ).takeIf { it.isValid }
        }.getOrNull()
    }
}

/** One named saved NNTP account. Array order in [UsenetProviderServerList] is fallback priority. */
internal data class UsenetProviderServer(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val maxConnections: Int,
    val useSSL: Boolean,
    val enabled: Boolean = true,
) {
    val isValid: Boolean get() = credentials.isValid && id.isNotBlank() && name.trim().isNotEmpty()
    val credentials: UsenetProviderCredentials get() = UsenetProviderCredentials(host, port, username, password, maxConnections, useSSL)
    val redactedSummary: String get() = "${name.trim()} — ${host.trim()}:$port ${if (useSSL) "SSL" else "plain"} ${if (enabled) "on" else "off"}"

    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("name", name).put("host", host).put("port", port)
        .put("username", username).put("password", password).put("maxConnections", maxConnections)
        .put("useSSL", useSSL).put("enabled", enabled)

    companion object {
        const val LEGACY_ID = "legacy-usenet-provider"

        fun legacy(credentials: UsenetProviderCredentials): UsenetProviderServer = UsenetProviderServer(
            id = LEGACY_ID, name = credentials.host.trim(), host = credentials.host, port = credentials.port,
            username = credentials.username, password = credentials.password,
            maxConnections = credentials.maxConnections, useSSL = credentials.useSSL,
        )

        fun fromJson(json: JSONObject): UsenetProviderServer? = runCatching {
            UsenetProviderServer(
                id = json.requiredString("id"), name = json.requiredString("name"),
                host = json.requiredString("host"), port = json.requiredInt("port"),
                username = json.requiredString("username"), password = json.requiredString("password"),
                maxConnections = json.requiredInt("maxConnections"), useSSL = json.requiredBoolean("useSSL"),
                enabled = json.requiredBoolean("enabled"),
            ).takeIf { it.isValid }
        }.getOrNull()
    }
}

/** Versioned encrypted document. Missing is the only state represented by an empty list. */
internal data class UsenetProviderServerList(
    val version: Int = CURRENT_VERSION,
    val servers: List<UsenetProviderServer>,
) {
    val enabledServers: List<UsenetProviderServer> get() = servers.filter { it.enabled }
    val firstEnabledCredentials: UsenetProviderCredentials? get() = enabledServers.firstOrNull()?.credentials

    fun toJson(): JSONObject = JSONObject().put("version", version).put("servers", JSONArray().also { array -> servers.forEach { array.put(it.toJson()) } })

    companion object {
        const val CURRENT_VERSION = 2
        const val MAX_SERVERS = 16

        /** A version marker is authoritative: malformed/future documents cannot be treated as legacy. */
        fun decode(raw: String): UsenetProviderServerList? = runCatching {
            val document = JSONObject(raw)
            if (document.has("version")) {
                if (document.requiredInt("version") != CURRENT_VERSION) return null
                val array = document.requiredArray("servers")
                val servers = ArrayList<UsenetProviderServer>(array.length())
                for (index in 0 until array.length()) {
                    val server = UsenetProviderServer.fromJson(array.requiredObject(index)) ?: return@runCatching null
                    servers += server
                }
                UsenetProviderServerList(servers = servers).takeIf(::isValid)
            } else {
                UsenetProviderCredentials.fromJson(document)?.let { UsenetProviderServerList(servers = listOf(UsenetProviderServer.legacy(it))) }
            }
        }.getOrNull()

        fun isValid(list: UsenetProviderServerList): Boolean =
            list.version == CURRENT_VERSION && list.servers.size <= MAX_SERVERS &&
                list.servers.all { it.isValid } && list.servers.map { it.id }.toSet().size == list.servers.size
    }
}

/** Pure validation helpers shared by settings, persistence and resolver policy. */
internal object UsenetProviderConfiguration {
    fun isBareHost(raw: String): Boolean {
        val host = raw.trim()
        if (host.isEmpty() || host.length > 253 || host.startsWith('.') || host.endsWith('.') ||
            host.any { !it.isLetterOrDigit() && it != '.' && it != '-' }) return false
        val labels = host.split('.')
        return labels.isNotEmpty() && labels.all { label ->
            label.isNotEmpty() && label.length <= 63 && !label.startsWith('-') && !label.endsWith('-')
        }
    }
}

private fun JSONObject.requiredString(key: String): String = get(key) as? String ?: throw IllegalArgumentException("$key must be a string")
private fun JSONObject.requiredInt(key: String): Int {
    val number = get(key) as? Number ?: throw IllegalArgumentException("$key must be an integer")
    val decimal = number.toDouble()
    val whole = number.toLong()
    return whole.takeIf {
        decimal.isFinite() && decimal == whole.toDouble() && it in Int.MIN_VALUE..Int.MAX_VALUE
    }?.toInt() ?: throw IllegalArgumentException("$key must be an integer")
}
private fun JSONObject.requiredBoolean(key: String): Boolean = get(key) as? Boolean ?: throw IllegalArgumentException("$key must be a boolean")
private fun JSONObject.requiredArray(key: String): JSONArray = get(key) as? JSONArray ?: throw IllegalArgumentException("$key must be an array")
private fun JSONArray.requiredObject(index: Int): JSONObject = get(index) as? JSONObject ?: throw IllegalArgumentException("server must be an object")
