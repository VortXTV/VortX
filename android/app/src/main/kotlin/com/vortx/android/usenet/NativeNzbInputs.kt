package com.vortx.android.usenet

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale

/** Transient transport inputs, never a preference/archive representation. Keep configured bytes intact. */
internal object NativeNzbInputs {
    const val MAX_MIRRORS = 8
    const val MAX_SERVERS = 16

    fun mirrors(single: String?, plural: List<String>): List<String> {
        val ordered = buildList { if (single != null) add(single); addAll(plural) }.distinct()
        require(ordered.size <= MAX_MIRRORS) { "Too many NZB mirrors" }
        ordered.forEach { raw ->
            val uri = uri(raw)
            require(uri.scheme?.lowercase(Locale.ROOT) in setOf("http", "https") && uri.host != null &&
                uri.rawUserInfo == null && uri.rawFragment == null && uri.port != 0 && uri.port <= 65535) {
                "Invalid NZB mirror"
            }
        }
        return ordered
    }

    fun servers(values: List<String>): List<String> {
        require(values.size <= MAX_SERVERS) { "Too many NNTP servers" }
        values.forEach { raw ->
            val uri = uri(raw)
            require(uri.scheme?.lowercase(Locale.ROOT) in setOf("nntp", "nntps") && uri.host != null &&
                uri.port != 0 && uri.port <= 65535 && uri.rawQuery == null && uri.rawFragment == null &&
                uri.rawPath.matches(Regex("/[0-9]{1,3}")) && uri.rawPath.drop(1).toInt() in 1..100) {
                "Invalid NNTP server"
            }
            // URI preserves raw userinfo; validate decoded control characters without normalizing '+' or escapes.
            uri.rawUserInfo?.split(':', limit = 2)?.forEach { component ->
                val decoded = try { decodeCredential(component) }
                catch (_: Exception) { throw IllegalArgumentException("Invalid NNTP credential encoding") }
                require(decoded.toByteArray(Charsets.UTF_8).size <= 1024 && decoded.none(Char::isISOControl)) {
                    "Invalid NNTP credential encoding"
                }
            }
        }
        return values.toList()
    }

    fun strings(document: JSONObject, key: String): List<String> {
        if (!document.has(key) || document.isNull(key)) return emptyList()
        val array = document.opt(key) as? JSONArray ?: throw IllegalArgumentException("Invalid Usenet array")
        // Bound before allocation, including duplicate entries (no truncation).
        require(array.length() <= if (key == "servers") MAX_SERVERS else MAX_MIRRORS) { "Usenet array is too large" }
        return (0 until array.length()).map { array.opt(it) as? String ?: throw IllegalArgumentException("Invalid Usenet array entry") }
    }

    fun saved(values: List<UsenetProviderServer>): List<String> = servers(values.filter { it.enabled }.map { server ->
        require(server.isValid) { "Invalid saved NNTP server" }
        val credentials = server.credentials
        val user = encode(credentials.username)
        val password = encode(credentials.password)
        "${if (credentials.useSSL) "nntps" else "nntp"}://$user:$password@${credentials.host.trim()}:${credentials.port}/${credentials.maxConnections}"
    })

    private fun uri(raw: String): URI {
        require(raw.isNotEmpty() && raw.length <= 8192 && raw.none { it.isWhitespace() || it.isISOControl() }) { "Invalid Usenet URL" }
        require(Charsets.UTF_8.newEncoder().canEncode(raw)) { "Invalid Usenet URL" }
        return try { URI(raw) } catch (_: Exception) { throw IllegalArgumentException("Invalid Usenet URL") }
    }

    private fun encode(value: String): String = buildString {
        require(Charsets.UTF_8.newEncoder().canEncode(value)) { "Invalid NNTP credential encoding" }
        value.toByteArray(Charsets.UTF_8).forEach { byte ->
            val code = byte.toInt() and 255
            if (code in 65..90 || code in 97..122 || code in 48..57 || code in listOf(45, 46, 95, 126)) append(code.toChar())
            else append("%%%02X".format(code))
        }
    }

    private fun decodeCredential(value: String): String {
        val bytes = value.toByteArray(Charsets.UTF_8)
        val output = ByteArrayOutputStream(bytes.size)
        var index = 0
        while (index < bytes.size) {
            if (bytes[index] == '%'.code.toByte()) {
                require(index + 2 < bytes.size)
                output.write(String(bytes, index + 1, 2, Charsets.US_ASCII).toInt(16))
                index += 3
            } else output.write(bytes[index++].toInt())
        }
        return Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(output.toByteArray())).toString()
    }
}
