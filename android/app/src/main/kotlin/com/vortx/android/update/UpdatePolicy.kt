package com.vortx.android.update

import org.json.JSONObject
import java.net.URI
import java.net.URISyntaxException
import java.net.URL
import java.security.MessageDigest

/**
 * Pure, Android-free trust policy for the updater (SEC-01). Every decision the network layer makes about a
 * URL, a feed entry, or a digest is expressed here as a function over plain values so adversarial fixtures
 * can be tested on the JVM without sockets or framework classes.
 *
 * Fail-closed rule: every function returns null / [UpdateDecision.Malformed] on anything it cannot fully
 * validate. A malformed or hostile feed NEVER yields an installable artifact and never degrades to some
 * fallback URL; the pre-2026-08 behaviour of falling back to the releases page is gone on purpose.
 */
internal object UpdatePolicy {

    /** The only hosts a manifest URL, an artifact URL, or ANY redirect hop may use. */
    val ALLOWED_HOSTS: Set<String> = setOf(
        "vortx.tv",                            // the appcast itself
        "github.com",                          // immutable release-asset URLs the feed publishes
        "objects.githubusercontent.com",       // github.com release downloads redirect here
        "release-assets.githubusercontent.com", // newer GitHub release-asset redirect host
    )

    /**
     * SHA-256 of the pinned production signing certificate, compact uppercase hex. MUST stay byte-equal to
     * EXPECTED_SIGNER_SHA256_COMPACT in scripts/verify-android-release-signing.sh: CI refuses to ship an
     * APK that does not carry this identity, and the client refuses to install one that does not either.
     */
    const val PINNED_SIGNER_SHA256 = "90DD0859BE63569B31F40BF93D3E3629094535013F3489C22BEE3B4655E0006A"

    /** Manifest body cap: a bigger response is bogus, not a feed. */
    const val MAX_MANIFEST_BYTES = 512 * 1024

    /** Hard sanity cap for a downloaded APK; the feed size must land in 1..this. */
    const val MAX_ARTIFACT_BYTES: Long = 1L shl 30 // 1 GiB

    /** Maximum redirects followed per fetch; hop 6 or later is refused outright. */
    const val MAX_REDIRECT_HOPS = 5

    private val HEX_64_ANY_CASE = Regex("^[0-9a-fA-F]{64}$")

    /** Field length caps; anything longer is hostile feed content, not prose. */
    private const val MAX_VERSION_CHARS = 64
    private const val MAX_NAME_CHARS = 200
    private const val MAX_NOTES_CHARS = 20_000

    // ------------------------------------------------------------------
    // Fingerprints and digests
    // ------------------------------------------------------------------

    /**
     * Normalize a certificate fingerprint to compact uppercase hex ("90:DD:..." and "90dd..." both map to
     * the same value); null when the input is not exactly 64 hex digits after cleanup.
     */
    fun normalizeFingerprint(raw: String): String? {
        val compact = raw.replace(":", "").replace(" ", "").trim().uppercase()
        return if (HEX_64_ANY_CASE.matches(compact)) compact else null
    }

    /** Normalize a hex content digest to lowercase; null unless exactly 64 hex digits remain. */
    fun normalizeDigest(raw: String): String? {
        val compact = raw.removePrefix("sha256:").removePrefix("SHA256:").trim()
        if (!HEX_64_ANY_CASE.matches(compact)) return null
        return compact.lowercase()
    }

    /** Constant-time equality for digests and fingerprints. */
    fun digestEquals(left: String?, right: String?): Boolean {
        if (left == null || right == null) return false
        val a = left.toByteArray(Charsets.US_ASCII)
        val b = right.toByteArray(Charsets.US_ASCII)
        return MessageDigest.isEqual(a, b)
    }

    // ------------------------------------------------------------------
    // URL policy
    // ------------------------------------------------------------------

