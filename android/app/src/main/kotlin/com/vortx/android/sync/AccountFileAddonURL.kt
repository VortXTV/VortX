package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.Locale
import okhttp3.HttpUrl

/** File-material URL identity only; never a request builder or a transport permission.
 * Mirrors the Apple projector's component operation: parse, reject user/password/fragment,
 * decode host once, lowercase scheme/host, then encode the host. Path/query are never decoded,
 * Unicode-normalized, case-folded, resolved, or passed through HttpUrl's URL canonicalizer.
 * Cross-platform edge behavior must pass the actual Apple oracle, not inferred goldens alone. */
internal object AccountFileAddonURL {
    private const val unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    private const val subDelimiters = "!$&'()*+,;="
    private const val hex = "0123456789ABCDEF"

    fun normalize(raw: String): String {
        try {
            require(raw.length <= AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES)
            val trimmed = raw.trim(::whitespaceOrNewline)
            val schemeEnd = trimmed.indexOf(':')
            require(schemeEnd > 0)
            val scheme = trimmed.substring(0, schemeEnd).lowercase(Locale.ROOT)
            require(scheme == "http" || scheme == "https")
            require(trimmed.startsWith("//", schemeEnd + 1) && '#' !in trimmed)
            val authorityStart = schemeEnd + 3
            val authorityEnd = (authorityStart until trimmed.length).firstOrNull {
                trimmed[it] == '/' || trimmed[it] == '?'
            } ?: trimmed.length
            val authority = trimmed.substring(authorityStart, authorityEnd)
            require(authority.isNotEmpty() && '@' !in authority)
            val bracketed = authority.startsWith('[')
            val rawHost: String
            val portSuffix: String
            if (bracketed) {
                val end = authority.indexOf(']')
                require(end > 1)
                rawHost = authority.substring(0, end + 1)
                portSuffix = authority.substring(end + 1)
                // URI is used only as an IPv6 syntax validator, never to reserialize a URL.
                require(URI("$scheme://$rawHost").host != null)
            } else {
                require('[' !in authority && ']' !in authority)
                val colon = authority.lastIndexOf(':')
                if (colon >= 0) {
                    require(authority.indexOf(':') == colon)
                    rawHost = authority.substring(0, colon); portSuffix = authority.substring(colon)
                } else { rawHost = authority; portSuffix = "" }
            }
            require(rawHost.isNotEmpty())
            val port = normalizePort(portSuffix)
            val decodedHost = decodeHostOnce(rawHost, literalBracketed = bracketed).lowercase(Locale.ROOT)
            require(decodedHost.isNotEmpty())
            val host = normalizeHost(scheme, decodedHost)
            val tail = trimmed.substring(authorityEnd)
            val question = tail.indexOf('?')
            val path = if (question < 0) tail else tail.substring(0, question)
            val query = if (question < 0) null else tail.substring(question + 1)
            val normalized = buildString {
                append(scheme).append("://").append(host).append(port)
                append(encode(path, unreserved + subDelimiters + ":@/", preserveEscapes = true))
                query?.let { append('?').append(encode(it, unreserved + subDelimiters + ":@/?", preserveEscapes = true)) }
            }
            require(normalized.length <= AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES)
            return normalized
        } catch (_: Exception) {
            error("Account profile add-on URL requires reconciliation")
        }
    }

    private fun normalizePort(suffix: String): String {
        if (suffix.isEmpty()) return ""
        require(suffix.startsWith(':'))
        val digits = suffix.substring(1)
        require(digits.all { it in '0'..'9' })
        if (digits.isEmpty()) return ""
        return ":" + digits.trimStart('0').ifEmpty { "0" }
    }

    private fun normalizeHost(scheme: String, host: String): String {
        if (host.startsWith('[')) {
            // An entirely escaped bracketed host can become IPv6 after the single decode.
            // Serialize the original address spelling, including the percent-encoded zone delimiter.
            require(host.endsWith(']'))
            val encoded = encode(host, unreserved + subDelimiters + ":[]", preserveEscapes = false)
            val uri = URI("$scheme://$encoded")
            require(uri.host != null && uri.rawAuthority == encoded && uri.rawUserInfo == null && uri.port == -1)
            return encoded
        }
        require(host.none { it in "\\/:?#@[]" })
        val escapeHex = hostEscapeHex(host)
        if (host.all { it.code < 128 }) return encode(host, unreserved + subDelimiters, preserveEscapes = true)
        if (escapeHex.isEmpty()) return idnaHost(host)
        return idnaHostWithEscapes(host, escapeHex)
    }

    // Pack the exact two-character tokens in source order without an allocation per escape.
    private fun hostEscapeHex(host: String): String = buildString {
        for (index in host.indices) {
            if (host[index] != '%') continue
            require(index + 2 < host.length)
            val high = host[index + 1]
            val low = host[index + 2]
            require(hexValue(high.code) >= 0 && hexValue(low.code) >= 0)
            append(high).append(low)
        }
    }

    private fun idnaHost(host: String): String = HttpUrl.Builder().scheme("https").host(host).build().host.also {
        require(it.isNotEmpty() && it.length <= AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES && it.all { char -> char.code in 33..126 })
    }

