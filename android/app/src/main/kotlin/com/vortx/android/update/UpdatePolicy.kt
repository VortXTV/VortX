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
    const val PINNED_SIGNER_SHA256 = "FC22B87ECD9E4FA26930A1C3E227D8F7D918C646B216032B5DA820EF1AC218CA"

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

    /** Distribution flavors that may appear as keys of a split android container (AGP flavor names). */
    val ANDROID_FLAVOR_KEYS: Set<String> = setOf("full", "play")

    /** Required engine per flavor; any other value is a hostile or mislabeled entry. */
    private val FLAVOR_ENGINE: Map<String, String> = mapOf("full" to "mpv", "play" to "media3")

    /** The only schemaVersion this client understands; anything else is refused outright. */
    private const val REQUIRED_SCHEMA_VERSION = 2

    /**
     * Evaluate a fetched appcast against the running build and flavor. This is the ONLY path from feed
     * bytes to an update offer; it deliberately re-checks fields the release worker also validates
     * server-side, because the client trusts neither the transport nor the edge cache.
     *
     * SchemaVersion 2 split container ONLY:
     *  - The root must carry `"schemaVersion": 2`; any other value (or absence) is Malformed.
     *  - `android` must be an object whose children are keyed by flavor (`full`, `play`). Each child is
     *    an independent entry. ONLY the sub-entry keyed by [currentFlavor] is read; siblings are never
     *    parsed, so a malformed sibling cannot block this device. A missing/null/non-object entry for
     *    this flavor is None (nothing published for us), not Malformed.
     *  - Flat legacy shapes (the android object IS the entry) are REJECTED: the approved worker emits
     *    split containers only, and accepting a flat shape would bypass flavor/engine enforcement.
     *
     * Flavor and engine enforcement:
     *  - [currentFlavor] must be exactly "full" or "play"; any other value is rejected before parsing.
     *  - The selected child's `flavor` field, when present, must equal [currentFlavor].
     *  - The selected child's `engine` field must equal "mpv" for full or "media3" for play; absent,
     *    mismatched, or mistyped engine is Malformed.
     *
     * Strictness notes:
     *  - `build` must be a JSON integer (org.json would otherwise coerce "189"), strictly above the running one.
     *  - `signed` must be exactly boolean true.
     *  - `prerelease` true keeps the entry silent (stable-build semantics), a mistyped prerelease is Malformed.
     *  - `apk` and `url`, when both present, must agree; at least one must be present.
     *  - `signer` must normalize to [PINNED_SIGNER_SHA256]; anything else is refused before download.
     *  - optional `applicationId`, when present, must equal [expectedApplicationId].
     */
    fun evaluateFeed(
        manifestText: String,
        currentBuild: Int,
        currentFlavor: String,
        expectedApplicationId: String,
    ): UpdateDecision {
        if (currentFlavor !in ANDROID_FLAVOR_KEYS) {
            return UpdateDecision.Malformed("unsupported flavor \"$currentFlavor\"")
        }
        if (manifestText.toByteArray(Charsets.UTF_8).size > MAX_MANIFEST_BYTES) {
            return UpdateDecision.Malformed("manifest exceeds ${MAX_MANIFEST_BYTES} byte cap")
        }
        val root = runCatching { JSONObject(manifestText) }.getOrNull()
            ?: return UpdateDecision.Malformed("manifest is not valid JSON")

        // Schema gate: only version 2 split containers are accepted.
        val schemaRaw = root.opt("schemaVersion")
        if (schemaRaw !is Int || schemaRaw != REQUIRED_SCHEMA_VERSION) {
            return UpdateDecision.Malformed(
                "schemaVersion must be $REQUIRED_SCHEMA_VERSION, got ${schemaRaw ?: "null"}",
            )
        }

        val androidValue = root.opt("android") ?: return UpdateDecision.None
        if (androidValue === JSONObject.NULL) return UpdateDecision.None
        val androidObject = androidValue as? JSONObject
            ?: return UpdateDecision.Malformed("android entry is not an object")

        // Split container only: a flat legacy entry (one that carries its own "build") is rejected.
        // The approved worker always emits split containers; accepting flat would bypass flavor/engine gates.
        if (androidObject.has("build")) {
            return UpdateDecision.Malformed("flat legacy android entry is not supported; expected split container")
        }

        // Select exact flavor child; never fall across to sibling.
        val child = androidObject.opt(currentFlavor) ?: return UpdateDecision.None
        if (child === JSONObject.NULL) return UpdateDecision.None
        val entry = child as? JSONObject
            ?: return UpdateDecision.Malformed("android.$currentFlavor is not an object")

        // Flavor field must match selection when present.
        val declaredFlavor = optionalString(entry, "flavor")
        if (declaredFlavor == null) {
            return UpdateDecision.Malformed("android.$currentFlavor missing required flavor field")
        }
        if (declaredFlavor != currentFlavor) {
            return UpdateDecision.Malformed(
                "android.$currentFlavor declares mismatched flavor \"$declaredFlavor\"",
            )
        }

        // Engine field is mandatory and must match the flavor's required engine.
        val declaredEngine = optionalString(entry, "engine")
        val requiredEngine = FLAVOR_ENGINE.getValue(currentFlavor)
        if (declaredEngine == null) {
            return UpdateDecision.Malformed("android.$currentFlavor is missing required engine field")
        }
        if (declaredEngine != requiredEngine) {
            return UpdateDecision.Malformed(
                "android.$currentFlavor engine \"$declaredEngine\" does not match required \"$requiredEngine\"",
            )
        }

        val declaredApplicationId = optionalString(entry, "applicationId")
        if (declaredApplicationId != null && declaredApplicationId != expectedApplicationId) {
            return UpdateDecision.Malformed(
                "feed applicationId $declaredApplicationId does not match this app",
            )
        }

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
