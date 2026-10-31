package com.vortx.android.xperience

import java.security.MessageDigest

/**
 * Pure Xperience source-to-installed-catalog matching. This is data resolution only: a Candidate
 * is not an install capability, owner lease, network authorization, or permission to mutate a profile.
 * A caller must obtain descriptors from its original admitted installed-addon snapshot and pass every
 * eventual request through the existing transport guard and owner/lifecycle checks.
 */
internal object XperienceAddonBinding {
    data class Catalog(
        val type: String,
        val id: String,
        val acceptsGenre: Boolean,
        val requiresGenre: Boolean,
        val supportsSkip: Boolean,
    )

    /** Narrow immutable projection required from one installed descriptor and its fetched manifest. */
    data class InstalledDescriptor(
        val manifestID: String,
        val transportURL: String,
        val catalogs: List<Catalog>,
        /** Presentation-only; deliberately excluded from identity and matching. */
        val displayName: String = "",
    )

    data class Mapping(val manifestID: String, val transportFingerprint: String)

    class Candidate private constructor(
        val manifestID: String,
        /** Portable identity bytes, never a request endpoint; Unicode host spelling is opaque, not IDNA. */
        val canonicalTransport: String,
        catalogs: List<Catalog>,
        val transportFingerprint: String,
    ) {
        val catalogs: List<Catalog> = catalogs.toList()
        val mapping: Mapping get() = Mapping(manifestID, transportFingerprint)

        companion object {
            /**
             * Projects an already installed descriptor. It never parses imported collection data,
             * installs an addon, or fetches the manifest. Catalogs must come from the matching
             * installed manifest snapshot, not from the imported Xperience document.
             */
            fun fromInstalled(descriptor: InstalledDescriptor): Candidate {
                require(descriptor.manifestID.isNotBlank()) { "Invalid installed registry" }
                val transport = normalizeInstalledTransport(descriptor.transportURL)
                val seen = HashSet<Pair<String, String>>()
                for (catalog in descriptor.catalogs) {
                    require(catalog.type.isNotEmpty() && catalog.id.isNotEmpty() &&
                        seen.add(catalog.type to catalog.id)) { "Invalid installed registry" }
                }
                return Candidate(descriptor.manifestID, transport, descriptor.catalogs,
                    sha256(transport.toByteArray(Charsets.UTF_8)))
            }
        }
    }

    sealed interface Resolution {
        data class Resolved(val candidate: Candidate) : Resolution
        object Missing : Resolution
        data class Ambiguous(val candidates: List<Candidate>) : Resolution
        object MappingUnavailable : Resolution
        object UnsupportedProvider : Resolution
        object UnsupportedGenreConfiguration : Resolution
        object InvalidRegistry : Resolution
    }

    /** Same semantic key used by Apple: provider/addon/type/catalog/genre, never a URL. */
    fun key(source: XperienceCollections.Source): String = source.semanticDigest

    fun resolve(
        source: XperienceCollections.Source,
        installed: List<Candidate>,
        mapping: Mapping? = null,
    ): Resolution {
        if (!source.isAddon) return Resolution.UnsupportedProvider
        val addonID = source.addonId ?: return Resolution.Missing
        val type = source.type ?: return Resolution.Missing
        val catalogID = source.catalogId ?: return Resolution.Missing
        val matching = installed.filter { candidate ->
            exact(candidate.manifestID, addonID) && candidate.catalogs.any {
                exact(it.type, type) && exact(it.id, catalogID)
            }
        }
        if (matching.isEmpty()) return if (mapping == null) Resolution.Missing else Resolution.MappingUnavailable
        // Duplicate configured identities are corrupt registry state; never pick by list order or name.
        if (matching.map { it.transportFingerprint }.toSet().size != matching.size) {
            return Resolution.InvalidRegistry
        }
        val chosen = if (mapping != null) {
            if (!exact(mapping.manifestID, addonID)) return Resolution.MappingUnavailable
            matching.singleOrNull { it.transportFingerprint == mapping.transportFingerprint }
                ?: return Resolution.MappingUnavailable
        } else {
            if (matching.size != 1) return Resolution.Ambiguous(matching)
            matching.single()
        }
        val catalog = chosen.catalogs.singleOrNull { exact(it.type, type) && exact(it.id, catalogID) }
            ?: return Resolution.InvalidRegistry
        if ((source.genre != null && !catalog.acceptsGenre) ||
            (catalog.requiresGenre && source.genre == null)) {
            return Resolution.UnsupportedGenreConfiguration
        }
        return Resolution.Resolved(chosen)
    }