    /**
     * Validate an artifact URL exactly as published by the release feed: HTTPS only, allow-listed host,
     * no userinfo, no query, no fragment, default or 443 port, non-empty path. Returns the canonical
     * string or null. The strictness matches the worker's own asset contract (immutable GitHub URL).
     */
    fun validateArtifactUrl(raw: String): String? {
        val uri = parseUri(raw) ?: return null
        if (!isTrustedSchemeAndHost(uri)) return null
        if (uri.rawQuery != null || uri.fragment != null) return null
        val path = uri.rawPath
        if (path.isNullOrEmpty() || !path.startsWith("/")) return null
        return uri.toString()
    }

    /**
     * Validate ONE redirect hop. Same scheme/host/userinfo rules as [validateArtifactUrl], but a query is
     * allowed because the GitHub object stores sign redirect targets with query parameters. Returns the
     * resolved absolute URL or null when the hop must be refused.
     */
    fun resolveRedirect(current: URL, location: String): URL? {
        val trimmed = location.trim()
        if (trimmed.isEmpty()) return null
        val resolved = try {
            current.toURI().resolve(trimmed)
        } catch (_: IllegalArgumentException) {
            return null
        }
        if (!isTrustedSchemeAndHost(resolved)) return null
        return try {
            resolved.toURL()
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun parseUri(raw: String): URI? = try {
        URI(raw)
    } catch (_: URISyntaxException) {
        null
    } catch (_: NullPointerException) {
        null
    }

    private fun isTrustedSchemeAndHost(uri: URI): Boolean {
        // Exact string compare: URI does not normalize "HTTPS" vs "https", and anything that is not the
        // exact lowercase scheme is refused rather than case-folded.
        if (uri.scheme != "https") return false
        val host = uri.host?.lowercase() ?: return false
        if (host !in ALLOWED_HOSTS) return false
        if (!uri.userInfo.isNullOrEmpty()) return false
        val port = uri.port
        if (port != -1 && port != 443) return false
        return true
    }

    // ------------------------------------------------------------------
    // Feed evaluation
    // ------------------------------------------------------------------

    /** What [evaluateFeed] decided about one fetched appcast. */
    internal sealed interface UpdateDecision {
        /** No android entry, build at or below the running one, or a silent prerelease: nothing to offer. */
        data object None : UpdateDecision

        /** The feed is unusable or hostile: fail closed, offer nothing, keep the reason for logs/tests. */
        data class Malformed(val reason: String) : UpdateDecision

        /** A fully validated update offer; every field below has already passed its checks. */
        data class Offer(val release: VerifiedRelease) : UpdateDecision
    }

    /** An update whose feed metadata survived every check in [evaluateFeed]. Immutable by construction. */
    internal data class VerifiedRelease(
        val version: String,
        val build: Int,
        val name: String,
        val notes: String,
        val artifactUrl: String,
        val sizeBytes: Long,
        val sha256: String,
        val signerSha256: String,
    ) {
        /** Stable key distinguishing betas that share [version]; the Later/Skip + once-per-launch memory. */
        val key: String get() = "$version.$build"
    }

    /**
     * Evaluate a fetched appcast against the running build. This is the ONLY path from feed bytes to an
     * update offer; it deliberately re-checks fields the release worker also validates server-side, because
     * the client trusts neither the transport nor the edge cache.
     *
     * Strictness notes:
     *  - `build` must be a JSON integer (org.json would otherwise coerce "189"), strictly above the running one.
     *  - `signed` must be exactly boolean true.
     *  - `prerelease` true keeps the entry silent (stable-build semantics), a mistyped prerelease is Malformed.
     *  - `apk` and `url`, when both present, must agree; at least one must be present.
     *  - `signer` must normalize to [PINNED_SIGNER_SHA256]; anything else is refused before download.
     */
    fun evaluateFeed(manifestText: String, currentBuild: Int): UpdateDecision {
        if (manifestText.toByteArray(Charsets.UTF_8).size > MAX_MANIFEST_BYTES) {
            return UpdateDecision.Malformed("manifest exceeds ${MAX_MANIFEST_BYTES} byte cap")
        }
        val root = runCatching { JSONObject(manifestText) }.getOrNull()
            ?: return UpdateDecision.Malformed("manifest is not valid JSON")
        val entryRaw = root.opt("android") ?: return UpdateDecision.None
        if (entryRaw === JSONObject.NULL) return UpdateDecision.None
        val entry = entryRaw as? JSONObject ?: return UpdateDecision.Malformed("android entry is not an object")

        when (val prerelease = entry.opt("prerelease") ?: JSONObject.NULL) {
            JSONObject.NULL -> Unit // absent reads as stable; the publisher always sends the field today
            is Boolean -> if (prerelease) return UpdateDecision.None
            else -> return UpdateDecision.Malformed("prerelease is not a boolean")
        }

        val build = entry.opt("build")
        if (build !is Int) return UpdateDecision.Malformed("build is not an integer")
        if (build <= 0) return UpdateDecision.Malformed("build is not positive")
        if (build <= currentBuild) return UpdateDecision.None

        if (entry.opt("signed") != true) return UpdateDecision.Malformed("android entry is not marked signed")

        val version = optionalString(entry, "version")
        if (version.isNullOrEmpty() || version.isBlank() || version.length > MAX_VERSION_CHARS) {
            return UpdateDecision.Malformed("version missing, blank, or oversized")
        }
        val nameRaw = optionalString(entry, "name")
        if (nameRaw != null && nameRaw.length > MAX_NAME_CHARS) {
            return UpdateDecision.Malformed("name exceeds $MAX_NAME_CHARS chars")
        }
        val name = if (nameRaw.isNullOrBlank()) "" else nameRaw
        val notesRaw = optionalString(entry, "notes")
        if (notesRaw != null && notesRaw.length > MAX_NOTES_CHARS) {
            return UpdateDecision.Malformed("notes exceed $MAX_NOTES_CHARS chars")
        }
        val notes = notesRaw ?: ""

        val apkField = optionalString(entry, "apk")
        val urlField = optionalString(entry, "url")
        if (apkField != null && urlField != null && apkField != urlField) {
            return UpdateDecision.Malformed("apk and url disagree")
        }
        val rawArtifactUrl = apkField ?: urlField
            ?: return UpdateDecision.Malformed("no apk/url artifact URL")
        val artifactUrl = validateArtifactUrl(rawArtifactUrl)
            ?: return UpdateDecision.Malformed("artifact URL rejected by host policy")

        val sizeRaw = entry.opt("size")
        val size = when (sizeRaw) {
            is Int -> sizeRaw.toLong()
            is Long -> sizeRaw
            else -> return UpdateDecision.Malformed("size is not an integer")
        }
        if (size <= 0L || size > MAX_ARTIFACT_BYTES) {
            return UpdateDecision.Malformed("size outside 1..$MAX_ARTIFACT_BYTES")
        }

        val sha256Raw = optionalString(entry, "sha256")
            ?: return UpdateDecision.Malformed("sha256 missing")
        val sha256 = normalizeDigest(sha256Raw)
            ?: return UpdateDecision.Malformed("sha256 is not a 64-hex digest")

        val signerRaw = optionalString(entry, "signer")
            ?: return UpdateDecision.Malformed("signer missing")
        val signer = normalizeFingerprint(signerRaw)
            ?: return UpdateDecision.Malformed("signer is not a 64-hex fingerprint")
        if (!digestEquals(signer, PINNED_SIGNER_SHA256)) {
            return UpdateDecision.Malformed("feed signer does not match the pinned production certificate")
        }

        return UpdateDecision.Offer(
            VerifiedRelease(
                version = version,
                build = build,
                name = name,
                notes = notes,
                artifactUrl = artifactUrl,
                sizeBytes = size,
                sha256 = sha256,
                signerSha256 = signer,
            ),
        )
    }

    private fun optionalString(entry: JSONObject, key: String): String? {
        val value = entry.opt(key) ?: return null
        if (value === JSONObject.NULL) return null
        return value as? String
    }
}