    /** OkHttp's hostname validator rejects percent. Two one-character ASCII substitutions keep
     * each residual escape in the basic character sequence while the existing IDNA mapper handles
     * the surrounding Unicode. Restore escapes only when both conversions agree on their shape,
     * every changed position is an exact marker pair in the basic sequence, and the following
     * hex pair matches the next source escape. The host setter sees no percent in either
     * conversion, so it cannot decode another layer. */
    private fun idnaHostWithEscapes(host: String, escapeHex: String): String {
        val first = idnaHost(host.replace('%', 'g'))
        val second = idnaHost(host.replace('%', 'h'))
        require(first.length == second.length)
        var labelStart = 0
        var basicStart = 0
        var basicEnd = -1
        var escapeOffset = 0
        val output = StringBuilder(first.length)
        for (index in first.indices) {
            val left = first[index]
            if (left == second[index]) {
                output.append(left)
                if (left == '.') {
                    labelStart = index + 1
                    basicEnd = -1
                }
                continue
            }
            require(left == 'g' && second[index] == 'h')
            if (basicEnd < 0) {
                val labelEnd = first.indexOf('.', labelStart).let { if (it < 0) first.length else it }
                require(second.indexOf('.', labelStart).let { if (it < 0) second.length else it } == labelEnd)
                val punycode = first.startsWith("xn--", labelStart)
                require(punycode == second.startsWith("xn--", labelStart))
                basicStart = if (punycode) labelStart + 4 else labelStart
                basicEnd = if (punycode) first.lastIndexOf('-', labelEnd - 1) else labelEnd
                require(!punycode || basicEnd == second.lastIndexOf('-', labelEnd - 1))
            }
            require(index >= basicStart && index + 2 < basicEnd)
            require(escapeOffset + 1 < escapeHex.length)
            val high = escapeHex[escapeOffset]
            val low = escapeHex[escapeOffset + 1]
            require(first[index + 1] == high && second[index + 1] == high &&
                first[index + 2] == low && second[index + 2] == low)
            output.append('%')
            escapeOffset += 2
        }
        require(escapeOffset == escapeHex.length)
        return output.toString()
    }

    /** Percent is interpreted once in the host. Literal IPv6 zones retain the existing URI
     * syntax check above. A malformed escape in a regular host is refused. */
    private fun decodeHostOnce(value: String, literalBracketed: Boolean): String {
        requireWellFormedUTF16(value)
        val bytes = value.toByteArray(Charsets.UTF_8)
        val output = ByteArrayOutputStream(bytes.size)
        var index = 0
        while (index < bytes.size) {
            val byte = bytes[index].toInt() and 255
            val high = bytes.getOrNull(index + 1)?.toInt()?.and(255)?.let(::hexValue) ?: -1
            val low = bytes.getOrNull(index + 2)?.toInt()?.and(255)?.let(::hexValue) ?: -1
            if (byte == '%'.code && high >= 0 && low >= 0) {
                output.write(high * 16 + low)
                index += 3
            } else {
                require(byte != '%'.code || literalBracketed)
                output.write(byte)
                index++
            }
        }
        return OHJson.utf8(output.toByteArray())
    }

    /** UTF-8 percent-encoding without URI.toASCIIString's Unicode normalization. Already valid
     * path/query escapes keep their original hex spelling. Bad literal '%' becomes '%25'. */
    private fun encode(value: String, allowed: String, preserveEscapes: Boolean): String {
        requireWellFormedUTF16(value)
        val bytes = value.toByteArray(Charsets.UTF_8)
        return buildString {
            var index = 0
            while (index < bytes.size) {
                val byte = bytes[index].toInt() and 255
                if (preserveEscapes && byte == '%'.code && index + 2 < bytes.size &&
                    hexValue(bytes[index + 1].toInt() and 255) >= 0 && hexValue(bytes[index + 2].toInt() and 255) >= 0) {
                    append('%').append((bytes[index + 1].toInt() and 255).toChar())
                        .append((bytes[index + 2].toInt() and 255).toChar())
                    index += 3
                } else {
                    if (byte < 128 && byte.toChar() in allowed) append(byte.toChar())
                    else append('%').append(hex[byte ushr 4]).append(hex[byte and 15])
                    index++
                }
                require(length <= AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES)
            }
        }
    }

    private fun hexValue(byte: Int): Int = when (byte) {
        in '0'.code..'9'.code -> byte - '0'.code
        in 'A'.code..'F'.code -> byte - 'A'.code + 10
        in 'a'.code..'f'.code -> byte - 'a'.code + 10
        else -> -1
    }
    private fun requireWellFormedUTF16(value: String) {
        var index = 0
        while (index < value.length) {
            val char = value[index++]
            if (Character.isHighSurrogate(char)) require(index < value.length && Character.isLowSurrogate(value[index++]))
            else require(!Character.isLowSurrogate(char))
        }
    }
    private fun whitespaceOrNewline(char: Char) = Character.getType(char) == Character.SPACE_SEPARATOR.toInt() ||
        char in "\t\n\r\u000B\u000C\u0085\u2028\u2029"
}