    private fun normalizeInstalledTransport(raw: String): String {
        // Configured-source identity only. Requests retain the original installed addon snapshot.
        requireRegistry(raw.isNotEmpty())
        var sourceByteCount = 0
        var sourceIndex = 0
        while (sourceIndex < raw.length) {
            val value = raw[sourceIndex]
            requireRegistry(value.code > 32 && value.code !in 127..159)
            val width = when {
                Character.isHighSurrogate(value) -> {
                    requireRegistry(sourceIndex + 1 < raw.length && Character.isLowSurrogate(raw[sourceIndex + 1]))
                    sourceIndex += 2; 4
                }
                Character.isLowSurrogate(value) -> invalidRegistry()
                else -> { sourceIndex++; if (value.code < 128) 1 else if (value.code < 2048) 2 else 3 }
            }
            requireRegistry(sourceByteCount <= Int.MAX_VALUE - width)
            sourceByteCount += width
        }
        val outputCapacity = transportIdentityCapacity(sourceByteCount)
        val bytes = raw.toByteArray(Charsets.UTF_8).map { it.toInt() and 255 }
        requireRegistry(bytes.size == sourceByteCount && 35 !in bytes)
        val colon = bytes.indexOf(58)
        requireRegistry(colon >= 0 && colon + 2 < bytes.size && bytes[colon + 1] == 47 && bytes[colon + 2] == 47)
        val scheme = folded(bytes.take(colon))
        requireRegistry(scheme == ascii("http") || scheme == ascii("https"))
        val slash = (colon + 3 until bytes.size).firstOrNull { bytes[it] == 47 } ?: invalidRegistry()
        val authority = bytes.subList(colon + 3, slash)
        requireRegistry(authority.isNotEmpty() && 64 !in authority)
        val question = (slash until bytes.size).firstOrNull { bytes[it] == 63 } ?: bytes.size
        val path = bytes.subList(slash, question)
        requireRegistry(folded(path).takeLast(14) == ascii("/manifest.json"))
        val host: List<Int>
        val port: List<Int>?
        if (authority.first() == 91) {
            val close = authority.indexOf(93)
            requireRegistry(close >= 0)
            host = authority.take(close + 1)
            if (close + 1 == authority.size) port = null else {
                requireRegistry(authority[close + 1] == 58)
                port = authority.drop(close + 2)
            }
            requireIPv6(host.drop(1).dropLast(1))
        } else {
            val split = authority.indexOf(58)
            host = if (split < 0) authority else authority.take(split)
            port = if (split < 0) null else authority.drop(split + 1)
        }
        requireRegistry(host.isNotEmpty())
        val normalizedHost = if (host.first() == 91) {
            // A scoped interface identifier can be case-sensitive; only the address is folded.
            val zone = host.indexOf(37).let { if (it < 0) host.size else it }
            folded(host.take(zone)) + host.drop(zone)
        } else opaqueHost(host)
        val normalized = ArrayList<Int>(outputCapacity)
        normalized.addAll(scheme + ascii("://") + normalizedHost)
        if (port != null && port.isNotEmpty()) {
            var number = 0
            for (digit in port) {
                requireRegistry(digit in 48..57)
                number = number * 10 + digit - 48
                requireRegistry(number <= 65535)
            }
            requireRegistry(number > 0)
            normalized.addAll(ascii(":$number"))
        }
        normalized.addAll(escapedComponent(path, false))
        if (question < bytes.size) {
            normalized.add(63)
            normalized.addAll(escapedComponent(bytes.drop(question + 1), true))
        }
        requireRegistry(normalized.size <= outputCapacity)
        return normalized.map(Int::toByte).toByteArray().toString(Charsets.UTF_8)
    }

