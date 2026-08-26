package com.vortx.android.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/**
 * Adversarial coverage for the post-download gates (SEC-07): exact-size streaming, digest enforcement, and
 * the archive identity/signer checks, exercised through a fake [ApkVerification.ApkInspector] so the whole
 * verification pipeline runs on the JVM.
 */
class ApkVerificationTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val pinnedSigner = "90DD0859BE63569B31F40BF93D3E3629094535013F3489C22BEE3B4655E0006A"

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun spec(
        content: ByteArray,
        version: String = "0.3.15",
        build: Int = 189,
        sha256: String = sha256Hex(content),
        sizeBytes: Long = content.size.toLong(),
    ) = UpdatePolicy.VerifiedRelease(
        version = version,
        build = build,
        name = "VortX",
        notes = "",
        artifactUrl = "https://github.com/VortXTV/VortX/releases/download/v$version/a.apk",
        sizeBytes = sizeBytes,
        sha256 = sha256,
        signerSha256 = pinnedSigner,
    )

    private fun identity(
        packageName: String? = "com.vortx.android",
        versionName: String? = "0.3.15",
        versionCode: Long? = 189L,
        signer: String? = pinnedSigner,
    ) = ApkVerification.ApkIdentity(packageName, versionName, versionCode, signer)

    private val matchingInspector = ApkVerification.ApkInspector { identity() }

    // ------------------------------------------------------------------
    // copyExactWithDigest: the stream gate
    // ------------------------------------------------------------------

    @Test
    fun exactStreamCopiesAndHashesTheDeclaredByteCount() {
        val content = ByteArray(200_000) { (it % 251).toByte() } // spans many buffer refills
        val out = ByteArrayOutputStream()
        val digest = ApkVerification.copyExactWithDigest(
            ByteArrayInputStream(content),
            out,
            content.size.toLong(),
        )
        assertEquals(sha256Hex(content), digest)
        assertTrue(out.toByteArray().contentEquals(content))
    }

    @Test
    fun truncatedStreamIsRefused() {
        val content = ByteArray(1000) { 7 }
        val out = ByteArrayOutputStream()
        assertNull(
            ApkVerification.copyExactWithDigest(
                ByteArrayInputStream(content),
                out,
                expectedBytes = content.size + 1L, // promises more than the body has
            ),
        )
        // Whatever was streamed before the refusal stays in the sink; the CALLER deletes it. The checker
        // does exactly that on every null-digest path.
        assertEquals(content.size.toLong(), out.size().toLong())
    }

    @Test
    fun oneExtraByteIsTamperingAndIsRefused() {
        val content = ByteArray(500) { 3 }
        val out = ByteArrayOutputStream()
        assertNull(
            ApkVerification.copyExactWithDigest(
                ByteArrayInputStream(content),
                out,
                expectedBytes = content.size - 1L,
            ),
        )
    }

    @Test
    fun nonPositiveExpectationIsRefusedWithoutReading() {
        assertNull(ApkVerification.copyExactWithDigest(ByteArrayInputStream(byteArrayOf(1)), ByteArrayOutputStream(), 0))
        assertNull(ApkVerification.copyExactWithDigest(ByteArrayInputStream(byteArrayOf(1)), ByteArrayOutputStream(), -5))
    }

    // ------------------------------------------------------------------
    // verify(): the full gate
    // ------------------------------------------------------------------

    private var stagedCounter = 0

    private fun stagedApk(content: ByteArray): File {
        // TemporaryFolder.newFile rejects duplicate names within one test; every stage gets a fresh name.
        val file = tmp.newFile("staged-${++stagedCounter}.apk")
        file.writeBytes(content)
        return file
    }

    @Test
    fun everyGatePassingAcceptsTheArtifact() {
        val content = "genuine-apk-bytes".toByteArray()
        val file = stagedApk(content)
        val verdict = ApkVerification.verify(file, spec(content), "com.vortx.android", matchingInspector)
        assertEquals(ApkVerification.Verdict.Accepted(file), verdict)
    }

    @Test
    fun missingFileWrongSizeAndBadDigestAreAllRejected() {
        val content = "apk".toByteArray()
        val goodSpec = spec(content)

        val missing = File(tmp.root, "not-there.apk")
        assertTrue(ApkVerification.verify(missing, goodSpec, "com.vortx.android", matchingInspector)
            is ApkVerification.Verdict.Rejected)

        val shortFile = stagedApk("ap".toByteArray())
        val shortVerdict = ApkVerification.verify(shortFile, goodSpec, "com.vortx.android", matchingInspector)
        assertTrue(shortVerdict is ApkVerification.Verdict.Rejected)
        assertFalse((shortVerdict as ApkVerification.Verdict.Rejected).reason.contains("checksum"))

        val tamperedContent = "APK".toByteArray() // same length, different bytes
        val tampered = stagedApk(tamperedContent)
        val tamperedVerdict = ApkVerification.verify(tampered, goodSpec, "com.vortx.android", matchingInspector)
        assertTrue((tamperedVerdict as ApkVerification.Verdict.Rejected).reason.contains("SHA-256"))
    }

    @Test
    fun wrongArchiveIdentityIsRejected() {
        val content = "bytes".toByteArray()
        val s = spec(content)

        listOf(
            "foreign package" to identity(packageName = "com.evil.repack"),
            "wrong build" to identity(versionCode = 999L),
            "unknown build" to identity(versionCode = null),
            "wrong version" to identity(versionName = "9.9.9"),
        ).forEach { (label, badIdentity) ->
            val verdict = ApkVerification.verify(
                stagedApk(content), s, "com.vortx.android",
                ApkVerification.ApkInspector { badIdentity },
            )
            assertTrue("expected rejection for [$label]", verdict is ApkVerification.Verdict.Rejected)
        }
    }

    @Test
    fun unreadableArchiveIsRejected() {
        val content = "bytes".toByteArray()
        val inspector = ApkVerification.ApkInspector { null }
        val verdict = ApkVerification.verify(stagedApk(content), spec(content), "com.vortx.android", inspector)
        assertTrue(verdict is ApkVerification.Verdict.Rejected)
    }

    @Test
    fun signerMismatchIsRejectedEvenWhenEverythingElseMatches() {
        val content = "signed-by-someone-else".toByteArray()
        val s = spec(content)
        listOf(
            "different cert" to identity(signer = "f".repeat(64)),
            "no signing block" to identity(signer = null),
            "garbled fingerprint" to identity(signer = "zz"),
            "multi-signer artifact reported as absent" to identity(signer = ""),
        ).forEach { (label, badIdentity) ->
            val verdict = ApkVerification.verify(
                stagedApk(content), s, "com.vortx.android",
                ApkVerification.ApkInspector { badIdentity },
            )
            assertTrue("expected signer rejection for [$label]", verdict is ApkVerification.Verdict.Rejected)
            assertNotNull(verdict)
        }
    }

    @Test
    fun colonSeparatedSignerFromTheArchiveStillMatchesThePin() {
        val content = "ok".toByteArray()
        val colonForm = "90:dd:08:59:be:63:56:9b:31:f4:0b:f9:3d:3e:36:29:" +
            "09:45:35:01:3f:34:89:c2:2b:ee:3b:46:55:e0:00:6a"
        val inspector = ApkVerification.ApkInspector { identity(signer = colonForm) }
        val verdict = ApkVerification.verify(stagedApk(content), spec(content), "com.vortx.android", inspector)
        assertEquals(ApkVerification.Verdict.Accepted::class, verdict::class)
    }
}
