package com.vortx.android.xperience

import java.net.URI
import java.security.MessageDigest
import java.util.Locale

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
        /** Configured transport snapshot; do not log or display it as an imported source value. */
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
        val uri = try { URI(raw) } catch (_: Exception) { throw IllegalArgumentException("Invalid installed registry") }
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        val authority = uri.rawAuthority
        val path = uri.rawPath ?: ""
        require((scheme == "http" || scheme == "https") && uri.host?.isNotEmpty() == true &&
            uri.rawUserInfo == null && uri.rawFragment == null && authority != null &&
            path.lowercase(Locale.ROOT).endsWith("/manifest.json") &&
            (uri.port == -1 || uri.port in 1..65535)) { "Invalid installed registry" }
        // Rebuild only scheme/authority. Preserve the raw escaped path and query, including %2F.
        val normalized = buildString {
            append(scheme).append("://").append(authority.lowercase(Locale.ROOT)).append(path)
            uri.rawQuery?.let { append('?').append(it) }
        }
        return try {
            URI(normalized)
            normalized
        } catch (_: Exception) {
            throw IllegalArgumentException("Invalid installed registry")
        }
    }

    private fun exact(left: String, right: String): Boolean =
        left.toByteArray(Charsets.UTF_8).contentEquals(right.toByteArray(Charsets.UTF_8))

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
}