    /** Common Int32 output-count representation, not URL policy or available memory; allocates nothing. */
    internal fun transportIdentityCapacity(utf8Count: Int): Int {
        requireRegistry(utf8Count >= 0 && utf8Count <= Int.MAX_VALUE / 3)
        return utf8Count * 3
    }

    private fun invalidRegistry(): Nothing = throw IllegalArgumentException("Invalid installed registry")
    private fun requireRegistry(value: Boolean) { if (!value) invalidRegistry() }
    private fun ascii(value: String): List<Int> = value.map(Char::code)
    private fun folded(bytes: List<Int>): List<Int> = bytes.map { if (it in 65..90) it + 32 else it }
    private fun hex(byte: Int): Boolean = byte in 48..57 || byte in 65..70 || byte in 97..102
    private val nameASCII = ascii("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!\$&'()*+,;=").toSet()
    private val pathASCII = nameASCII + ascii(":@/")
    private fun opaqueHost(bytes: List<Int>): List<Int> {
        val text = bytes.map(Int::toByte).toByteArray().toString(Charsets.UTF_8)
        requireRegistry(text.none { it.code == 160 || it.code == 5760 || it.code in 8192..8202 ||
            it.code == 8232 || it.code == 8233 || it.code == 8239 || it.code == 8287 || it.code == 12288 })
        val result = ArrayList<Int>(bytes.size); var index = 0
        while (index < bytes.size) {
            val byte = bytes[index]
            if (byte == 37) {
                requireRegistry(index + 2 < bytes.size && hex(bytes[index + 1]) && hex(bytes[index + 2]))
                result.addAll(bytes.subList(index, index + 3)); index += 3
            } else {
                requireRegistry(byte >= 128 || byte in nameASCII)
                result.add(if (byte in 65..90) byte + 32 else byte); index++
            }
        }
        return result
    }
    private fun escapedComponent(bytes: List<Int>, query: Boolean): List<Int> {
        val digits = ascii("0123456789ABCDEF")
        val result = ArrayList<Int>(transportIdentityCapacity(bytes.size)); var index = 0
        while (index < bytes.size) {
            val byte = bytes[index]
            if (byte == 37) {
                requireRegistry(index + 2 < bytes.size && hex(bytes[index + 1]) && hex(bytes[index + 2]))
                result.addAll(bytes.subList(index, index + 3)); index += 3
            } else if (byte >= 128) {
                result.addAll(listOf(37, digits[byte shr 4], digits[byte and 15])); index++
            } else {
                requireRegistry(byte in pathASCII || query && byte == 63)
                result.add(byte); index++
            }
        }
        return result
    }
    private fun requireIPv6(bytes: List<Int>) {
        val percent = bytes.indexOf(37).let { if (it < 0) bytes.size else it }
        if (percent < bytes.size) {
            requireRegistry(percent + 3 < bytes.size && bytes[percent + 1] == 50 && bytes[percent + 2] == 53 &&
                bytes.drop(percent + 3).all { it in 48..57 || it in 65..90 || it in 97..122 || it in ascii("-._~") })
        }
        val address = bytes.take(percent).map(Int::toChar).joinToString("")
        requireRegistry(address.all { hex(it.code) || it == ':' || it == '.' } && ':' in address &&
            ":::" !in address && address.split("::").size <= 2 &&
            (!address.startsWith(':') || address.startsWith("::")) &&
            (!address.endsWith(':') || address.endsWith("::")))
        val groups = address.split(':').filter(String::isNotEmpty).toMutableList()
        var units = groups.size
        if (groups.lastOrNull()?.contains('.') == true) {
            val last = groups.removeAt(groups.lastIndex)
            val octets = last.split('.')
            requireRegistry(address.endsWith(last) && octets.size == 4 && octets.all { part ->
                part.length in 1..3 && part.all { it in '0'..'9' } && (part.toIntOrNull() ?: 256) <= 255 })
            units++
        }
        requireRegistry(groups.all { it.length in 1..4 && it.all { digit -> hex(digit.code) } } &&
            if ("::" in address) units < 8 else units == 8 && !address.startsWith(':') && !address.endsWith(':'))
    }

    private fun exact(left: String, right: String): Boolean =
        left.toByteArray(Charsets.UTF_8).contentEquals(right.toByteArray(Charsets.UTF_8))

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
}
