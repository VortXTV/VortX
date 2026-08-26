package com.vortx.android.update

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale

/**
 * Post-download artifact verification (SEC-07). The feed promised a size, a SHA-256, an identity and a
 * signer; this layer proves the downloaded bytes keep that promise BEFORE anything is handed to the
 * package installer. Every check fails closed: any mismatch deletes the artifact and reports a reason,
 * and nothing ever reaches [android.content.Intent.ACTION_VIEW] unless every check passed.
 *
 * The APK inspection itself is behind [ApkInspector] so the orchestration is testable on the JVM with a
 * fake; the production inspector reads the real package metadata through PackageManager.
 */
internal object ApkVerification {

    /** Identity read out of a downloaded APK by [ApkInspector]. */
    internal data class ApkIdentity(
        val packageName: String?,
        val versionName: String?,
        val versionCode: Long?,
        /** SHA-256 of the signing certificate, compact uppercase; null when unreadable or absent. */
        val signerSha256: String?,
    )

    internal fun interface ApkInspector {
        fun inspect(apk: File): ApkIdentity?
    }

    internal sealed interface Verdict {
        /** Every check passed; the file at [apk] may be handed to the installer. */
        data class Accepted(val apk: File) : Verdict

        /** The artifact broke its promise. Never installable; [reason] is safe, user-facing text. */
        data class Rejected(val reason: String) : Verdict
    }

    /**
     * Stream-copy at most [expectedBytes] from [input] into [output] while hashing. Returns the lowercase
     * hex SHA-256 of exactly [expectedBytes] bytes, or null when the stream ended early OR carried even one
     * extra byte: both are failures, never "close enough".
     */
    fun copyExactWithDigest(input: InputStream, output: OutputStream, expectedBytes: Long): String? {
        if (expectedBytes <= 0L) return null
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var remaining = expectedBytes
        while (remaining > 0L) {
            val chunk = minOf(remaining, buffer.size.toLong()).toInt()
            val read = input.read(buffer, 0, chunk)
            if (read < 0) return null // truncated body
            digest.update(buffer, 0, read)
            output.write(buffer, 0, read)
            remaining -= read
        }
        // One byte past the declared size is tampering or a lying server; refuse it.
        if (input.read() != -1) return null
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Full gate for a downloaded artifact against its feed spec:
     * exact byte length, exact digest, then archive identity (package, versionCode, versionName) and the
     * pinned production signing certificate. Returns [Verdict.Accepted] only when ALL hold.
     */
    fun verify(
        apk: File,
        release: UpdatePolicy.VerifiedRelease,
        expectedPackage: String,
        inspector: ApkInspector,
    ): Verdict {
        if (!apk.isFile) return Verdict.Rejected("Downloaded update file is missing.")
        val length = apk.length()
        if (length != release.sizeBytes) {
            return Verdict.Rejected("Downloaded update has the wrong size ($length vs ${release.sizeBytes} bytes).")
        }
        val actualDigest = runCatching { sha256File(apk) }.getOrNull()
            ?: return Verdict.Rejected("Downloaded update could not be read for hashing.")
        if (!UpdatePolicy.digestEquals(actualDigest, release.sha256)) {
            return Verdict.Rejected("Downloaded update failed its integrity check (SHA-256 mismatch).")
        }
        val identity = runCatching { inspector.inspect(apk) }.getOrNull()
            ?: return Verdict.Rejected("Downloaded update is not a readable Android package.")
        if (identity.packageName != expectedPackage) {
            return Verdict.Rejected(
                "Update targets a different app (${identity.packageName ?: "unknown"}), installation blocked.",
            )
        }
        if (identity.versionCode == null || identity.versionCode != release.build.toLong()) {
            return Verdict.Rejected("Update build does not match the announced build; installation blocked.")
        }
        if (identity.versionName != release.version) {
            return Verdict.Rejected("Update version does not match the announced version; installation blocked.")
        }
        val signer = identity.signerSha256?.let { UpdatePolicy.normalizeFingerprint(it) }
        if (signer == null || !UpdatePolicy.digestEquals(signer, UpdatePolicy.PINNED_SIGNER_SHA256)) {
            return Verdict.Rejected("Update was not signed with the pinned VortX release key; installation blocked.")
        }
        return Verdict.Accepted(apk)
    }

    private fun sha256File(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Production inspector: parse the archive's manifest + signing block without installing it.
     * Requires exactly ONE signer (mirroring scripts/verify-android-release-signing.sh) so a multi-signed
     * or re-signed artifact cannot slip a second identity past the pin.
     */
    internal class PackageManagerInspector(private val context: Context) : ApkInspector {

        override fun inspect(apk: File): ApkIdentity? {
            val pm = context.packageManager
            val path = apk.absolutePath
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageArchiveInfo(path, PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES)
            } ?: return null

            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                info.signatures
            }
            if (signatures == null || signatures.size != 1) return null
            val certDigest = MessageDigest.getInstance("SHA-256")
                .digest(signatures[0].toByteArray())
                .joinToString("") { "%02X".format(it) }

            @Suppress("DEPRECATION")
            val versionCode: Long = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                info.versionCode.toLong()
            }
            return ApkIdentity(
                packageName = info.packageName,
                versionName = info.versionName,
                versionCode = versionCode,
                signerSha256 = certDigest.uppercase(Locale.US),
            )
        }
    }
}
